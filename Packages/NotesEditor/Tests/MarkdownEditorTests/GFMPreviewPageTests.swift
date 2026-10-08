//
//  GFMPreviewPageTests.swift
//  MarkdownEditorTests
//
//  A preview page can be built off the main actor (`GFMPreview.page(_:style:)`,
//  from a `PageStyle` read on it) and handed to the preview with a number, so
//  a redraw that hands the same page over again is told by its number rather
//  than by reading it. The app's Preview follows typing that way; it rendered
//  the page in the view's initialiser, on the main actor, at every redraw.
//

import Foundation
import Testing
import WebKit
@testable import MarkdownEditor
import GFMRender

@MainActor
struct GFMPreviewPageTests {

    /// The page built from a style is the page the preview showed before it
    /// could be built anywhere else — the one `RenderParity` grades Edit
    /// against: the theme's size, a pane's box, the theme's palette.
    @Test func aPageBuiltFromItsStyleIsThePageThePreviewShows() {
        let markdown = "# Title\n\nSome *text*, a [link](https://example.com) and `code`.\n\n- one\n- two\n"
        for isDark in [false, true] {
            let theme = EditorTheme(fontSize: 17)
            let page = GFMPreview.page(markdown, style: GFMPreview.PageStyle(theme: theme, isDark: isDark))
            let shown = GFMRenderer.page(markdown, base: 17,
                                         box: .pane(inset: EditorMetrics.textContainerInset,
                                                    leading: EditorMetrics.textLeadingInset),
                                         palette: theme.pagePalette(isDark: isDark))
            #expect(page == shown, "the page built from its style is not the page the preview shows (isDark: \(isDark))")
        }
    }

    /// Two styles are the same style exactly when they would draw the same
    /// page — what lets a preview key its page on one.
    @Test func aStyleChangesWithWhatItDraws() {
        let light = GFMPreview.PageStyle(theme: EditorTheme(fontSize: 17), isDark: false)
        #expect(light == GFMPreview.PageStyle(theme: EditorTheme(fontSize: 17), isDark: false))
        #expect(light != GFMPreview.PageStyle(theme: EditorTheme(fontSize: 17), isDark: true))
        #expect(light != GFMPreview.PageStyle(theme: EditorTheme(fontSize: 19), isDark: false))
    }

    /// A page with a number is loaded once per number: handed over again —
    /// every redraw of whatever holds the preview hands it over — it is told
    /// by the number, and nothing reads the page. Without one, by what the
    /// page says, which is how it was told before.
    @Test func aPageIsLoadedOncePerNumber() {
        var loads: [String] = []
        EditorProbe.listener = { line in if line.hasPrefix("load ") { loads.append(line) } }
        defer { EditorProbe.listener = nil }
        let web = WKWebView()
        let state = GFMWebLoadState()

        GFMWebView.load(web, "<p>one</p>", 1, nil, state)
        GFMWebView.load(web, "<p>one</p>", 1, nil, state)
        #expect(loads.count == 1, "the same page, handed over again, was loaded again")
        // Told by the number, so what the page says is never read: the same
        // number is the same page, whatever it holds.
        GFMWebView.load(web, "<p>one, as the caller had it</p>", 1, nil, state)
        #expect(loads.count == 1, "a page was told by what it says, not by its number")
        GFMWebView.load(web, "<p>two</p>", 2, nil, state)
        #expect(loads.count == 2, "a new page was not loaded")

        GFMWebView.load(web, "<p>three</p>", nil, nil, state)
        GFMWebView.load(web, "<p>three</p>", nil, nil, state)
        #expect(loads.count == 3, "a page without a number was loaded again")
        GFMWebView.load(web, "<p>four</p>", nil, nil, state)
        #expect(loads.count == 4, "a page without a number was not told by what it says")
    }
}
