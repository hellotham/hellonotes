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

    /// A rendered embed is laid out at the width the *page* would lay it out
    /// at: the pane less the distance from its edge to the first glyph, twice
    /// — which is `EditorMetrics.textLeadingInset` and is exactly the padding
    /// `GFMRenderer.page` is given for Preview.
    ///
    /// `syncRenderMetrics` took the container's width, which
    /// `widthTracksTextView` has *already* inset, and subtracted the inset
    /// again: every table, diagram, formula and HTML block in Edit came out
    /// 32pt narrower than the same block in Preview. No height measurement
    /// could see it — a narrower box is the same height until something in it
    /// wraps, and nothing in 672 one-construct examples did. Two PNG dumps of
    /// the same `<table>`, laid side by side, were 1452px and 1516px wide.
    ///
    /// **1200 is in the list on purpose.** The same line then capped the result
    /// at `min(width, 900)` — a number with no comment, no counterpart in the
    /// stylesheet (`img` is `max-width: 100%`) and no gate that reached it: the
    /// document sweep ran at 800 and 560, and the corpus's own fixtures are
    /// 20x20 squares. A 1600x900 screenshot measured −33pt against Preview at a
    /// 1000pt pane and −145 at 1200, which is an ordinary maximised window.
    @Test func aRenderedEmbedIsAsWideAsThePagesContentBox() {
        let document = EditorDocument(text: "<table><tr><td>Hi</td></tr></table>\n")
        let (scrollView, _) = MarkdownTextView.scrollableEditor(document: document)
        for width in [420.0, 800.0, 1200.0] as [CGFloat] {
            scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 400)
            let window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(scrollView)
            window.layoutIfNeeded()
            defer { window.contentView = nil }
            #expect(abs(document.renderMaxWidth - (width - 2 * EditorMetrics.textLeadingInset)) < 0.01,
                    "embed width \(document.renderMaxWidth) at pane width \(width)")
        }
    }
}
#endif
