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
            let html = MarkdownExport.html(from: markdown, title: title, fontScale: scale)
            // Load in-memory with the note's folder as the base so relative
            // image paths resolve where WebKit permits it.
            view.loadHTMLString(html, baseURL: baseURL)
        }
    }
}
#endif
