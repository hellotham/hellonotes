//
//  BM25.swift
//  EmbedBench
//
//  The other lexical candidate.
//
//  TF-IDF cosine won the first round, but it was the only lexical scheme in it.
//  BM25 is the standard for this shape of problem and differs in two ways that
//  should matter on this corpus: term frequency saturates (a note that says
//  "Sanskrit" forty times is not forty times more about Sanskrit), and document
//  length is normalised explicitly rather than by L2 norm — and this vault's
//  notes range from a paragraph to a converted book chapter.
//
//  It also suits an *incremental* index better, which is what the app needs:
//  scores are computed at query time from term frequencies and document
//  lengths, so adding or removing a note never invalidates other notes' stored
//  vectors the way a corpus-wide IDF renormalisation does.
//
//  Measured rather than assumed, for the same reason as everything else here.
//

import Foundation

/// Inverted index + BM25 scoring over the same chunks every other backend saw.
final class BM25Index {
    struct Posting { let doc: Int32; let tf: Float }

    private var postings: [Int: [Posting]] = [:]   // term bucket → postings
    private var docLength: [Float] = []
    private var averageLength: Float = 1
    private var docCount = 0

    /// Saturation and length-normalisation constants. The values Robertson's
    /// original work settled on and every implementation since has kept; not
    /// tuned here, because tuning on the same 520 pairs used to evaluate would
    /// be fitting the test set.
    private let k1: Float = 1.2
    private let b: Float = 0.75

    /// FNV-1a — stable across processes, unlike `String.hashValue`.
    static func bucket(_ term: String, modulo: Int) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in term.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Int(hash % UInt64(modulo))
    }

    private let dimension: Int
    init(dimension: Int = 1 << 20) { self.dimension = dimension }

    /// Add one document. Documents must be added in `doc` order.
    func add(doc: Int, text: String) {
        var counts: [Int: Float] = [:]
        var length: Float = 0
        for term in TFIDFEmbedder.terms(text) {
            counts[Self.bucket(term, modulo: dimension), default: 0] += 1
            length += 1
        }
        for (bucket, tf) in counts {
            postings[bucket, default: []].append(Posting(doc: Int32(doc), tf: tf))
        }
        while docLength.count <= doc { docLength.append(0) }
        docLength[doc] += length
        docCount = max(docCount, doc + 1)
    }

    func finalise() {
        let total = docLength.reduce(0, +)
        averageLength = docCount > 0 ? max(total / Float(docCount), 1) : 1
    }

    /// BM25 score of every document against `text`, as (doc, score), best first.
    func rank(query text: String, excluding: Int, limit: Int) -> [(Int, Float)] {
        var queryTerms: [Int: Float] = [:]
        for term in TFIDFEmbedder.terms(text) {
            queryTerms[Self.bucket(term, modulo: dimension), default: 0] += 1
        }
        var scores = [Float](repeating: 0, count: docCount)
        let n = Float(docCount)
        for (bucket, qtf) in queryTerms {
            guard let list = postings[bucket] else { continue }
            let df = Float(list.count)
            // Robertson/Sparck-Jones IDF, the `+0.5` form, floored at zero so a
            // term present in most documents cannot push a score *down*.
            let idf = max(0, log((n - df + 0.5) / (df + 0.5) + 1))
            guard idf > 0 else { continue }
            for p in list {
                let doc = Int(p.doc)
                let len = docLength[doc]
                let denominator = p.tf + k1 * (1 - b + b * len / averageLength)
                scores[doc] += idf * (p.tf * (k1 + 1)) / denominator * min(qtf, 3)
            }
        }
        scores[excluding] = -1
        return scores.enumerated()
            .filter { $0.element > 0 }
            .sorted { $0.element > $1.element }
            .prefix(limit)
            .map { ($0.offset, $0.element) }
    }
}
