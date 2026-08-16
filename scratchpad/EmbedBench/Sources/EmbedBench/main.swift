//
//  main.swift
//  EmbedBench
//
//  Measures the candidates for 1.3's semantic index on a real vault:
//  index build time, memory, on-disk size, and retrieval quality against the
//  author's own wiki-links (see `Corpus.swift` for what that can and cannot
//  prove).
//
//  Usage:  swift run -c release EmbedBench <vault-path> [--limit N]
//

import Foundation
import Accelerate

// MARK: - Arguments

var args = Array(CommandLine.arguments.dropFirst())
var limit: Int?
/// Print the corpus + ground-truth header and stop. Checking whether the ground
/// truth is sound should not cost a 30-minute embedding run.
/// Run only the lexical candidates. The neural ones take 34 minutes and their
/// numbers are already recorded; comparing two lexical schemes should not cost
/// that again.
var lexicalOnly = false
var dryRun = false
if let i = args.firstIndex(of: "--dry") { dryRun = true; args.remove(at: i) }
if let i = args.firstIndex(of: "--lexical") { lexicalOnly = true; args.remove(at: i) }
if let i = args.firstIndex(of: "--limit"), i + 1 < args.count {
    limit = Int(args[i + 1])
    args.removeSubrange(i...(i + 1))
}
guard let vaultPath = args.first else {
    print("usage: EmbedBench <vault-path> [--limit N]")
    exit(2)
}
let root = URL(fileURLWithPath: (vaultPath as NSString).expandingTildeInPath)

// MARK: - Load

func stamp(_ s: String) {
    FileHandle.standardError.write(Data("• \(s)\n".utf8))
}

stamp("loading \(root.lastPathComponent)…")
let loadStart = Date()
var notes = Corpus.load(root: root, limit: limit)
let loadSeconds = Date().timeIntervalSince(loadStart)

// Flat chunk array, shared by every backend so they see identical input.
var allChunks: [String] = []
for i in notes.indices {
    let c = chunks(of: notes[i].text)
    notes[i].chunkRange = allChunks.count..<(allChunks.count + c.count)
    allChunks += c
}

let chunkLengths = allChunks.map(\.count).sorted()
stamp("chunk chars — median \(chunkLengths[chunkLengths.count/2]), p99 \(chunkLengths[chunkLengths.count*99/100]), max \(chunkLengths.last ?? 0)")

let linked = notes.indices.filter { !notes[$0].links.isEmpty }
let linkPairs = linked.reduce(0) { $0 + notes[$1].links.count }

print("""
# Semantic index benchmark

Vault:      \(root.path)
Notes:      \(notes.count) with ≥80 characters of prose
Chunks:     \(allChunks.count) (mean \(String(format: "%.1f", Double(allChunks.count) / Double(max(notes.count, 1)))) per note)
Load:       \(String(format: "%.1f", loadSeconds))s (coordinated reads)

## Ground truth

Queries:    \(linked.count) notes that link to at least one other note in the vault
Pairs:      \(linkPairs) author-authored links (mean \(String(format: "%.1f", Double(linkPairs) / Double(max(linked.count, 1)))) per query)

Link markup is stripped from the text every backend sees, so a target's title
is never present as a lexical clue. Recall here is a LOWER BOUND: an unlinked
pair is not evidence of unrelatedness, which is the premise of auto-linking.

""")

print("## Instrument check\n")
print("Paraphrase pairs must outrank unrelated text, or nothing below is worth reading.\n")

// Does chunking earn its complexity for the lexical winner?
//
// "mean-of-chunks" means: TF-IDF each ~900-character chunk, L2-normalise it,
// average, normalise again. A whole-note vector is one line of code instead.
// If they tie, the shipping index is markedly simpler — so measure rather than
// inherit the chunked design from the neural backends that needed it.
@MainActor func runWholeNoteTFIDF() {
    let start = Date()
    let model = TFIDFEmbedder()
    model.fit(documents: notes.map(\.text))
    var vectors: [Int: [Float]] = [:]
    for i in notes.indices { vectors[i] = model.vector(for: notes[i].text) }
    let build = Date().timeIntervalSince(start)

    let searchStart = Date()
    var r5 = 0.0, r10 = 0.0, mrr = 0.0
    for q in linked {
        guard let qv = vectors[q] else { continue }
        var scored: [(Int, Float)] = []
        for (i, v) in vectors where i != q {
            var d: Float = 0
            vDSP_dotpr(qv, 1, v, 1, &d, vDSP_Length(qv.count))
            if d > 0 { scored.append((i, d)) }
        }
        scored.sort { $0.1 > $1.1 }
        let ranked = scored.map(\.0)
        let truth = notes[q].links
        r5 += Double(truth.intersection(Set(ranked.prefix(5))).count) / Double(truth.count)
        r10 += Double(truth.intersection(Set(ranked.prefix(10))).count) / Double(truth.count)
        if let hit = ranked.firstIndex(where: { truth.contains($0) }) { mrr += 1.0 / Double(hit + 1) }
    }
    let n = Double(linked.count)
    results.append(Result(name: "TF-IDF whole-note (no chunking)", dimension: model.dimension,
                          embedSeconds: build, searchSeconds: Date().timeIntervalSince(searchStart),
                          failedChunks: 0, bytesOnDisk: notes.count * model.dimension * 4,
                          meanRecall5: r5 / n, meanRecall10: r10 / n, mrr: mrr / n,
                          pooling: "note-level"))
}
/// The variant that would be simplest to ship: one vector per note, built from
/// the *capped* text (the chunker's output rejoined) rather than the whole file.
///
/// Splitting the two effects matters. "mean-of-chunks" does two things at once —
/// it caps how much of a note is read (24 × 900 chars) and it normalises each
/// chunk separately. Whole-note did neither and lost 2.6 points. If the cap is
/// what carries the win, one vector per note is enough and the shipping index
/// never needs to store per-chunk state, which is a large simplification for an
/// index that must also update incrementally.
@MainActor func runCappedWholeNoteTFIDF() {
    let start = Date()
    let capped = notes.map { chunks(of: $0.text).joined(separator: " ") }
    let model = TFIDFEmbedder()
    model.fit(documents: capped)
    var vectors: [Int: [Float]] = [:]
    for i in notes.indices { vectors[i] = model.vector(for: capped[i]) }
    let build = Date().timeIntervalSince(start)

    let searchStart = Date()
    var r5 = 0.0, r10 = 0.0, mrr = 0.0
    for q in linked {
        guard let qv = vectors[q] else { continue }
        var scored: [(Int, Float)] = []
        for (i, v) in vectors where i != q {
            var d: Float = 0
            vDSP_dotpr(qv, 1, v, 1, &d, vDSP_Length(qv.count))
            if d > 0 { scored.append((i, d)) }
        }
        scored.sort { $0.1 > $1.1 }
        let ranked = scored.map(\.0)
        let truth = notes[q].links
        r5 += Double(truth.intersection(Set(ranked.prefix(5))).count) / Double(truth.count)
        r10 += Double(truth.intersection(Set(ranked.prefix(10))).count) / Double(truth.count)
        if let hit = ranked.firstIndex(where: { truth.contains($0) }) { mrr += 1.0 / Double(hit + 1) }
    }
    let n = Double(linked.count)
    results.append(Result(name: "TF-IDF capped-note (one vector per note)", dimension: model.dimension,
                          embedSeconds: build, searchSeconds: Date().timeIntervalSince(searchStart),
                          failedChunks: 0, bytesOnDisk: notes.count * model.dimension * 4,
                          meanRecall5: r5 / n, meanRecall10: r10 / n, mrr: mrr / n,
                          pooling: "note-level"))
}

@MainActor func runBM25() {
    let start = Date()
    let index = BM25Index()
    // One document per *note*, not per chunk: note-level won the first round,
    // and BM25's length normalisation is what makes that safe on a corpus whose
    // notes run from a paragraph to a book chapter.
    for i in notes.indices { index.add(doc: i, text: notes[i].text) }
    index.finalise()
    let build = Date().timeIntervalSince(start)

    let searchStart = Date()
    var recall5 = 0.0, recall10 = 0.0, mrr = 0.0
    for q in linked {
        let ranked = index.rank(query: notes[q].text, excluding: q, limit: 200).map(\.0)
        let truth = notes[q].links
        recall5 += Double(truth.intersection(Set(ranked.prefix(5))).count) / Double(truth.count)
        recall10 += Double(truth.intersection(Set(ranked.prefix(10))).count) / Double(truth.count)
        if let hit = ranked.firstIndex(where: { truth.contains($0) }) { mrr += 1.0 / Double(hit + 1) }
    }
    let n = Double(linked.count)
    results.append(Result(name: "BM25 (inverted index)", dimension: 0,
                          embedSeconds: build,
                          searchSeconds: Date().timeIntervalSince(searchStart),
                          failedChunks: 0,
                          // Postings are (Int32 doc, Float tf) = 8 bytes each.
                          bytesOnDisk: notes.count * 200 * 8,
                          meanRecall5: recall5 / n, meanRecall10: recall10 / n,
                          mrr: mrr / n, pooling: "note-level"))
}

let tfidf = TFIDFEmbedder()
tfidf.fit(documents: allChunks)
SelfTest.run(tfidf)
// Loading the transformer costs seconds even when it will not be used.
let sentenceModel = lexicalOnly ? nil : SentenceEmbedder()
if let sentenceModel { SelfTest.run(sentenceModel) }
let contextualModel = lexicalOnly ? nil : ContextualEmbedder()
if let contextualModel { SelfTest.run(contextualModel) }
print("")

guard !linked.isEmpty else {
    print("No resolvable links — nothing to measure.")
    exit(1)
}
// How much of the ground truth needs an index at all?
//
// The app already scans for *unlinked mentions*: a note whose text contains
// another note's title, with no link. If most author-authored links are between
// notes that already name each other, then no retrieval method — lexical or
// neural — is earning its keep on those pairs, and the honest denominator for
// "what does an index buy" is the rest.
var mentioned = 0, notMentioned = 0
for q in linked {
    let haystack = notes[q].text.lowercased()
    for target in notes[q].links {
        if haystack.contains(notes[target].title.lowercased()) { mentioned += 1 }
        else { notMentioned += 1 }
    }
}
let total = mentioned + notMentioned
print("""
## How much needs an index

Of \(total) linked pairs, \(mentioned) (\(String(format: "%.0f%%", Double(mentioned) / Double(total) * 100))) have the
target's title present verbatim in the source note's text even after link markup
is stripped — the existing unlinked-mention scan already finds those, with no
index of any kind. The remaining \(notMentioned) (\(String(format: "%.0f%%", Double(notMentioned) / Double(total) * 100)))
are the pairs a retrieval method has to earn.

""")

if dryRun { exit(0) }

// MARK: - Metrics

struct Result {
    var name: String
    var dimension: Int
    var embedSeconds: Double
    var searchSeconds: Double
    var failedChunks: Int
    var bytesOnDisk: Int
    var meanRecall5: Double
    var meanRecall10: Double
    var mrr: Double
    var pooling: String
}

/// Rank every other note for each query and score recall@k / MRR.
///
/// `maxPool` scores a note by its single best-matching chunk; the alternative
/// averages a note's chunks into one vector first. Both are measured because
/// the choice is a real design decision for the index and the usual assumption
/// (mean is fine) is worth checking rather than inheriting.
@MainActor func evaluate(chunkVectors: [[Float]?], dim: Int, maxPool: Bool) -> (Double, Double, Double, Double) {
    // Dense matrix of usable chunk vectors, plus the note each belongs to.
    var matrix = [Float]()
    var chunkNote = [Int]()
    matrix.reserveCapacity(chunkVectors.count * dim)
    var noteVectors = [Int: [Float]]()

    for i in notes.indices {
        var mean = [Float](repeating: 0, count: dim)
        var n = 0
        for c in notes[i].chunkRange {
            guard let v = chunkVectors[c] else { continue }
            if maxPool {
                matrix += v
                chunkNote.append(i)
            }
            vDSP_vadd(mean, 1, v, 1, &mean, 1, vDSP_Length(dim))
            n += 1
        }
        guard n > 0 else { continue }
        if !maxPool {
            var d = Float(n)
            vDSP_vsdiv(mean, 1, &d, &mean, 1, vDSP_Length(dim))
            l2Normalise(&mean)
            matrix += mean
            chunkNote.append(i)
        }
        noteVectors[i] = mean
    }

    let rows = chunkNote.count
    guard rows > 0 else { return (0, 0, 0, 0) }

    var recall5 = 0.0, recall10 = 0.0, mrr = 0.0
    let searchStart = Date()

    // Reused across queries.
    var scores = [Float](repeating: 0, count: rows)
    var best = [Float](repeating: -2, count: notes.count)

    for q in linked {
        // Query vectors: this note's chunks (max-pool) or its mean vector.
        var queryRows = [Float]()
        var queryCount = 0
        if maxPool {
            for c in notes[q].chunkRange {
                if let v = chunkVectors[c] { queryRows += v; queryCount += 1 }
            }
        } else if let v = noteVectors[q] {
            queryRows += v; queryCount = 1
        }
        guard queryCount > 0 else { continue }

        for i in best.indices { best[i] = -2 }

        // scores = matrix (rows×dim) · queryRow (dim) — one GEMV per query row.
        for r in 0..<queryCount {
            queryRows.withUnsafeBufferPointer { qb in
                matrix.withUnsafeBufferPointer { mb in
                    cblas_sgemv(CblasRowMajor, CblasNoTrans,
                                Int32(rows), Int32(dim), 1.0,
                                mb.baseAddress!, Int32(dim),
                                qb.baseAddress! + r * dim, 1, 0.0,
                                &scores, 1)
                }
            }
            for k in 0..<rows {
                let note = chunkNote[k]
                if scores[k] > best[note] { best[note] = scores[k] }
            }
        }

        // Rank, excluding the query itself.
        best[q] = -2
        var ranked = Array(best.enumerated().filter { $0.element > -2 })
        ranked.sort { $0.element > $1.element }

        let truth = notes[q].links
        let top5 = Set(ranked.prefix(5).map(\.offset))
        let top10 = Set(ranked.prefix(10).map(\.offset))
        recall5 += Double(truth.intersection(top5).count) / Double(truth.count)
        recall10 += Double(truth.intersection(top10).count) / Double(truth.count)
        if let firstHit = ranked.firstIndex(where: { truth.contains($0.offset) }) {
            mrr += 1.0 / Double(firstHit + 1)
        }
    }

    let n = Double(linked.count)
    return (recall5 / n, recall10 / n, mrr / n, Date().timeIntervalSince(searchStart))
}

/// Embed every chunk, timing it.
@MainActor func embedAll(_ embedder: Embedder) -> ([[Float]?], Double, Int) {
    let start = Date()
    var out = [[Float]?](repeating: nil, count: allChunks.count)
    var failed = 0
    for (i, chunk) in allChunks.enumerated() {
        // Each `vector(for:)` allocates Objective-C temporaries. With no pool
        // to drain them, 29,361 iterations of top-level code accumulate every
        // one until the process dies — which is exactly how the first full run
        // ended: `std::bad_alloc` at chunk 26,000, after 18 minutes of work,
        // with the shell reporting exit 0 because the abort was the *program's*.
        autoreleasepool {
            if let v = embedder.vector(for: chunk) { out[i] = v } else { failed += 1 }
        }
        if i % 2000 == 1999 { stamp("  \(embedder.name): \(i + 1)/\(allChunks.count)") }
    }
    return (out, Date().timeIntervalSince(start), failed)
}

// MARK: - Run

var results: [Result] = []

// Must run *after* `results` exists: top-level code initialises globals in
// source order, so calling this any earlier appends to a variable that has not
// been created yet.
runBM25()
runWholeNoteTFIDF()
runCappedWholeNoteTFIDF()

@MainActor func run(_ embedder: Embedder) {
    stamp("embedding with \(embedder.name)…")
    let (vectors, seconds, failed) = embedAll(embedder)
    let usable = vectors.compactMap { $0 }.count
    guard usable > 0 else {
        stamp("  \(embedder.name) produced no vectors — skipped")
        return
    }
    let dim = embedder.dimension
    for pooling in ["max-over-chunks", "mean-of-chunks"] {
        let maxPool = pooling == "max-over-chunks"
        let (r5, r10, mrr, searchSeconds) = evaluate(chunkVectors: vectors, dim: dim, maxPool: maxPool)
        results.append(Result(
            name: embedder.name, dimension: dim,
            embedSeconds: seconds, searchSeconds: searchSeconds, failedChunks: failed,
            // Float32 on disk, which is what the index would store.
            bytesOnDisk: (maxPool ? usable : notes.count) * dim * 4,
            meanRecall5: r5, meanRecall10: r10, mrr: mrr, pooling: pooling))
    }
}

run(tfidf)

if lexicalOnly {
    // Neural numbers already recorded in docs/semantic-retrieval-benchmark.md.
} else if let sentenceModel {
    run(sentenceModel)
} else {
    print("> `NLEmbedding.sentenceEmbedding(for: .english)` unavailable on this system.\n")
}

if lexicalOnly {
} else if let contextualModel {
    run(contextualModel)
} else {
    print("> `NLContextualEmbedding` unavailable on this system.\n")
}

// MARK: - Report

@MainActor func pct(_ d: Double) -> String { String(format: "%.1f%%", d * 100) }

print("## Results\n")
print("| Backend | Pooling | dim | recall@5 | recall@10 | MRR | build | search | index size |")
print("|---|---|---:|---:|---:|---:|---:|---:|---:|")
for r in results.sorted(by: { $0.meanRecall10 > $1.meanRecall10 }) {
    let mb = Double(r.bytesOnDisk) / 1_048_576
    print("| \(r.name) | \(r.pooling) | \(r.dimension) | \(pct(r.meanRecall5)) | \(pct(r.meanRecall10)) | \(String(format: "%.3f", r.mrr)) | \(String(format: "%.1f", r.embedSeconds))s | \(String(format: "%.2f", r.searchSeconds))s | \(String(format: "%.1f", mb)) MB |")
}

print("\n### Per-note cost, extrapolated\n")
for r in results where r.pooling == "max-over-chunks" {
    let perNote = r.embedSeconds / Double(max(notes.count, 1))
    print("- **\(r.name)**: \(String(format: "%.1f", perNote * 1000))ms/note → \(String(format: "%.1f", perNote * 10_000 / 60))min for a 10,000-note vault"
          + (r.failedChunks > 0 ? "; \(r.failedChunks) chunks returned no vector" : ""))
}
