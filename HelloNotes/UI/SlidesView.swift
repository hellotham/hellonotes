//
//  SlidesView.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  A paged deck preview for Marp Markdown slides. Each slide renders in a 16:9
//  WebView; the note is edited as normal Markdown in the editor. Navigate with
//  the arrows / on-screen controls, or jump from the slide menu.
//

// **Cross-platform.** This file was `#if os(macOS)` for the sake of one
// representable; the Marp rendering, navigation and export never were.
import SwiftUI
import MarkdownEditor
import WebKit

struct SlidesView: View {
    let markdown: String
    let title: String
    /// The note's directory, so relative image paths in slides resolve.
    let baseURL: URL?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var index = 0

    private var slides: [String] { MarpSlides.slides(markdown) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            deck
            Divider()
            controls
        }
        .frame(width: 900, height: 640)
        .onChange(of: slides.count) { _, count in
            if index >= count { index = max(0, count - 1) }
        }
    }

    private var header: some View {
        HStack {
            Label("Slides — \(title)", systemImage: "rectangle.on.rectangle").font(.headline)
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    @ViewBuilder
    private var deck: some View {
        if slides.isEmpty {
            ContentUnavailableView("No slides", systemImage: "rectangle.on.rectangle",
                                   description: Text("Separate slides with a line containing only `---`."))
        } else {
            let current = min(index, slides.count - 1)
            SlideWebView(html: MarpSlides.slideHTML(slides[current], dark: colorScheme == .dark), baseURL: baseURL)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(Color.black.opacity(0.04))
                .padding(16)
                .background(.background)
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(index <= 0)
                .accessibilityLabel("Previous slide")
            Menu("\(min(index, max(0, slides.count - 1)) + 1) / \(max(slides.count, 1))") {
                ForEach(Array(slides.enumerated()), id: \.offset) { i, slide in
                    Button("\(i + 1). \(slideTitle(slide))") { index = i }
                }
            }
            .fixedSize()
            .accessibilityLabel("Slide \(min(index, max(0, slides.count - 1)) + 1) of \(max(slides.count, 1))")
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(index >= slides.count - 1)
                .accessibilityLabel("Next slide")
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.bar)
    }

    private func step(_ delta: Int) {
        index = min(max(0, index + delta), max(0, slides.count - 1))
    }

    /// A short label for a slide (its first heading or first line).
    private func slideTitle(_ slide: String) -> String {
        for raw in slide.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let stripped = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            return String(stripped.prefix(40))
        }
        return "Slide"
    }
}

/// The deck, in a web view.
///
/// The only platform-specific thing in this file: `NSViewRepresentable` on the
/// Mac, `UIViewRepresentable` on iPad. Everything else — the Marp rendering,
/// the navigation, the export — was already portable, which is why the whole
/// file sat behind `#if os(macOS)` for the sake of these fifteen lines.
#if os(macOS)
private struct SlideWebView: NSViewRepresentable {
    let html: String
    let baseURL: URL?

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")   // transparent, so our CSS bg shows
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        view.loadHTMLString(html, baseURL: baseURL)
    }
    // Viewport sizing (S1): take what we're offered, never the deck's size.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView,
                      context: Context) -> CGSize? { viewportSizeThatFits(proposal) }
}
#else
private struct SlideWebView: UIViewRepresentable {
    let html: String
    let baseURL: URL?

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.isOpaque = false                 // the iOS spelling of drawsBackground
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        view.loadHTMLString(html, baseURL: baseURL)
    }
    // Viewport sizing (S1): take what we're offered, never the deck's size.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: WKWebView,
                      context: Context) -> CGSize? { viewportSizeThatFits(proposal) }
}
#endif

