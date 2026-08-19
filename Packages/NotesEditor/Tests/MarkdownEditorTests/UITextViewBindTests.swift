//
//  UITextViewBindTests.swift
//  MarkdownEditorTests
//
//  `bind(to:)` hands the text view its document by *replacing* the text storage
//  on the content manager. AppKit supports that; these tests ask whether UIKit
//  does — i.e. whether a `UITextView` that had its storage swapped still agrees
//  with that storage about how long the document is.
//
//  It matters because every disagreement is an out-of-bounds waiting to happen:
//  UIKit reads text ranges from its own cached notion of the document, and the
//  first thing that walks the storage over one of those ranges throws
//  NSRangeException from a stack with no app frames in it.
//

#if canImport(UIKit) && !canImport(AppKit)
import UIKit
import Testing
@testable import MarkdownEditor

@MainActor
@Suite struct UITextViewBindTests {

    /// A note big enough that a stale "empty document" is unmistakable.
    private func sampleText() -> String {
        (0..<200).map { i in
            "## Section \(i)\n\nParagraph \(i) with **bold**, `code` and a [[Link \(i)]].\n\n> quoted \(i)\n\n- bullet \(i)\n"
        }.joined()
    }

    private func hosted(_ document: EditorDocument) -> (MarkdownUITextView, UIWindow) {
        let tv = MarkdownUITextView.make(document: document)
        tv.frame = CGRect(x: 0, y: 0, width: 700, height: 900)
        let window = UIWindow(frame: tv.frame)
        window.addSubview(tv)
        window.makeKeyAndVisible()
        tv.layoutIfNeeded()
        return (tv, window)
    }

    @Test func theTextViewAgreesWithItsDocumentAboutTheDocument() {
        let text = sampleText()
        let document = EditorDocument(text: text)
        document.styleEverythingNow()
        let (tv, _) = hosted(document)
        let length = document.storage.length

        #expect(length == (text as NSString).length)
        #expect(tv.textStorage.length == length)
        #expect((tv.text as NSString?)?.length == length)
        #expect(tv.offset(from: tv.beginningOfDocument, to: tv.endOfDocument) == length)
    }

    /// The reported crash: scroll, then tap. A tap is a selection change plus a
    /// request for the caret's geometry, and scrolling asks UIKit to lay out a
    /// range it has not seen. Both go through UIKit's own view of the document.
    @Test func scrollingThenSelectingLateInTheDocumentDoesNotThrow() {
        let document = EditorDocument(text: sampleText())
        document.styleEverythingNow()
        let (tv, _) = hosted(document)
        let length = document.storage.length

        tv.setContentOffset(CGPoint(x: 0, y: max(0, tv.contentSize.height - 900)), animated: false)
        tv.layoutIfNeeded()
        tv.ensureVisibleRangeStyled()

        let caret = NSRange(location: max(0, length - 20), length: 0)
        tv.selectedRange = caret
        tv.scrollRangeToVisible(caret)
        tv.layoutIfNeeded()

        #expect(tv.selectedRange.location == caret.location)
        // What a tap actually asks for.
        if let position = tv.position(from: tv.beginningOfDocument, offset: caret.location) {
            _ = tv.caretRect(for: position)
        }
        _ = tv.selectionRects(for: tv.textRange(from: tv.beginningOfDocument, to: tv.endOfDocument)!)
    }

    /// Find was switched off on the theory that it walked stale ranges. It was
    /// walking an empty `textStorage`; the invariant above is what makes it
    /// safe, so this only checks the feature is actually on and that the text
    /// it would search is the note's.
    @Test func findIsEnabledAndSearchesTheNoteOnScreen() {
        let document = EditorDocument(text: sampleText())
        document.styleEverythingNow()
        let (tv, _) = hosted(document)

        #expect(tv.isFindInteractionEnabled)
        #expect(tv.findInteraction != nil)
        #expect(tv.text.contains("Section 137"))
    }

}
#endif
