//
//  MarkdownWebView.swift
//  HelloNotes
//
//  Created by Chris Tham on 13/7/2026.
//
//  iOS read-only Markdown preview. the live editor is macOS-only (AppKit /
//  TextKit 2), so the mobile Preview renders the note to styled HTML with the
//  shared, cross-platform `MarkdownExport` and shows it in a WKWebView.
//

#if os(iOS)
import SwiftUI
import GFMRender
import MarkdownEditor
import WebKit

struct MarkdownWebView: UIViewRepresentable {
    /// The raw Markdown to render.
    let markdown: String
    /// Note title (used for the document `<title>`).
    let title: String
    /// The note's folder, so relative image paths can resolve.
    let baseURL: URL?
    /// Multiplies the document's base font with the app's Text Size setting.
    var fontScale: Double = 1

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        context.coordinator.load(markdown: markdown, title: title, baseURL: baseURL, scale: fontScale, into: view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.load(markdown: markdown, title: title, baseURL: baseURL, scale: fontScale, into: view)
    }

    // Viewport sizing (S1): take what we're offered, never the page's size.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: WKWebView,
                      context: Context) -> CGSize? { viewportSizeThatFits(proposal) }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        /// Remember what we last rendered so an unrelated SwiftUI update (e.g. a
        /// selection change elsewhere) doesn't reload and scroll the view back
        /// to the top.
        private var lastKey: String?

        func load(markdown: String, title: String, baseURL: URL?, scale: Double, into view: WKWebView) {
            let key = "\(scale)\n\(markdown)"
            guard key != lastKey else { return }
            lastKey = key
            // `GFMRenderer.page`, not `MarkdownExport.html`.
            //
            // GitHub fidelity is the requirement (implemented.md §4: "both the
            // Preview *and* the live editor provably GitHub-faithful, using
            // GitHub's own engine"), and the package ships exactly that —
            // cmark-gfm through github-markdown-css, with 648/648 spec tests
            // and byte-parity against api.github.com/markdown behind it. The
            // Preview was calling the *export* renderer instead: a small
            // hand-written stylesheet over a different formatter. So the live
            // editor styled from cmark's AST while the Preview beside it did
            // not, on both platforms, which is why Edit and Preview disagreed
            // about tables, headings and type.
            let html = GFMRenderer.page(markdown, fontScale: scale)
            // Load in-memory with the note's folder as the base so relative
            // image paths resolve where WebKit permits it.
            view.loadHTMLString(html, baseURL: baseURL)
        }
    }
}
#endif
