//
//  LinkReviewFlowTests.swift
//  HelloNotesTests
//
//  The re-derivation guard, on both platforms.
//
//  A link proposal is a character range, and a range only describes the text it
//  was computed from. If the note changes while the review sheet is open,
//  applying the accepted proposals would link *different words* — silently, in
//  someone's notes. Both shells had this guard and neither had a test for it,
//  because it lived inside a `private func` on a view struct.
//

import Foundation
import Testing
@testable import HelloNotes

@MainActor
struct LinkReviewFlowTests {

    private func proposal(_ phrase: String, at location: Int, target: String) -> LinkProposal {
        LinkProposal(range: NSRange(location: location, length: (phrase as NSString).length),
                     phrase: phrase,
                     targetTitle: target,
                     targetURL: URL(fileURLWithPath: "/v/\(target).md"))
    }

    @Test func acceptingNothingChangesNothing() {
        let outcome = LinkReviewFlow.apply([], reviewedText: "a", currentText: "a")
        #expect(outcome == .nothing)
    }

    /// The guard: the buffer moved under the review, so nothing is applied.
    @Test func aChangedNoteRefusesTheEditRatherThanGuessing() {
        let reviewed = "See the Roadmap for details."
        let accepted = [proposal("Roadmap", at: 8, target: "Roadmap")]

        let outcome = LinkReviewFlow.apply(accepted,
                                           reviewedText: reviewed,
                                           currentText: "Something else entirely.")
        #expect(outcome == .stale(message: LinkReviewFlow.staleMessage))
    }

    /// Unchanged text applies, and applies to the right words.
    @Test func anUnchangedNoteAppliesTheAcceptedLinks() throws {
        let text = "See the Roadmap for details."
        let accepted = [proposal("Roadmap", at: 8, target: "Roadmap")]

        let outcome = LinkReviewFlow.apply(accepted, reviewedText: text, currentText: text)
        guard case .apply(let result) = outcome else {
            Issue.record("expected an edit, got \(outcome)"); return
        }
        #expect(result.contains("[[Roadmap]]"))
        #expect(result.hasPrefix("See the "))
        #expect(result.hasSuffix(" for details."))
    }

    /// Whitespace counts: "the same text" means byte-identical, because a range
    /// shifts by one when a character does.
    @Test func evenAOneCharacterChangeIsStale() {
        let reviewed = "See the Roadmap for details."
        let accepted = [proposal("Roadmap", at: 8, target: "Roadmap")]
        let outcome = LinkReviewFlow.apply(accepted,
                                           reviewedText: reviewed,
                                           currentText: " " + reviewed)
        #expect(outcome == .stale(message: LinkReviewFlow.staleMessage))
    }

    @Test func beginningWithNoCollectionYieldsNoReview() async {
        let request = await LinkReviewFlow.begin(text: "anything", noteURL: nil, in: nil)
        #expect(request == nil)
    }
}
