//
//  CompletionChoiceTests.swift
//  HelloNotesTests
//
//  Which keys the list of suggestions by the caret takes, and when.
//
//  The list had no keyboard route at all (found by fact-checking the 1.3.3
//  website against the source; implemented.md §51.44). Giving it one means
//  taking keys from the text, so most of what is held here is what the list
//  must *not* take: Return with nothing chosen, and the arrows from a caret
//  that is only passing through a link.
//

import Foundation
import Testing
import MarkdownEditor
@testable import HelloNotes

@MainActor
struct CompletionChoiceTests {

    private func link(_ query: String, at location: Int = 10) -> EditorDocument.InlineContext {
        .init(kind: .wikiLink, range: NSRange(location: location, length: query.count + 2), query: query)
    }

    private func tag(_ query: String, at location: Int = 10) -> EditorDocument.InlineContext {
        .init(kind: .tag, range: NSRange(location: location, length: query.count + 1), query: query)
    }

    /// `[[`, typed: the list is live, nothing is chosen, and the arrows choose.
    @Test func typingALinkGivesTheArrowsToTheList() {
        let choice = CompletionChoice()
        choice.report(nil, revision: 1)             // "["
        choice.report(link(""), revision: 2)        // "[["
        #expect(choice.wants(.down, count: 5) && choice.wants(.up, count: 5))
        #expect(choice.row == nil, "a row was chosen before any arrow chose it")

        #expect(choice.take(.down, count: 5) == nil)
        #expect(choice.row == 0)
        _ = choice.take(.down, count: 5)
        #expect(choice.row == 1)
        _ = choice.take(.up, count: 5)
        #expect(choice.row == 0)
        _ = choice.take(.up, count: 5)
        #expect(choice.row == 0, "↑ walked off the top of the list")
    }

    /// ↑ first chooses the last row; ↓ stops at it.
    @Test func theArrowsStopAtTheEnds() {
        let choice = CompletionChoice()
        choice.report(nil, revision: 1)
        choice.report(link(""), revision: 2)
        _ = choice.take(.up, count: 3)
        #expect(choice.row == 2)
        _ = choice.take(.down, count: 3)
        #expect(choice.row == 2)
    }

    /// **Return is Return until a row is chosen** — `#todo`, Return is a line
    /// that ends in a tag, not a request for the first suggestion.
    @Test func returnIsTheTextsUntilARowIsChosen() {
        let choice = CompletionChoice()
        choice.report(nil, revision: 1)
        choice.report(tag("todo"), revision: 2)
        #expect(!choice.wants(.accept, count: 4), "Return was taken from a line ending in a tag")
        #expect(choice.take(.accept, count: 4) == nil)

        _ = choice.take(.down, count: 4)
        #expect(choice.wants(.accept, count: 4))
        #expect(choice.take(.accept, count: 4) == 0)
    }

    /// **A caret passing through a link keeps its arrows.** The list shows —
    /// it always has — and ↓ goes on down the paragraph.
    @Test func aCaretOnlyPassingThroughKeepsItsArrows() {
        let choice = CompletionChoice()
        choice.report(nil, revision: 7)
        choice.report(link("Notes"), revision: 7)   // arrowed into `[[Notes]]`: nothing typed
        #expect(!choice.wants(.down, count: 3) && !choice.wants(.up, count: 3),
                "the arrows were taken from a caret moving through the text")
        #expect(!choice.wants(.accept, count: 3))
        // Escape may still send the list away: it has no other use there.
        #expect(choice.wants(.dismiss, count: 3))

        // Typing in it makes it the list being typed into.
        choice.report(link("Notesx"), revision: 8)
        #expect(choice.wants(.down, count: 3))
    }

    /// An editor reports twice for one keystroke — the edit, then the caret —
    /// and the second, at the same revision, must not read as "only moved".
    @Test func aSecondReportOfTheSameKeystrokeChangesNothing() {
        let choice = CompletionChoice()
        choice.report(nil, revision: 1)
        choice.report(link("N"), revision: 2)
        choice.report(link("N"), revision: 2)
        #expect(choice.wants(.down, count: 2))
        // And the caret moving inside it, with nothing typed, keeps the list.
        choice.report(link("N"), revision: 2)
        _ = choice.take(.down, count: 2)
        choice.report(link("N"), revision: 2)
        #expect(choice.row == 0)
    }

    /// Other words are other rows: the choice does not carry over.
    @Test func typingMoreForgetsTheRow() {
        let choice = CompletionChoice()
        choice.report(nil, revision: 1)
        choice.report(link("N"), revision: 2)
        _ = choice.take(.down, count: 4)
        _ = choice.take(.down, count: 4)
        #expect(choice.row == 1)
        choice.report(link("No"), revision: 3)
        #expect(choice.row == nil)
        #expect(!choice.wants(.accept, count: 2))
    }

    /// Escape sends the list away — until the next thing typed.
    @Test func escapeSendsTheListAwayUntilSomethingIsTyped() {
        let choice = CompletionChoice()
        choice.report(nil, revision: 1)
        choice.report(link("N"), revision: 2)
        _ = choice.take(.down, count: 4)
        #expect(choice.take(.dismiss, count: 4) == nil)
        #expect(choice.isDismissed && choice.row == nil)
        for key in CompletionKey.allCases {
            #expect(!choice.wants(key, count: 4), "\(key) was taken by a list that had been sent away")
        }
        choice.report(link("No"), revision: 3)
        #expect(!choice.isDismissed && choice.wants(.down, count: 2))
    }

    /// Leaving the construct gives everything back, and a list with no rows
    /// takes nothing.
    @Test func leavingGivesTheKeysBack() {
        let choice = CompletionChoice()
        choice.report(nil, revision: 1)
        choice.report(link("N"), revision: 2)
        _ = choice.take(.down, count: 4)
        choice.report(nil, revision: 3)
        #expect(choice.row == nil && !choice.isLive)
        for key in CompletionKey.allCases { #expect(!choice.wants(key, count: 4)) }

        choice.report(link("zzz"), revision: 4)
        for key in CompletionKey.allCases { #expect(!choice.wants(key, count: 0)) }
    }

    /// Two constructs on a line are two lists.
    @Test func anotherConstructIsAnotherList() {
        let choice = CompletionChoice()
        choice.report(nil, revision: 1)
        choice.report(link("N", at: 10), revision: 2)
        _ = choice.take(.down, count: 4)
        // The caret jumps into a tag further along, nothing typed.
        choice.report(tag("idea", at: 40), revision: 2)
        #expect(choice.row == nil && !choice.wants(.down, count: 4))
    }
}

/// The list is ranked once for the words typed, however often it is asked for.
///
/// It was ranked again each time the editor's host drew and each time the
/// editor asked whether a key was the list's — five times for one read of an
/// iOS text view's key commands, each a fold and a sort of every title in the
/// collection, to learn a count (implemented.md §51.44).
@MainActor
struct CompletionMemoTests {

    private func link(_ query: String) -> EditorDocument.InlineContext {
        .init(kind: .wikiLink, range: NSRange(location: 4, length: query.count + 2), query: query)
    }

    @Test func theListIsRankedOnceForTheWordsTyped() {
        let memo = CompletionMemo()
        let rows = [WikiCompletion(label: "Notes", insert: "Notes", isHeading: false)]
        for _ in 0..<20 {
            #expect(memo.matches(for: link("No")) { rows } == rows)
        }
        #expect(memo.rankings == 1, "ranked \(memo.rankings) times for one query")

        // Other words are another list; the same words in a tag are too.
        _ = memo.matches(for: link("Not")) { [] }
        #expect(memo.rankings == 2)
        _ = memo.matches(for: .init(kind: .tag, range: NSRange(location: 4, length: 4), query: "Not")) { [] }
        #expect(memo.rankings == 3)
    }

    /// Leaving the construct forgets the list, so the next one typed takes up
    /// whatever notes and tags there are by then.
    @Test func leavingForgetsTheList() {
        let memo = CompletionMemo()
        _ = memo.matches(for: link("No")) { [] }
        memo.forget()
        let later = [WikiCompletion(label: "Notes", insert: "Notes", isHeading: false)]
        #expect(memo.matches(for: link("No")) { later } == later, "a list kept from before the caret left was shown")
        #expect(memo.rankings == 2)
    }
}
