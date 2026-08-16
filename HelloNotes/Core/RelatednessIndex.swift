//
//  RelatednessIndex.swift
//  HelloNotes
//
//  Created by Chris Tham on 16/8/2026.
//
//  "Which other notes is this note about the same things as?"
//
//  The answer feeds link suggestion, related notes, and retrieval for Ask
//  Library — all of which previously either scanned every title or stuffed the
//  model's context with whatever fitted.
//
//  ## Why this is a protocol
//
//  Two reasons, and both are about the scheme changing under us rather than
//  about tidiness.
//
//  **Frameworks.** Second-brain methods are coming, and a Zettelkasten
//  collection does not mean the same thing by "related" as a PARA one: the first
//  wants conceptual adjacency between atomic notes, the second wants notes
//  serving the same project. That is a different *scorer* over the same corpus,
//  chosen per collection.
//
//  **Better models.** `docs/semantic-retrieval-benchmark.md` measured Apple's
//  two on-device embedding models against a term-weighted lexical index on a
//  real 2,027-note vault, and the lexical index won on quality *and* cost —
//  52.1% recall@10 against 38.3%, built in 2.4 seconds against 951. That is a
//  statement about today's on-device models, not a law. Pairing this protocol
//  with `LLM/ProviderCapabilities.swift` means adopting a better one is a
//  re-measurement, not a rewrite.
//

import Foundation

/// One ranked neighbour.
struct RelatedNote: Equatable, Sendable {
    let url: URL
    let title: String
    /// Cosine similarity in [0, 1]. Comparable *within* one query's results;
    /// not a probability, and not comparable across schemes.
    let score: Double
}

/// One note, as a retrieval index sees it.
struct RelatednessDocument: Sendable {
    let url: URL
    let title: String
    /// Already passed through `RetrievalText.prepare`.
    let text: String
}

/// Ranks a collection's notes by relatedness to a piece of text.
///
/// An **actor**, because building this reads and tokenises every note — 2.2
/// seconds for a 2,000-note vault, measured — and none of that may happen on the
/// main actor. Actor isolation makes that structural rather than a rule someone
/// has to remember, and avoids handing a mutable class across isolation
/// boundaries with an `@unchecked Sendable` and a hopeful comment.
protocol RelatednessIndex: Actor {
    /// Identifies the scheme. Persisted with any cached index, so switching
    /// schemes invalidates rather than silently mixes.
    static var schemeID: String { get }

    func rebuild(with documents: [RelatednessDocument])
    func update(_ document: RelatednessDocument)
    func remove(_ url: URL)

    /// The `limit` notes most related to `text`, best first.
    func related(to text: String, excluding: URL?, limit: Int) -> [RelatedNote]
}

// MARK: - The measured default

/// TF-IDF over hashed terms, one L2-normalised sparse vector per note, ranked by
/// cosine. The scheme that won the benchmark.
///
/// Everything here is a measured choice, so each is noted where it is made
/// rather than left as folklore.
actor TermVectorRelatednessIndex: RelatednessIndex {
    static let schemeID = "tfidf-hashed-2048-v1"

    /// Feature buckets. 2,048 is what was measured; collisions at this width are
    /// common but harmless — a collision blends two rare terms, and the ranking
    /// is over sums of hundreds of terms.
    private let dimension: Int

    private struct Entry {
        let url: URL
        let title: String
        /// (bucket, term count), sorted by bucket. Sparse: a note touches a few
        /// hundred buckets, not 2,048, so this is ~10× smaller than a dense
        /// vector and cheaper to intersect.
        let counts: [(bucket: Int32, count: Float)]
    }

    private var entries: [Entry] = []
    private var indexByURL: [URL: Int] = [:]

    /// Derived state, rebuilt lazily — see `refreshDerivedIfNeeded`.
    private var documentFrequency: [Int32: Int] = [:]
    private var postings: [Int32: [(entry: Int32, count: Float)]] = [:]
    private var norms: [Float] = []
    private var derivedIsStale = true

    init(dimension: Int = 2048) {
        self.dimension = dimension
    }

    // MARK: Building

    func rebuild(with documents: [RelatednessDocument]) {
        entries = documents.map { Entry(url: $0.url, title: $0.title, counts: Self.counts(of: $0.text, dimension: dimension)) }
        indexByURL = Dictionary(entries.enumerated().map { ($1.url, $0) }, uniquingKeysWith: { a, _ in a })
        derivedIsStale = true
    }

    func update(_ document: RelatednessDocument) {
        let entry = Entry(url: document.url, title: document.title,
                          counts: Self.counts(of: document.text, dimension: dimension))
        if let i = indexByURL[document.url] {
            entries[i] = entry
        } else {
            indexByURL[document.url] = entries.count
            entries.append(entry)
        }
        derivedIsStale = true
    }

    func remove(_ url: URL) {
        guard let i = indexByURL[url] else { return }
        entries.remove(at: i)
        // Indices after the removed one shift, so the map is rebuilt rather than
        // patched — patching it is where an off-by-one silently returns the
        // wrong note's title next to the right note's score.
        indexByURL = Dictionary(entries.enumerated().map { ($1.url, $0) }, uniquingKeysWith: { a, _ in a })
        derivedIsStale = true
    }

    // MARK: Querying

    func related(to text: String, excluding: URL?, limit: Int) -> [RelatedNote] {
        refreshDerivedIfNeeded()
        guard !entries.isEmpty, limit > 0 else { return [] }

        let queryCounts = Self.counts(of: text, dimension: dimension)
        guard !queryCounts.isEmpty else { return [] }

        // Query vector: tf × idf, L2-normalised.
        var queryNorm: Float = 0
        var weighted: [(bucket: Int32, weight: Float)] = []
        weighted.reserveCapacity(queryCounts.count)
        for (bucket, count) in queryCounts {
            let w = count * idf(bucket)
            guard w > 0 else { continue }
            weighted.append((bucket, w))
            queryNorm += w * w
        }
        queryNorm = sqrt(queryNorm)
        guard queryNorm > 0 else { return [] }

        // Accumulate over the inverted index: only notes sharing a term are
        // touched at all, which is what keeps this O(matches) rather than
        // O(collection) on every keystroke-adjacent call.
        var scores = [Float](repeating: 0, count: entries.count)
        for (bucket, queryWeight) in weighted {
            guard let list = postings[bucket] else { continue }
            let bucketIDF = idf(bucket)
            for (entry, count) in list {
                scores[Int(entry)] += queryWeight * count * bucketIDF
            }
        }

        let excludedIndex = excluding.flatMap { indexByURL[$0] }
        var ranked: [(Int, Float)] = []
        ranked.reserveCapacity(min(entries.count, 256))
        for (i, raw) in scores.enumerated() where raw > 0 && i != excludedIndex {
            let norm = norms[i]
            guard norm > 0 else { continue }
            ranked.append((i, raw / (norm * queryNorm)))
        }
        ranked.sort { $0.1 > $1.1 }

        return ranked.prefix(limit).map {
            RelatedNote(url: entries[$0.0].url, title: entries[$0.0].title, score: Double($0.1))
        }
    }

    // MARK: Derived state

    /// Document frequencies, postings and norms all depend on the *whole*
    /// corpus, so any single edit invalidates them. Rebuilding is one pass over
    /// the postings — a few milliseconds for a 2,000-note vault — so it happens
    /// on the next query rather than on every save. A note saved five times
    /// while typing then costs one rebuild, not five.
    private func refreshDerivedIfNeeded() {
        guard derivedIsStale else { return }
        defer { derivedIsStale = false }

        documentFrequency.removeAll(keepingCapacity: true)
        postings.removeAll(keepingCapacity: true)
        norms = [Float](repeating: 0, count: entries.count)

        for (i, entry) in entries.enumerated() {
            for (bucket, count) in entry.counts {
                documentFrequency[bucket, default: 0] += 1
                postings[bucket, default: []].append((Int32(i), count))
            }
        }
        // Norms need the finished document frequencies, so this cannot fold
        // into the loop above.
        for (i, entry) in entries.enumerated() {
            var sum: Float = 0
            for (bucket, count) in entry.counts {
                let w = count * idf(bucket)
                sum += w * w
            }
            norms[i] = sqrt(sum)
        }
    }

    /// `log(N / (1 + df)) + 1` — the form the benchmark measured. The `+1` keeps
    /// a term that appears everywhere at a small positive weight instead of
    /// zero, so a note made entirely of common words still ranks *something*
    /// rather than returning nothing at all.
    private func idf(_ bucket: Int32) -> Float {
        let n = Float(max(entries.count, 1))
        return log(n / Float(1 + (documentFrequency[bucket] ?? 0))) + 1
    }

    // MARK: Terms

    /// Term counts for `text`, as a sorted sparse vector.
    nonisolated private static func counts(of text: String, dimension: Int) -> [(bucket: Int32, count: Float)] {
        var counts: [Int32: Float] = [:]
        for term in RetrievalText.terms(in: text) {
            counts[bucket(term, dimension: dimension), default: 0] += 1
        }
        return counts.sorted { $0.key < $1.key }.map { (bucket: $0.key, count: $0.value) }
    }

    /// FNV-1a, **not** `String.hashValue`.
    ///
    /// Swift's `Hashable` is seeded per process, so an index built with it means
    /// something different on every launch — fine in memory, silently wrong the
    /// moment it is persisted. This repo has paid for that once already
    /// (`WalkCheckpointStore`).
    nonisolated static func bucket(_ term: String, dimension: Int) -> Int32 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in term.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Int32(hash % UInt64(dimension))
    }
}
