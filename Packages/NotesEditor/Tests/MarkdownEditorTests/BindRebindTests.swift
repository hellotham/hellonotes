//
//  BindClobberProbe.swift
//  MarkdownEditorTests
//
//  `NSTextView.font` applies to the storage attached at that moment, so
//  `bind(to:)` has two ordering hazards, not one. The known one (set the font
//  before attaching the new storage) was handled; the other — don't set it
//  while the *previous* document is still attached — was not, and documents
//  outlive their views, so the damage stuck.
//

import Foundation
import Testing
#if canImport(AppKit)
import AppKit
#endif
@testable import MarkdownEditor

@MainActor
@Suite struct BindRebindTests {

    @Test func bindingASecondDocumentDoesNotClobberTheFirst() {
        let textA = "---\ntitle: A\n---\n\n# Big Heading\n\nBody text here.\n"
        let a = EditorDocument(text: textA)
        a.selectionDidChange(NSRange(location: (textA as NSString).length - 1, length: 0))
        a.styleEverythingNow()
        let b = EditorDocument(text: "plain\n")

        let ns = textA as NSString
        func aFont(_ needle: String) -> CGFloat {
            let loc = ns.range(of: needle).location
            return (a.storage.attribute(.font, at: loc, effectiveRange: nil) as? PlatformFont)?.pointSize ?? 0
        }
        print("A before bind:  h1=\(aFont("Big Heading"))  frontMatter=\(aFont("title: A"))")

        let view = MarkdownTextView(usingTextLayoutManager: true)
        view.bind(to: a)
        print("A after bind(A): h1=\(aFont("Big Heading"))  frontMatter=\(aFont("title: A"))")

        view.bind(to: b)
        let h1 = aFont("Big Heading")
        let fm = aFont("title: A")
        print("A after bind(B): h1=\(h1)  frontMatter=\(fm)")

        // Symptoms when this regresses, both visible on the very next visit to
        // the note you left: headings render at body size, and folded front
        // matter renders at full height while staying transparent — an empty
        // band above the first line.
        #expect(h1 > 20, "binding another document flattened the first document's heading font")
        #expect(fm < 1, "binding another document un-concealed the first document's front matter")
    }
}
