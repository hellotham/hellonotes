//
//  LinkProposalTests.swift
//  HelloNotesTests
//
//  Created by Chris Tham on 16/8/2026.
//

import Testing
import Foundation
@testable import HelloNotes

/// Auto-linking's contract.
///
/// Every one of these is a way the feature could quietly corrupt a note rather
/// than fail visibly — a link inside a code fence changes what the code says, a
/// second link to an already-linked note doubles the graph edge, and applying
/// edits front-to-back mangles every range after the first. A wrong link is
/// worse than a missing one because nobody re-reads a link they accepted.
struct LinkProposalTests {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/vault/\(name).md") }

    private func candidate(_ title: String, aliases: [String] = []) -> LinkCandidate {
        LinkCandidate(title: title, url: url(title), aliases: aliases)
    }

    // MARK: - Finding

    @Test func proposesAPlainMention() {
        let proposals = LinkProposals.proposals(
            in: "I have been building a Second Brain for years.",
            candidates: [candidate("Second Brain")])
        #expect(proposals.count == 1)
        #expect(proposals.first?.phrase == "Second Brain")
        #expect(proposals.first?.targetTitle == "Second Brain")
    }

    /// The replacement has to preserve the sentence, so the phrase keeps the
    /// author's casing and the link gets an alias.
    @Test func matchingIsCaseInsensitiveButThePhraseKeepsItsCasing() {
        let proposals = LinkProposals.proposals(
            in: "my second brain is a mess",
            candidates: [candidate("Second Brain")])
        #expect(proposals.first?.phrase == "second brain")
        let applied = LinkProposals.apply(proposals, to: "my second brain is a mess")
        #expect(applied == "my [[Second Brain|second brain]] is a mess")
    }

    @Test func matchesWholeWordsOnly() {
        // "Brains" must not match a note called "Brain".
        let proposals = LinkProposals.proposals(
            in: "Brains and brainstorming are different.",
            candidates: [candidate("Brain")])
        #expect(proposals.isEmpty)
    }

    @Test func anAliasCountsAsAMention() {
        let proposals = LinkProposals.proposals(
            in: "The slip box method is what I use.",
            candidates: [candidate("Zettelkasten", aliases: ["slip box"])])
        #expect(proposals.first?.targetTitle == "Zettelkasten")
        #expect(proposals.first?.phrase == "slip box")
    }

    /// A note titled "A" or "of" would otherwise link half the vault.
    @Test func veryShortTitlesAreNeverProposed() {
        let proposals = LinkProposals.proposals(
            in: "A cat sat on a mat, of course.",
            candidates: [candidate("A"), candidate("of")])
        #expect(proposals.isEmpty)
    }

    /// Linking every instance is what makes auto-linked vaults unreadable.
    @Test func onlyTheFirstOccurrenceIsProposed() {
        let text = "Second Brain here. Second Brain again. And Second Brain once more."
        let proposals = LinkProposals.proposals(in: text, candidates: [candidate("Second Brain")])
        #expect(proposals.count == 1)
        #expect(proposals.first?.range.location == 0)
    }

    @Test func aTargetTheNoteAlreadyLinksIsNotProposedAgain() {
        let text = "I use [[Second Brain]] daily, and my Second Brain is growing."
        let proposals = LinkProposals.proposals(in: text, candidates: [candidate("Second Brain")])
        #expect(proposals.isEmpty)
    }

    @Test func aNoteIsNeverProposedAsALinkToItself() {
        let proposals = LinkProposals.proposals(
            in: "This note about Second Brain refers to itself.",
            candidates: [candidate("Second Brain")],
            excludingNoteAt: url("Second Brain"))
        #expect(proposals.isEmpty)
    }

    @Test func declinedProposalsDoNotComeBack() {
        let text = "My second brain is a mess."
        let key = LinkProposals.declineKey(phrase: "second brain", target: "Second Brain")
        let proposals = LinkProposals.proposals(
            in: text, candidates: [candidate("Second Brain")], declined: [key])
        #expect(proposals.isEmpty)
    }

    @Test func proposalsArriveInReadingOrder() {
        let text = "First we discuss Zettelkasten, then later the Second Brain."
        let proposals = LinkProposals.proposals(
            in: text, candidates: [candidate("Second Brain"), candidate("Zettelkasten")])
        #expect(proposals.map(\.targetTitle) == ["Zettelkasten", "Second Brain"])
    }

    // MARK: - Where a link must never go
    //
    // Each of these inserts markup into a span where it would be meaningless or
    // destructive. The code-fence case is the worst: it changes what the code
    // says, in a file the user may run.

    @Test func neverInsideAFencedCodeBlock() {
        let text = """
        Prose mentioning nothing.

        ```swift
        let secondBrain = SecondBrain()   // Second Brain
        ```
        """
        #expect(LinkProposals.proposals(in: text, candidates: [candidate("Second Brain")]).isEmpty)
    }

    @Test func neverInsideInlineCode() {
        let text = "Call `Second Brain` to initialise it."
        #expect(LinkProposals.proposals(in: text, candidates: [candidate("Second Brain")]).isEmpty)
    }

    @Test func neverInsideFrontMatter() {
        let text = """
        ---
        title: Second Brain
        ---

        Body without any mention.
        """
        #expect(LinkProposals.proposals(in: text, candidates: [candidate("Second Brain")]).isEmpty)
    }

    @Test func neverInsideAHeading() {
        let text = "## Second Brain\n\nBody without any mention."
        #expect(LinkProposals.proposals(in: text, candidates: [candidate("Second Brain")]).isEmpty)
    }

    @Test func neverInsideMath() {
        let text = "Inline $Second Brain$ and display:\n\n$$\nSecond Brain\n$$\n"
        #expect(LinkProposals.proposals(in: text, candidates: [candidate("Second Brain")]).isEmpty)
    }

    @Test func neverInsideAnExistingLinkOrURL() {
        let text = "See [Second Brain](https://example.com/Second%20Brain) and https://x.com/Second-Brain"
        #expect(LinkProposals.proposals(in: text, candidates: [candidate("Second Brain")]).isEmpty)
    }

    @Test func neverInsideATag() {
        let text = "Filed under #second-brain today."
        #expect(LinkProposals.proposals(in: text, candidates: [candidate("second-brain")]).isEmpty)
    }

    /// A four-space indent after a blank line is code. A four-space indent
    /// *continuing a bullet* is prose — and treating it as code would silently
    /// suppress proposals across whole notes.
    @Test func indentedCodeIsExcludedButWrappedListItemsAreNot() {
        let code = "Intro.\n\n    let x = SecondBrain   // Second Brain\n\nOutro."
        #expect(LinkProposals.proposals(in: code, candidates: [candidate("Second Brain")]).isEmpty)

        let list = "- A bullet that runs on\n    and mentions Second Brain here\n"
        #expect(!LinkProposals.proposals(in: list, candidates: [candidate("Second Brain")]).isEmpty)
    }

    /// Two separate fences must not merge into one zone that swallows the prose
    /// between them — a greedy pattern would suppress every proposal in it.
    @Test func proseBetweenTwoCodeFencesIsStillProposed() {
        let text = """
        ```
        let a = 1
        ```

        My Second Brain lives here.

        ```
        let b = 2
        ```
        """
        #expect(LinkProposals.proposals(in: text, candidates: [candidate("Second Brain")]).count == 1)
    }

    // MARK: - Applying

    /// Inserting at an earlier offset shifts every later range. Applying
    /// forwards corrupts the note from the second link onward, and the damage
    /// looks like a parsing bug rather than an ordering one.
    @Test func multipleProposalsApplyWithoutCorruptingLaterRanges() {
        let text = "Zettelkasten first, Second Brain second, Deep Work third."
        let proposals = LinkProposals.proposals(
            in: text,
            candidates: [candidate("Zettelkasten"), candidate("Second Brain"), candidate("Deep Work")])
        #expect(proposals.count == 3)
        let applied = LinkProposals.apply(proposals, to: text)
        #expect(applied == "[[Zettelkasten]] first, [[Second Brain]] second, [[Deep Work]] third.")
    }

    @Test func applyingNothingChangesNothing() {
        let text = "Untouched prose."
        #expect(LinkProposals.apply([], to: text) == text)
    }

    /// A proposal generated against older text must not corrupt a note that has
    /// since been edited shorter.
    @Test func aStaleRangePastTheEndIsSkippedRatherThanCrashing() {
        let stale = LinkProposal(range: NSRange(location: 500, length: 12),
                                 phrase: "Second Brain", targetTitle: "Second Brain",
                                 targetURL: url("Second Brain"))
        #expect(LinkProposals.apply([stale], to: "Short.") == "Short.")
    }
}
