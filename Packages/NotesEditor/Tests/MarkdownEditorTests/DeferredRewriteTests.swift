//
//  DeferredRewriteTests.swift
//  MarkdownEditorTests
//
//  A rewrite that lands a moment after the text it rewrites went in — a
//  picture's alt text from Vision, a pasted link's title from the web — is
//  made by `EditorDocument.replaceFirst`, straight into the storage, and the
//  caret has to stay where it was in the *text*. On iOS it stayed at its
//  offset: a photo put in with Insert Image had its alt text filled in before
//  the caret, and the next keystroke went into the middle of the alt text
//  (2026-11-22). `EditorProxy.replaceFirst` keeps it.
//

import Foundation
import Testing
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
@testable import MarkdownEditor

@MainActor
@Suite struct DeferredRewriteTests {

    // MARK: - The rule

    @Test func aSelectionKeepsItsPlaceInTheText() {
        // Five characters at 10 become twelve: seven more.
        let replaced = NSRange(location: 10, length: 5)
        func kept(_ location: Int, _ length: Int = 0) -> NSRange {
            EditorDocument.selection(NSRange(location: location, length: length), across: replaced, becoming: 12)
        }
        #expect(kept(3) == NSRange(location: 3, length: 0))        // before it
        #expect(kept(10) == NSRange(location: 10, length: 0))      // at its start: still before it
        #expect(kept(15) == NSRange(location: 22, length: 0))      // at its end: after the new text
        #expect(kept(30) == NSRange(location: 37, length: 0))      // after it
        #expect(kept(12) == NSRange(location: 22, length: 0))      // inside it: after the new text
        #expect(kept(2, 4) == NSRange(location: 2, length: 4))     // a selection ending before it
        #expect(kept(2, 20) == NSRange(location: 2, length: 27))   // one holding all of it
        #expect(kept(12, 10) == NSRange(location: 22, length: 0))  // one beginning inside it
        #expect(kept(NSNotFound).location == NSNotFound)           // no caret at all
    }

    @Test func aRewriteSaysWhatItReplaced() {
        let document = EditorDocument(text: "One ![](a.png) two ![](a.png) three")
        // Near the second one, which is where the search starts.
        let replaced = document.replaceFirst("![](a.png)", with: "![alt](a.png)", near: 29)
        #expect(replaced == NSRange(location: 19, length: 10))
        #expect(document.text == "One ![](a.png) two ![alt](a.png) three")
        #expect(document.replaceFirst("nowhere", with: "x") == nil)
    }

    // MARK: - On a text view

    private static let before = "Nothing here is special.\n\n"
    private static let link = "![](assets/Photo-1.jpg)"
    private static let described = "![plant, foliage](assets/Photo-1.jpg)"

    /// A picture's link just put in, the caret after it, and its alt text
    /// arriving: the caret is after the link still, so typing goes on there.
    @Test func theCaretStaysAfterAPictureWhoseDescriptionArrives() {
        let shown = Shown(Self.before + Self.link + "\n\n## The tour\n")
        let after = (Self.before + Self.link as NSString).length
        shown.place(NSRange(location: after, length: 0))

        #expect(shown.proxy.replaceFirst(Self.link, with: Self.described, in: shown.document))
        #expect(shown.document.text == Self.before + Self.described + "\n\n## The tour\n")
        #expect(shown.caret == NSRange(location: (Self.before + Self.described as NSString).length, length: 0))
    }

    /// Typing before the picture went on while Vision looked at it: a caret
    /// before the rewrite is left where it is.
    @Test func aCaretBeforeTheRewriteIsLeftAlone() {
        let shown = Shown(Self.before + Self.link + "\n")
        shown.place(NSRange(location: 7, length: 0))

        #expect(shown.proxy.replaceFirst(Self.link, with: Self.described, in: shown.document))
        #expect(shown.caret == NSRange(location: 7, length: 0))
    }

    /// The person went to another note before the description came: it goes
    /// into the note it was for, and the note on screen keeps its caret.
    @Test func aDocumentNoLongerShownIsRewrittenAndTheShownOneLeftAlone() {
        let shown = Shown("Another note entirely.")
        shown.place(NSRange(location: 8, length: 0))
        let earlier = EditorDocument(text: Self.before + Self.link)

        #expect(shown.proxy.replaceFirst(Self.link, with: Self.described, in: earlier))
        #expect(earlier.text == Self.before + Self.described)
        #expect(shown.document.text == "Another note entirely.")
        #expect(shown.caret == NSRange(location: 8, length: 0))
    }

    /// A text view showing `document`, with a proxy on it — the host's
    /// arrangement, on whichever platform the suite is built for.
    @MainActor private struct Shown {
        let document: EditorDocument
        let proxy = EditorProxy()
        #if canImport(AppKit)
        let view: MarkdownTextView
        #else
        let view: MarkdownUITextView
        let window: UIWindow
        #endif

        init(_ text: String) {
            document = EditorDocument(text: text)
            document.styleEverythingNow()
            #if canImport(AppKit)
            view = MarkdownTextView(usingTextLayoutManager: true)
            view.bind(to: document)
            #else
            view = MarkdownUITextView.make(document: document)
            view.frame = CGRect(x: 0, y: 0, width: 700, height: 900)
            window = UIWindow(frame: view.frame)
            window.addSubview(view)
            window.makeKeyAndVisible()
            view.layoutIfNeeded()
            #endif
            proxy.textView = view
        }

        func place(_ range: NSRange) { proxy.setSelection(range) }

        var caret: NSRange { proxy.selection() }
    }
}
