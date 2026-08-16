//
//  Backends.swift
//  EmbedBench
//
//  The three candidates, behind one protocol — which is also the shape
//  `Core/SemanticIndex` will take, so the loser costs nothing.
//
//  Two are Apple's on-device embedding models. The third is a TF-IDF baseline,
//  and it is not a formality: the app *already* retrieves by keyword overlap
//  (`CollectionSearchModel`, `LibraryChatView.retrieve`). If an embedding
//  backend cannot beat plain term statistics on this vault, then the index has
//  no case — it would be build time, disk and complexity bought for nothing.
//  A benchmark without a baseline can only tell you which of two things you
//  already decided to build is better.
//

import Foundation
import NaturalLanguage
import Accelerate

/// One text → one unit-length vector. Nil when the backend cannot represent it.
protocol Embedder {
    var name: String { get }
    var dimension: Int { get }
    func vector(for text: String) -> [Float]?
}

// MARK: - Helpers

func l2Normalise(_ v: inout [Float]) {
    var norm: Float = 0
    vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
    norm = sqrt(norm)
    guard norm > 1e-9 else { return }
    var inv = 1 / norm
    vDSP_vsmul(v, 1, &inv, &v, 1, vDSP_Length(v.count))
}

/// Split into chunks a sentence model can actually represent.
///
/// `NLEmbedding.sentenceEmbedding` is a *sentence* model: hand it a 4,000-word
/// note and it returns something, but not something that means much. Chunking
/// is therefore not an optimisation here, it is a correctness requirement — and
/// it is what the real index would store anyway.
/// A hard ceiling every chunk must respect, whatever the tokenizer says.
///
/// **This is not defensive padding — it is load-bearing.** A note converted from
/// a PDF can contain no sentence-ending punctuation at all, so `NLTokenizer`
/// returns the entire note as one "sentence". This vault holds such a note: the
/// longest chunk it produced was **327,680 characters** against a median of 839,
/// and handing that to `NLEmbedding.vector(for:)` allocates until the process
/// dies. Two full 30-minute runs aborted at the same chunk index before the
/// distribution was actually looked at — a deterministic failure at a fixed
/// point is a specific *input*, never a leak, and the length histogram said so
/// in one line.
private func hardSplit(_ sentence: String, maxChars: Int) -> [String] {
    guard sentence.count > maxChars else { return [sentence] }
    var pieces: [String] = []
    var piece = ""
    for word in sentence.split(separator: " ", omittingEmptySubsequences: true) {
        if piece.count + word.count + 1 > maxChars, !piece.isEmpty {
            pieces.append(piece)
            piece = ""
        }
        // A single "word" longer than the ceiling (base64 blobs do exist in
        // converted notes) still has to be cut somewhere.
        if word.count > maxChars {
            pieces.append(contentsOf: stride(from: 0, to: word.count, by: maxChars).map {
                String(word.dropFirst($0).prefix(maxChars))
            })
        } else {
            piece += piece.isEmpty ? String(word) : " " + word
        }
    }
    if !piece.isEmpty { pieces.append(piece) }
    return pieces
}

func chunks(of text: String, maxChars: Int = 900, limit: Int = 24) -> [String] {
    let tokenizer = NLTokenizer(unit: .sentence)
    tokenizer.string = text
    var out: [String] = []
    var current = ""
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
        let raw = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return true }
        for sentence in hardSplit(raw, maxChars: maxChars) {
            if current.count + sentence.count + 1 > maxChars, !current.isEmpty {
                out.append(current)
                current = ""
                if out.count >= limit { return false }
            }
            current += current.isEmpty ? sentence : " " + sentence
        }
        return true
    }
    if !current.isEmpty, out.count < limit { out.append(current) }
    return out.isEmpty ? [String(text.prefix(maxChars))] : out
}

// MARK: - NLEmbedding (static sentence embedding)

final class SentenceEmbedder: Embedder {
    let name = "NLEmbedding.sentenceEmbedding"
    private let model: NLEmbedding
    var dimension: Int { model.dimension }

    init?() {
        guard let m = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        model = m
    }

    func vector(for text: String) -> [Float]? {
        guard let d = model.vector(for: text) else { return nil }
        var v = d.map(Float.init)
        l2Normalise(&v)
        return v
    }
}

// MARK: - NLContextualEmbedding (transformer, per-token)

final class ContextualEmbedder: Embedder {
    let name = "NLContextualEmbedding"
    private let model: NLContextualEmbedding
    var dimension: Int { model.dimension }

    init?() {
        guard let m = NLContextualEmbedding(language: .english) else { return nil }
        if !m.hasAvailableAssets {
            let sem = DispatchSemaphore(value: 0)
            var ok = false
            m.requestAssets { result, _ in
                ok = (result == .available)
                sem.signal()
            }
            // Asset download; generous, and reported if it times out.
            if sem.wait(timeout: .now() + 600) == .timedOut || !ok {
                FileHandle.standardError.write(
                    Data("NLContextualEmbedding assets unavailable\n".utf8))
                return nil
            }
        }
        do { try m.load() } catch {
            FileHandle.standardError.write(Data("NLContextualEmbedding load failed: \(error)\n".utf8))
            return nil
        }
        model = m
    }

    /// Mean of the token vectors — the standard way to turn a per-token model
    /// into one vector for a passage.
    func vector(for text: String) -> [Float]? {
        guard let result = try? model.embeddingResult(for: text, language: .english) else { return nil }
        var sum = [Float](repeating: 0, count: model.dimension)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            let v = vector.map(Float.init)
            vDSP_vadd(sum, 1, v, 1, &sum, 1, vDSP_Length(sum.count))
            count += 1
            return true
        }
        guard count > 0 else { return nil }
        var divisor = Float(count)
        vDSP_vsdiv(sum, 1, &divisor, &sum, 1, vDSP_Length(sum.count))
        l2Normalise(&sum)
        return sum
    }
}

// MARK: - TF-IDF baseline

/// Term-frequency baseline over the same chunks, projected into a fixed-width
/// hashed vector so it can be scored by exactly the same cosine code path as
/// the neural backends. Same evaluation, same pooling, same everything —
/// otherwise a difference in the numbers could be a difference in the harness.
final class TFIDFEmbedder: Embedder {
    let name = "TF-IDF (hashed, baseline)"
    let dimension = 2048
    private var idf: [Int: Float] = [:]

    private static let stop: Set<String> = [
        "the","and","for","with","that","this","from","are","was","were","have","has",
        "not","but","you","your","its","they","them","their","there","then",
        "what","when","which","who","will","would","can","could","should","about","into",
        "than","also","more","most","some","such","only","other","been","being","over"]

    static func terms(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 && !stop.contains($0) }
    }

    /// FNV-1a, **not** `String.hashValue`.
    ///
    /// Swift's `Hashable` is seeded per process, so a hashed feature index built
    /// with it means something different on every launch — fine inside one run,
    /// silently wrong the moment anything is persisted or compared across runs.
    /// This repo has already paid for that lesson once (`WalkCheckpointStore`),
    /// and a baseline whose numbers cannot be reproduced is not a baseline.
    private func bucket(_ term: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in term.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Int(hash % UInt64(dimension))
    }

    /// Document frequencies must come from the corpus, so this is fitted before
    /// any vector is produced.
    func fit(documents: [String]) {
        var df: [Int: Int] = [:]
        for doc in documents {
            var seen = Set<Int>()
            for term in Self.terms(doc) {
                let h = bucket(term)
                if seen.insert(h).inserted { df[h, default: 0] += 1 }
            }
        }
        let n = Float(max(documents.count, 1))
        idf = df.mapValues { log(n / Float(1 + $0)) + 1 }
    }

    func vector(for text: String) -> [Float]? {
        var v = [Float](repeating: 0, count: dimension)
        var any = false
        for term in Self.terms(text) {
            let h = bucket(term)
            v[h] += idf[h] ?? 1
            any = true
        }
        guard any else { return nil }
        l2Normalise(&v)
        return v
    }
}
