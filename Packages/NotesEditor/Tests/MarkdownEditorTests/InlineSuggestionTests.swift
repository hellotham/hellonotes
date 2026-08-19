//
//  InlineSuggestionTests.swift
//  MarkdownEditorTests
//
//  The ghost-text invariant, pinned.
//
//  Everything downstream of the editor — autosave, the incremental reparse, the
//  search index, the link graph, Git — reads the document's text. So "the
//  suggestion never reaches a save, an index or a diff" is not four claims to
//  check separately: it is one claim about `document.text`, and these tests
//  make it once. If a suggestion is ever visible there, every one of those
//  systems has already been lied to.
//

// AppKit-only: this suite drives `MarkdownTextView`, the NSTextView half
// of the editor. The package builds for iOS too, and the tests have to
// compile there.
#if canImport(AppKit)
import Foundation
import Testing
#if canImport(AppKit)
import AppKit
#endif
@testable import MarkdownEditor

#if canImport(AppKit)
@MainActor
@Suite struct InlineSuggestionTests {

    private func editor(_ text: String, caretAtEnd: Bool = true)
        -> (MarkdownTextView, EditorDocument) {
        let document = EditorDocument(text: text)
        let view = MarkdownTextView(usingTextLayoutManager: true)
        view.bind(to: document)
        if caretAtEnd {
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        return (view, document)
    }

    private func offer(_ view: MarkdownTextView, _ text: String) {
        view.showInlineSuggestion(
            InlineSuggestion(location: view.selectedRange().location, text: text))
    }

    // MARK: - The invariant

    /// The one that matters. A shown suggestion is pixels, not text.
    @Test func aShownSuggestionIsNotInTheDocument() {
        let source = "The slip box is "
        let (view, document) = editor(source)
        offer(view, "a filing system for ideas.")

        #expect(view.inlineSuggestion != nil)          // it really is showing
        #expect(document.text == source)
        #expect(!document.text.contains("filing system"))
        #expect(document.storage.length == (source as NSString).length)
        #expect(view.string == source)
    }

    /// The same claim after the editor has had a chance to react — styling,
    /// selection reporting, layout. A suggestion that leaks one runloop later
    /// leaks just as thoroughly.
    @Test func aSuggestionStillIsNotInTheDocumentAfterAStylePass() {
        let source = "Zettelkasten "
        let (view, document) = editor(source)
        offer(view, "means slip box.")
        document.styleEverythingNow()
        view.layoutSubtreeIfNeeded()

        #expect(view.inlineSuggestion != nil)
        #expect(document.text == source)
    }

    // MARK: - Accepting

    @Test func acceptingInsertsItExactlyOnce() {
        let source = "The slip box is "
        let (view, document) = editor(source)
        offer(view, "a filing system.")

        #expect(view.acceptInlineSuggestion())
        #expect(document.text == "The slip box is a filing system.")
        #expect(view.inlineSuggestion == nil)
        #expect(view.selectedRange().location == (document.text as NSString).length)
    }

    /// Accepting twice must not insert twice — the suggestion is consumed.
    @Test func acceptingASecondTimeDoesNothing() {
        let (view, document) = editor("a ")
        offer(view, "b")
        #expect(view.acceptInlineSuggestion())
        #expect(!view.acceptInlineSuggestion())
        #expect(document.text == "a b")
    }

    /// Completion is asynchronous and people keep typing. A reply computed for
    /// a caret that has since moved describes a sentence that no longer exists,
    /// so it must be refused rather than inserted somewhere plausible.
    @Test func aSuggestionForAMovedCaretIsRefused() {
        let (view, document) = editor("one two")
        view.showInlineSuggestion(InlineSuggestion(location: 7, text: " three"))
        view.setSelectedRange(NSRange(location: 3, length: 0))

        #expect(!view.acceptInlineSuggestion())
        #expect(document.text == "one two")
    }

    // MARK: - Where it may appear

    /// Ghost text is drawn into empty space at the end of a line. Offered
    /// mid-line it would have to reflow text it does not own.
    @Test func aSuggestionIsNotOfferedMidLine() {
        let (view, _) = editor("one two", caretAtEnd: false)
        view.setSelectedRange(NSRange(location: 3, length: 0))
        offer(view, " and a half")
        #expect(view.inlineSuggestion == nil)
    }

    @Test func aSuggestionIsOfferedAtTheEndOfANonFinalLine() {
        let (view, _) = editor("first\nsecond", caretAtEnd: false)
        view.setSelectedRange(NSRange(location: 5, length: 0))   // end of "first"
        offer(view, " line")
        #expect(view.inlineSuggestion != nil)
    }

    @Test func aSuggestionIsNotOfferedOverASelection() {
        let (view, _) = editor("one two", caretAtEnd: false)
        view.setSelectedRange(NSRange(location: 0, length: 3))
        offer(view, "!")
        #expect(view.inlineSuggestion == nil)
    }

    // MARK: - Dismissal

    @Test func movingTheCaretClearsIt() {
        let (view, _) = editor("first\nsecond")
        offer(view, " more")
        #expect(view.inlineSuggestion != nil)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(view.inlineSuggestion == nil)
    }

    @Test func typingClearsIt() {
        let (view, document) = editor("abc")
        offer(view, "def")
        view.performEdit(replacing: NSRange(location: 3, length: 0), with: "d")
        #expect(view.inlineSuggestion == nil)
        #expect(document.text == "abcd")
    }

    @Test func escapeClearsItAndLeavesTheDocumentAlone() {
        let (view, document) = editor("abc")
        offer(view, "def")
        view.cancelOperation(nil)
        #expect(view.inlineSuggestion == nil)
        #expect(document.text == "abc")
    }

    // MARK: - Sanitising a model reply

    @Test func onlyTheFirstLineIsEverUsed() {
        #expect(InlineSuggestion.sanitise("one\ntwo\nthree") == "one")
    }

    @Test func aWrappingQuoteIsStripped() {
        #expect(InlineSuggestion.sanitise("\"a slip box\"") == "a slip box")
    }

    /// A completion legitimately begins with a space — that is how it joins the
    /// word before it. Trimming both ends glues the ghost to the last word.
    @Test func aLeadingSpaceSurvivesButATrailingOneDoesNot() {
        #expect(InlineSuggestion.sanitise(" a slip box  ") == " a slip box")
    }

    @Test func aCodeFenceIsRefusedOutright() {
        #expect(InlineSuggestion.sanitise("```swift\nlet x = 1\n```") == nil)
        #expect(InlineSuggestion.sanitise("   \n  ") == nil)
    }
}
#endif
#endif
