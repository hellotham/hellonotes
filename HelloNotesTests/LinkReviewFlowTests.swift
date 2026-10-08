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
//  Whether the note changed is asked of its text version, as the shell asks
//  it: an editor holding the reviewed text, and the same editor after a change.
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

    /// An editor holding `text`, as the review found it.
    private func editor(holding text: String) -> EditorModel {
        let editor = EditorModel()
        editor.text = text
        return editor
    }

    @Test func acceptingNothingChangesNothing() {
        let editor = editor(holding: "a")
        let outcome = LinkReviewFlow.apply([], reviewed: editor.textVersion, now: editor.textVersion, to: "a")
        #expect(outcome == .nothing)
    }

    /// The guard: the buffer moved under the review, so nothing is applied.
    @Test func aChangedNoteRefusesTheEditRatherThanGuessing() {
        let editor = editor(holding: "See the Roadmap for details.")
        let reviewed = editor.textVersion
        let accepted = [proposal("Roadmap", at: 8, target: "Roadmap")]

        editor.text = "Something else entirely."
        let outcome = LinkReviewFlow.apply(accepted, reviewed: reviewed,
                                           now: editor.textVersion, to: editor.text)
        #expect(outcome == .stale(message: LinkReviewFlow.staleMessage))
    }

    /// Another note's editor is not the note reviewed, whatever its count says.
    @Test func anotherNotesEditorIsStale() {
        let reviewedEditor = editor(holding: "See the Roadmap for details.")
        let other = editor(holding: "See the Roadmap for details.")
        let accepted = [proposal("Roadmap", at: 8, target: "Roadmap")]

        let outcome = LinkReviewFlow.apply(accepted, reviewed: reviewedEditor.textVersion,
                                           now: other.textVersion, to: other.text)
        #expect(outcome == .stale(message: LinkReviewFlow.staleMessage))
    }

    /// Unchanged text applies, and applies to the right words.
    @Test func anUnchangedNoteAppliesTheAcceptedLinks() throws {
        let text = "See the Roadmap for details."
        let editor = editor(holding: text)
        let accepted = [proposal("Roadmap", at: 8, target: "Roadmap")]

        let outcome = LinkReviewFlow.apply(accepted, reviewed: editor.textVersion,
                                           now: editor.textVersion, to: editor.text)
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
        let editor = editor(holding: reviewed)
        let version = editor.textVersion
        let accepted = [proposal("Roadmap", at: 8, target: "Roadmap")]

        editor.text = " " + reviewed
        let outcome = LinkReviewFlow.apply(accepted, reviewed: version,
                                           now: editor.textVersion, to: editor.text)
        #expect(outcome == .stale(message: LinkReviewFlow.staleMessage))
    }

    @Test func beginningWithNoCollectionYieldsNoReview() async {
        let request = await LinkReviewFlow.begin(text: "anything", version: nil, noteURL: nil, in: nil)
        #expect(request == nil)
    }
}
