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
    public init(markdown: String, baseURL: URL? = nil) {
        self.init(html: GFMRenderer.page(markdown), baseURL: baseURL)
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
}
#else
struct GFMWebView: UIViewRepresentable {
    let html: String
    let baseURL: URL?
    func makeUIView(context: Context) -> WKWebView { Self.makeWebView() }
    func updateUIView(_ web: WKWebView, context: Context) { Self.load(web, html, baseURL) }
}
#endif

extension GFMWebView {
    static func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
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
