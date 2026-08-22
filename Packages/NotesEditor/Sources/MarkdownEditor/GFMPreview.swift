//
//  GFMPreview.swift
//  MarkdownEditor
//
//  A read-only preview that renders a note exactly as GitHub does: the
//  Markdown is run through cmark-gfm (GitHub's engine) to HTML and displayed
//  in a WKWebView styled with GitHub's own stylesheet. This is the
//  pixel-fidelity surface — the live TextKit editor stays for editing.
//

import SwiftUI
import WebKit
import GFMRender

/// SwiftUI preview view. Give it a pre-built HTML page (see `GFMRenderer.page`
/// / the app's resource-resolving wrapper) and the note folder for base
/// resolution.
public struct GFMPreview: View {
    private let html: String
    private let baseURL: URL?

    /// `html` is a complete page (e.g. `GFMRenderer.page(markdown)`), already
    /// with images inlined by the caller. `baseURL` is the note's folder.
    public init(html: String, baseURL: URL? = nil) {
        self.html = html
        self.baseURL = baseURL
    }

    /// Convenience: render raw Markdown to a GitHub page directly.
    /// - Parameter fontScale: the app's Text Size, folded into the page.
    ///
    /// It used to be absent, so this initialiser rendered at scale 1 and every
    /// caller that cared had to reach for `GFMRenderer.page` and the `html:`
    /// form instead. One of them did and one did not, which is how Text Size
    /// scaled the preview on iPad and did nothing on the Mac.
    /// The page is measured as a **pane**, not a document: the same top inset
    /// and the same distance from the leading edge to the first glyph that the
    /// live editor uses, and no measure of its own. Preview used the export
    /// page's box — a 980pt centred column — so switching out of Edit moved
    /// the text sideways before a single glyph had been re-measured.
    public init(markdown: String, baseURL: URL? = nil, fontScale: Double = 1) {
        self.init(html: GFMRenderer.page(
            markdown,
            fontScale: fontScale,
            box: .pane(inset: EditorMetrics.textContainerInset,
                       leading: EditorMetrics.textLeadingInset)),
                  baseURL: baseURL)
    }

    public var body: some View {
        GFMWebView(html: html, baseURL: baseURL)
            .ignoresSafeArea()
    }
}

#if canImport(AppKit)
struct GFMWebView: NSViewRepresentable {
    let html: String
    let baseURL: URL?
    func makeNSView(context: Context) -> WKWebView { Self.makeWebView() }
    func updateNSView(_ web: WKWebView, context: Context) { Self.load(web, html, baseURL) }
    // Viewport sizing — docs/layout-architecture.md S1.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView,
                      context: Context) -> CGSize? { viewportSizeThatFits(proposal) }
}
#else
struct GFMWebView: UIViewRepresentable {
    let html: String
    let baseURL: URL?
    func makeUIView(context: Context) -> WKWebView { Self.makeWebView() }
    func updateUIView(_ web: WKWebView, context: Context) { Self.load(web, html, baseURL) }
    // Viewport sizing — docs/layout-architecture.md S1.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: WKWebView,
                      context: Context) -> CGSize? { viewportSizeThatFits(proposal) }
}
#endif

extension GFMWebView {
    static func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        // JS is needed only for the bundled highlight.js; any `<script>` in the
        // note itself is already escaped by cmark-gfm's tagfilter.
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let web = WKWebView(frame: .zero, configuration: config)
        #if canImport(AppKit)
        web.setValue(false, forKey: "drawsBackground")
        #else
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        #endif
        return web
    }

    /// Load only when the content actually changed (avoid reload-on-every-
    /// SwiftUI-update flicker).
    static func load(_ web: WKWebView, _ html: String, _ baseURL: URL?) {
        let tag = ObjectIdentifier(web)
        if lastLoaded[tag] == html.hashValue { return }
        lastLoaded[tag] = html.hashValue
        web.loadHTMLString(html, baseURL: baseURL)
    }
}

@MainActor private var lastLoaded: [ObjectIdentifier: Int] = [:]
