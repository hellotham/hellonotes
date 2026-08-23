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
    public init(markdown: String, baseURL: URL? = nil, fontScale: Double = 1,
                theme: EditorTheme? = nil, isDark: Bool = false) {
        let theme = theme ?? EditorTheme(fontSize: 16 * CGFloat(fontScale))
        self.init(html: GFMRenderer.page(
            markdown,
            fontScale: fontScale,
            box: .pane(inset: EditorMetrics.textContainerInset,
                       leading: EditorMetrics.textLeadingInset),
            palette: theme.pagePalette(isDark: isDark)),
                  baseURL: baseURL)
    }

    public var body: some View {
        // No `.ignoresSafeArea()`. On macOS the split view's detail column
        // spans the whole window and the sidebar is drawn over it; the overlap
        // is published as a safe-area inset, and every other pane view honours
        // it. Preview did not, so it alone started underneath the sidebar with
        // its first glyphs hidden — which reads exactly like the document
        // shifting sideways when you switch out of Edit.
        GFMWebView(html: html, baseURL: baseURL)
    }
}

/// What this web view has already been given, kept for exactly as long as the
/// web view itself.
///
/// It used to be a file-scope `[ObjectIdentifier: Int]`, which is a dictionary
/// keyed by the address of an object it does not retain and never removes an
/// entry from. Deallocate a web view, allocate the next one, and the allocator
/// will happily hand back the same address — at which point the *new*, empty
/// web view matches the *old* one's entry and the load is skipped. There is
/// nothing to draw and nothing to say so. A coordinator is created with the
/// view and released with it, so the memory cannot outlive what it describes.
@MainActor final class GFMWebLoadState {
    var loaded: Int?
}

#if canImport(AppKit)
struct GFMWebView: NSViewRepresentable {
    let html: String
    let baseURL: URL?
    func makeCoordinator() -> GFMWebLoadState { GFMWebLoadState() }
    func makeNSView(context: Context) -> WKWebView {
        Self.log("make")
        return Self.makeWebView()
    }
    func updateNSView(_ web: WKWebView, context: Context) {
        Self.load(web, html, baseURL, context.coordinator)
    }
    // Viewport sizing — docs/layout-architecture.md S1.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView,
                      context: Context) -> CGSize? {
        let size = viewportSizeThatFits(proposal)
        Self.log("size proposal=\(proposal) -> \(size)")
        return size
    }
}
#else
struct GFMWebView: UIViewRepresentable {
    let html: String
    let baseURL: URL?
    func makeCoordinator() -> GFMWebLoadState { GFMWebLoadState() }
    func makeUIView(context: Context) -> WKWebView {
        Self.log("make")
        return Self.makeWebView()
    }
    func updateUIView(_ web: WKWebView, context: Context) {
        Self.load(web, html, baseURL, context.coordinator)
    }
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
    static func load(_ web: WKWebView, _ html: String, _ baseURL: URL?,
                     _ state: GFMWebLoadState) {
        guard state.loaded != html.hashValue else {
            log("skip \(html.count) chars — already loaded")
            return
        }
        state.loaded = html.hashValue
        log("load \(html.count) chars, frame \(web.frame.size)")
        web.loadHTMLString(html, baseURL: baseURL)
        guard EditorProbe.isEnabled else { return }
        // How far the first glyph sits below the page's own top edge — the
        // number to compare against the editor's `textContainerInset` plus its
        // first line's leading. If these differ, the two renderers start their
        // documents at different heights inside identical panes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            web.evaluateJavaScript("""
            (function () {
              var b = document.querySelector('.markdown-body');
              var f = b && b.firstElementChild;
              if (!f) return -1;
              var r = document.createRange();
              r.selectNodeContents(f);
              return r.getBoundingClientRect().top;
            })()
            """) { value, _ in
                log("preview first glyph top=\(value as? Double ?? -1)")
            }
        }
    }

    /// A blank Preview has no symptom to read — the pane is simply the colour
    /// of whatever is behind it, whether the web view was never built, never
    /// given a size, or never handed any HTML. `EditorProbe` says which.
    static func log(_ message: @autoclosure () -> String) { EditorProbe.log(message()) }
}
