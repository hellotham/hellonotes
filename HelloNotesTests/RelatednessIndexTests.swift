//
//  RelatednessIndexTests.swift
//  HelloNotesTests
//
//  Created by Chris Tham on 16/8/2026.
//

import Testing
import Foundation
@testable import HelloNotes

/// The retrieval index's contract.
///
/// Ranking quality is measured on a real vault by `scratchpad/EmbedBench`
/// (`docs/semantic-retrieval-benchmark.md`) — a unit test cannot say whether
/// 52% recall is good. What it *can* pin is everything that would make the
/// numbers a lie: stale derived state after an edit, a shifted index returning
/// the wrong note's title, a hash that changes between runs.
struct RelatednessIndexTests {

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/vault/\(name).md")
    }

    private func doc(_ name: String, _ text: String) -> RelatednessDocument {
        RelatednessDocument(url: url(name), title: name, text: text)
    }

    private func index(_ documents: [RelatednessDocument]) async -> TermVectorRelatednessIndex {
        let index = TermVectorRelatednessIndex()
        await index.rebuild(with: documents)
        return index
    }

    // MARK: - Ranking

    @Test func ranksTheNoteSharingDistinctiveTermsFirst() async {
        let index = await index([
            doc("Zettelkasten", "Atomic notes linked to one another so structure emerges from connections."),
            doc("Slip Box", "Each idea on its own short note, connected by references, structure emerging from links."),
            doc("Sourdough", "Feed the starter twice a day at room temperature until it doubles reliably."),
        ])
        let results = await index.related(to: "notes linked together so that structure emerges",
                                    excluding: nil, limit: 3)
        #expect(results.first?.title == "Zettelkasten")
        #expect(results.first!.score > (results.last?.score ?? 1))
        #expect(!results.contains { $0.title == "Sourdough" })
    }

    /// **A known limitation, pinned deliberately.**
    ///
    /// This index matches terms, not meaning. Two notes that say the same thing
    /// in different words — the case a semantic index is supposed to win — are
    /// *not* reliably ranked together, and the first draft of the test above
    /// assumed otherwise until it failed.
    ///
    /// It is here on purpose. `docs/semantic-retrieval-benchmark.md` measured
    /// this trade honestly: Apple's on-device embedding models beat this scheme
    /// on paraphrase (6/6 triples against 5/6, a margin four times larger) and
    /// still lost overall by 1.4× on a real vault, because real links run on
    /// shared distinctive terms. If a future on-device model changes that, this
    /// is the test that should start failing — and that failure is the signal to
    /// re-run the benchmark, not to delete the test.
    @Test func paraphraseWithoutSharedTermsIsNotFound() async {
        let index = await index([
            doc("Deep Work", "Sustained periods of undistracted concentration on a demanding task."),
            doc("Unrelated", "Beetroot grows best in loose, stone-free soil without crowding."),
        ])
        // Same idea as "Deep Work", almost no vocabulary in common.
        let results = await index.related(to: "long uninterrupted stretches of focus with notifications off",
                                    excluding: nil, limit: 2)
        #expect(results.isEmpty || results.first?.title != "Deep Work")
    }

    /// A term in every note carries almost no information; a term in one note
    /// carries a lot. Without IDF the common word would dominate, which is
    /// precisely how the app's previous occurrence-counting retrieval behaved.
    @Test func rareTermsOutweighCommonOnes() async {
        let common = "notes notes notes"
        let index = await index([
            doc("A", "\(common) Bronkhorst"),
            doc("B", "\(common) \(common)"),
            doc("C", "\(common)"),
            doc("D", "\(common)"),
        ])
        let results = await index.related(to: "Bronkhorst notes", excluding: nil, limit: 4)
        #expect(results.first?.title == "A")
    }

    @Test func theQueriedNoteIsExcludedFromItsOwnResults() async {
        let index = await index([
            doc("A", "Spaced repetition schedules reviews at increasing intervals."),
            doc("B", "Spaced repetition expands the gap between reviews."),
        ])
        let results = await index.related(to: "Spaced repetition schedules reviews at increasing intervals.",
                                    excluding: url("A"), limit: 5)
        #expect(!results.contains { $0.title == "A" })
        #expect(results.contains { $0.title == "B" })
    }

    @Test func aQueryWithNoSharedTermsReturnsNothing() async {
        let index = await index([doc("A", "Sanskrit manuscripts and their transmission.")])
        #expect(await index.related(to: "carburettor gearbox suspension", excluding: nil, limit: 5).isEmpty)
    }

    @Test func anEmptyIndexAnswersEmptyRatherThanCrashing() async {
        let index = TermVectorRelatednessIndex()
        #expect(await index.related(to: "anything at all", excluding: nil, limit: 5).isEmpty)
    }

    // MARK: - Derived state after edits
    //
    // Document frequency, postings and norms depend on the whole corpus, so
    // every edit invalidates them. These are the tests that catch a stale cache.

    @Test func anUpdatedNoteIsRankedByItsNewText() async {
        let index = await index([
            doc("A", "Sourdough starter feeding schedule and hydration."),
            doc("B", "Spaced repetition and memory."),
        ])
        #expect(await index.related(to: "memory and repetition", excluding: nil, limit: 1).first?.title == "B")

        await index.update(doc("A", "Spaced repetition, memory, and forgetting curves."))
        let after = await index.related(to: "memory and repetition", excluding: nil, limit: 2)
        #expect(after.contains { $0.title == "A" })
    }

    @Test func anAddedNoteBecomesReachableImmediately() async {
        let index = await index([doc("A", "Sourdough starter feeding schedule.")])
        await index.update(doc("New", "Sanskrit manuscripts and Pali texts."))
        let results = await index.related(to: "Pali manuscripts", excluding: nil, limit: 3)
        #expect(results.first?.title == "New")
    }

    @Test func aRemovedNoteDisappearsFromResults() async {
        let index = await index([
            doc("A", "Sanskrit manuscripts and Pali texts."),
            doc("B", "Pali texts and their commentaries."),
        ])
        await index.remove(url("A"))
        let results = await index.related(to: "Pali manuscripts", excluding: nil, limit: 5)
        #expect(!results.contains { $0.title == "A" })
    }

    /// Removal shifts every later entry's index. If the URL map is patched
    /// rather than rebuilt, results keep the right *scores* while reporting the
    /// wrong *titles* — a failure that looks like bad ranking, not a bug.
    @Test func removalKeepsTitlesAlignedWithScores() async {
        let index = await index([
            doc("First", "alpha alpha unique-first"),
            doc("Second", "beta beta unique-second"),
            doc("Third", "gamma gamma unique-third"),
        ])
        await index.remove(url("First"))
        let results = await index.related(to: "unique-third gamma", excluding: nil, limit: 3)
        #expect(results.first?.title == "Third")
        #expect(results.first?.url == url("Third"))
    }

    // MARK: - Stability

    /// The bucket hash must not be `String.hashValue`: that is seeded per
    /// process, so a persisted index would mean something different on every
    /// launch. Same string, same bucket, forever.
    @Test func bucketHashingIsStableAndInRange() {
        let expected = TermVectorRelatednessIndex.bucket("zettelkasten", dimension: 2048)
        #expect(TermVectorRelatednessIndex.bucket("zettelkasten", dimension: 2048) == expected)
        #expect((0..<2048).contains(Int(expected)))
        for term in ["a", "", "Pāli", "second-brain", String(repeating: "x", count: 500)] {
            let b = TermVectorRelatednessIndex.bucket(term, dimension: 2048)
            #expect((0..<2048).contains(Int(b)), "\(term) hashed out of range")
        }
    }

    // MARK: - Text preparation

    /// The rule that keeps link suggestion honest: a note's vector must not be
    /// made of the titles of notes it already links to.
    @Test func linkMarkupContributesDisplayTextNotTargets() {
        let prepared = RetrievalText.prepare("I keep a [[Second Brain|second brain]] and a [[Zettelkasten]].")
        #expect(prepared.contains("second brain"))
        #expect(!prepared.contains("Second Brain"))
        #expect(!prepared.contains("Zettelkasten"))
    }

    @Test func frontMatterAndFencedCodeAreNotContent() {
        let prepared = RetrievalText.prepare("""
        ---
        title: Thing
        tags: [alpha]
        ---
        Real prose here.

        ```swift
        let secretIdentifier = 42
        ```
        """)
        #expect(prepared.contains("Real prose"))
        #expect(!prepared.contains("secretIdentifier"))
        #expect(!prepared.contains("tags"))
    }

    /// The cap is what carries the retrieval win, so it has to actually hold.
    @Test func preparedTextIsCapped() {
        let huge = String(repeating: "sanskrit manuscript ", count: 100_000)
        #expect(RetrievalText.prepare(huge).count <= RetrievalText.maxCharacters)
    }

    @Test func stopWordsAndShortTokensAreNotTerms() {
        let terms = RetrievalText.terms(in: "The cat and the dog are in a box")
        #expect(!terms.contains("the"))
        #expect(!terms.contains("and"))
        #expect(!terms.contains("are"))
        #expect(terms.contains("cat"))
        #expect(terms.contains("dog"))
        #expect(terms.contains("box"))
    }
}
