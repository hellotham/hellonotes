//
//  UnplacedCaretTests.swift
//  MarkdownEditorTests
//
//  A document has a caret once something puts one in it — the person, or a
//  command that places one — and not before. Until then `selectedRange` reads
//  `{0, 0}`, and a host that took that for a caret and put it back around a
//  replacement of the text reported a caret *arriving* at offset 0: in the
//  front matter, which unfolded on a note that had only been opened
//  (docs/implemented.md §51.20). These ask the document, and then each
//  platform's text view, whether anything puts a caret in a note nobody has
//  clicked into — and, as the control, whether a click still does.
//

import Foundation
import Testing
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
@testable import MarkdownEditor

@MainActor
@Suite struct UnplacedCaretTests {

    /// DefaultCollection's Linking.md, as far as its first paragraph.
    static let note = "---\ntitle: Linking\ntags: [tour]\naliases: [Links, Wiki Links]\n---\n\n"
        + "# Linking\n\nType [[ and HelloNotes offers every note in the collection.\n"

    private func offset(of needle: String) -> Int { (Self.note as NSString).range(of: needle).location }

    /// Built, and with its text replaced wholesale, a document has no caret; a
    /// selection reported to it is one — at 0 as much as anywhere, and a caret
    /// at 0 opens the front matter. That last is the control: without it,
    /// "folded" could be what `isFrontMatterFolded` always says.
    @Test func aDocumentHasNoCaretUntilOneIsPut() {
        let document = EditorDocument(text: "")
        #expect(document.caret == nil, "a document nobody has put a caret in has one")

        // The note arriving in the document built while it was still loading.
        document.replaceText(Self.note)
        #expect(document.caret == nil, "loading the note put a caret in it")
        #expect(document.isFrontMatterFolded)

        let body = NSRange(location: offset(of: "HelloNotes offers"), length: 0)
        document.selectionDidChange(body)
        #expect(document.caret == body)
        #expect(document.isFrontMatterFolded)

        document.replaceText(Self.note + "\nA line more.\n")
        #expect(document.caret == nil, "a caret outlived the text it was in")

        let atZero = NSRange(location: 0, length: 0)
        document.selectionDidChange(atZero)
        #expect(document.caret == atZero, "a caret put at 0 is not taken for one")
        #expect(!document.isFrontMatterFolded,
                "a caret in the front matter did not open it, so every fold above proves nothing")
    }

    #if canImport(AppKit)
    /// The Mac's text view reports every `setSelectedRanges` to its document —
    /// AppKit's own fix-ups after a change of text included. A note loading
    /// under it, and the view taking the next tab's note (the Mac re-binds one
    /// view rather than making another), must report no caret nobody placed.
    @Test func theMacTextViewReportsNoCaretNobodyPlaced() {
        let document = EditorDocument(text: "")
        let view = MarkdownTextView(usingTextLayoutManager: true)
        view.bind(to: document)
        document.replaceText(Self.note)
        #expect(document.caret == nil,
                "the text view reported a caret as the note loaded under it: \(String(describing: document.caret))")
        #expect(document.isFrontMatterFolded, "the note loaded under the text view with its front matter unfolded")

        // The control: a click in the body is reported.
        view.setSelectedRange(NSRange(location: offset(of: "HelloNotes offers"), length: 0))
        #expect(document.caret?.location == offset(of: "HelloNotes offers"),
                "a click was not reported, so every nil in this test proves nothing")

        let next = EditorDocument(text: Self.note)
        view.bind(to: next)
        #expect(next.caret == nil, "the next note was handed the last one's caret: \(String(describing: next.caret))")
        #expect(next.isFrontMatterFolded, "the next note opened with its front matter unfolded")
    }
    #else
    /// The iPad's text view, wired to its coordinator as the representable
    /// wires it. A note loading under it reports no caret; a tap does.
    @Test func theIPadTextViewReportsNoCaretNobodyPlaced() {
        let document = EditorDocument(text: "")
        let tv = MarkdownUITextView.make(document: document)
        let coordinator = MarkdownEditorRepresentable.Coordinator(document: document)
        tv.delegate = coordinator
        tv.frame = CGRect(x: 0, y: 0, width: 700, height: 900)
        let window = UIWindow(frame: tv.frame)
        window.addSubview(tv)
        window.makeKeyAndVisible()
        tv.layoutIfNeeded()

        document.replaceText(Self.note)
        tv.layoutIfNeeded()
        #expect(document.caret == nil,
                "the text view reported a caret as the note loaded under it: \(String(describing: document.caret))")
        #expect(document.isFrontMatterFolded, "the note loaded under the text view with its front matter unfolded")

        // The control: a tap in the body is reported.
        tv.selectedRange = NSRange(location: offset(of: "HelloNotes offers"), length: 0)
        #expect(document.caret?.location == offset(of: "HelloNotes offers"),
                "a tap was not reported, so every nil in this test proves nothing")
        withExtendedLifetime((coordinator, window)) {}
    }
    #endif
}
