//
//  HTMLBlockImageRenderer.swift
//  MarkdownEditor
//
//  Renders one raw HTML block to an image, so the live editor can show what
//  Preview shows instead of the literal tags.
//
//  Why WebKit and not a hand-rolled subset: the goal is that Edit and Preview
//  are the same picture, and HTML is exactly the construct where a subset would
//  diverge first — a `<table>`, a `<details>`, a `<sup>`, an inline `style`.
//  The block goes through `GFMRenderer.page`, the *same* function Preview
//  calls, with the same stylesheet and the same `GFMBoxMetrics` numbers. Parity
//  is then structural rather than something to keep re-checking: cmark passes
//  an HTML block through verbatim, so rendering the block alone renders exactly
//  the fragment Preview would have drawn in place.
//
//  The block is collapsed to this image only while the caret is elsewhere,
//  exactly as a table or a Mermaid fence is. Put the caret inside and the
//  source comes back, because the source is what you edit.
//

import Foundation
import WebKit
import GFMRender
import MarkdownCore

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Renders raw HTML blocks to images, off the note's own layout.
@MainActor
public enum HTMLBlockImageRenderer {

    /// Render `source` (raw HTML) at `maxWidth` points.
    ///
    /// Returns nil rather than a blank image when the page fails to load or
    /// measures to nothing — the caller leaves the source visible, which is the
    /// right fallback for markup that does not render.
    /// `keepsTrailingMargin` decides whether the element's own `margin-bottom`
    /// is measured with it. It is not a style choice: the stylesheet zeroes
    /// that margin on the article's last child, so a block *ending* the note
    /// genuinely has none, and asking for it there reserved 16pt of nothing.
    ///
    /// `baseURL` is the note's own folder, and it is what a relative `<img
    /// src="diagram.png">` inside the block resolves against. Preview has
    /// always been given it (`GFMPreview` loads with the note's directory);
    /// this renderer loaded with `nil`, so the *same* markup drew the picture
    /// on one surface and a broken-image box on the other — 338pt of it, on a
    /// `<div align="center">` wrapping a screenshot, which is the ordinary way
    /// to centre an image in a note. Nothing in the harness could see it
    /// either: a height sweep over one-construct examples has no images in its
    /// HTML blocks.
    public static func image(source: String, maxWidth: CGFloat, base: CGFloat,
                             palette: GFMRenderer.Palette?, isDark: Bool,
                             keepsTrailingMargin: Bool = true,
                             baseURL: URL? = nil) async -> PlatformImage? {
        guard maxWidth > 1, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        let page = GFMRenderer.page(
            source, base: base,
            // No padding: the editor's own text container already insets this
            // block, and a second inset here would indent every HTML block by
            // the pane's margin.
            box: .pane(inset: .zero, leading: 0),
            palette: palette)

        let host = OffscreenWebHost(width: maxWidth, isDark: isDark)
        defer { host.dismantle() }
        guard await host.load(page, baseURL: baseURL) else { return nil }
        guard let height = await host.contentHeight(keepsTrailingMargin: keepsTrailingMargin)
        else { return nil }
        // "It rendered nothing" is an answer, and a different one from "it did
        // not render". An empty `<div>` or a comment occupies no space on the
        // page, so the block must occupy none in the editor either — returning
        // nil here fell back to showing the source, which is three lines of
        // markup where the reader sees a blank. Only a failed load (above) is
        // allowed to leave the source visible.
        guard height > 0.5 else { return blankImage }
        return await host.snapshot(height: height)
    }
}

/// An image that occupies no space — what a block that renders to nothing
/// collapses to. Not zero-sized: a zero height would leave the band arithmetic
/// dividing by nothing and the fragment drawing a degenerate rect.
@MainActor
private var blankImage: PlatformImage {
    let size = CGSize(width: 1, height: 0.01)
    #if canImport(AppKit)
    return NSImage(size: size)
    #else
    // `UIImage` has no size-only initialiser; the smallest honest way to make
    // one is to render nothing into a context of that size.
    return UIGraphicsImageRenderer(size: size).image { _ in }
    #endif
}

/// Serves one HTML block's page, and whatever it references, out of the note's
/// own folder.
///
/// It exists for one reason: a `WKWebView` will not read a `file:` URL a page
/// points at unless the page itself came from a granted directory, and the
/// only API that grants one wants the page written into that directory. A
/// private scheme sidesteps both — the folder *is* the origin's root, so
/// `diagram.png` beside the note and `assets/diagram.png` under it both land
/// where the reader expects, and an `https://` image is untouched because the
/// handler never sees it.
@MainActor
final class BlockAssetScheme: NSObject, WKURLSchemeHandler {
    static let name = "hnblock"
    static let pageURL = URL(string: "hnblock://block/__block.html")!

    /// The page and the folder for the render in flight. One host renders one
    /// block, so there is never a second pair to confuse this with.
    var page = ""
    var root: URL?

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        let data: Data, mime: String
        if url.path == Self.pageURL.path {
            data = Data(page.utf8); mime = "text/html"
        } else if let root, let file = try? Data(contentsOf: Self.resolve(url.path, under: root)) {
            data = file
            // By content, not by extension: `<img src="photo">` is legal, and a
            // wrong `Content-Type` is a picture that does not draw.
            mime = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png"
                 : data.starts(with: [0xFF, 0xD8]) ? "image/jpeg"
                 : data.starts(with: [0x47, 0x49, 0x46]) ? "image/gif"
                 : data.starts(with: Array("<svg".utf8)) || data.starts(with: Array("<?xml".utf8))
                     ? "image/svg+xml"
                 : "application/octet-stream"
        } else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        task.didReceive(URLResponse(url: url, mimeType: mime,
                                    expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    /// A reference as a file under `root`. The leading slash is dropped rather
    /// than honoured — `URL(string:relativeTo:)` would send `/pic.png` to the
    /// filesystem root and `appendingPathComponent` would build `…/root//pic`.
    /// Both miss the file and only one of them looks like it worked. `..` is
    /// dropped too: a note's HTML block has no business reading its way up out
    /// of the folder it was rendered for.
    static func resolve(_ target: String, under root: URL) -> URL {
        var path = target.removingPercentEncoding ?? target
        while path.hasPrefix("/") { path.removeFirst() }
        return path.split(separator: "/")
            .filter { $0 != ".." && $0 != "." }
            .reduce(root) { $0.appendingPathComponent(String($1)) }
    }
}

/// A `WKWebView` that lives in an offscreen window for the length of one
/// render. It needs the window: `takeSnapshot` on a view that was never in one
/// returns an empty image on macOS, which is indistinguishable from "this HTML
/// draws nothing" and would have silently blanked every block.
@MainActor
final class OffscreenWebHost: NSObject, WKNavigationDelegate {
    private let web: WKWebView
    private var finished: CheckedContinuation<Bool, Never>?
    #if canImport(AppKit)
    private var window: NSWindow?
    #else
    private var window: UIWindow?
    #endif

    private let assets = BlockAssetScheme()

    init(width: CGFloat, isDark: Bool) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.setURLSchemeHandler(assets, forURLScheme: BlockAssetScheme.name)
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 1),
                        configuration: config)
        super.init()
        web.navigationDelegate = self
        #if canImport(AppKit)
        web.setValue(false, forKey: "drawsBackground")
        web.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: web.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Off every screen and never ordered front, so nothing appears on the
        // user's desktop while a note renders.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.contentView?.addSubview(web)
        self.window = window
        #else
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.overrideUserInterfaceStyle = isDark ? .dark : .light
        let window = UIWindow(frame: web.frame)
        window.isHidden = true
        window.addSubview(web)
        self.window = window
        #endif
    }

    func dismantle() {
        web.navigationDelegate = nil
        web.removeFromSuperview()
        #if canImport(AppKit)
        window?.close()
        #else
        // A `UIWindow` has no `close()`; hiding it and dropping the last
        // reference is the whole teardown. Spelled out rather than left to an
        // `#if` with one branch, because "iOS needs nothing here" and "iOS was
        // forgotten here" look identical when the else is missing.
        window?.isHidden = true
        #endif
        window = nil
    }

    /// Load and wait for the navigation to finish. False on failure.
    ///
    /// With a `baseURL` the page is served over `hnblock:` rather than handed
    /// to `loadHTMLString`, because `loadHTMLString(_:baseURL:)` **does not
    /// grant file read access**: give it `file:///…/Notes/` and every relative
    /// `<img>` still fails, silently, and the block renders with a
    /// broken-image box that is 338pt shorter than the picture Preview draws
    /// in the same place. The base URL was there and looked right, which is
    /// what made it a bad half-hour. `loadFileURL(_:allowingReadAccessTo:)`
    /// does grant it, and needs the page written to a file inside the folder
    /// being granted — i.e. inside the user's vault, which is not somewhere
    /// this renderer gets to write.
    ///
    /// Without one, `loadHTMLString` as before: a block with no folder to
    /// resolve against gains nothing from an origin, and giving every such
    /// page one would quietly change what a root-absolute `/url` means.
    func load(_ html: String, baseURL: URL? = nil) async -> Bool {
        await withCheckedContinuation { continuation in
            finished = continuation
            guard let baseURL else {
                web.loadHTMLString(html, baseURL: nil)
                return
            }
            assets.page = html
            assets.root = baseURL
            var request = URLRequest(url: BlockAssetScheme.pageURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            web.load(request)
        }
    }

    /// The rendered height of the article, in points.
    ///
    /// Two measurements, because the block is asked two different questions.
    ///
    /// **Mid-note** (`keepsTrailingMargin`) the answer is the article's border
    /// box between two zero-height sentinels, and the element's *own* margins
    /// are part of it: the editor gives an HTML block no margin of its own
    /// precisely so that this measurement decides, and a `<table>` carries
    /// `margin-bottom: 16px` where a `<div>` carries none. They are not there
    /// for the asking — the stylesheet zeroes `margin-bottom` on
    /// `.markdown-body > *:last-child`, and in a one-element fragment the
    /// element *is* the last child, so every table came back 16pt short. With a
    /// sentinel after it the rule no longer applies and the margin shows up as
    /// a gap inside the article's own height. (The sentinel at the *top* does
    /// the same for `:first-child`'s `margin-top: 0`, which is right for a note
    /// and wrong for a block sitting in the middle of one.)
    ///
    /// **Ending the note** the answer is where the page's ink stops —
    /// `PaintedContent.bottomJS`, the same rule `RenderParity` grades the whole
    /// note by. Dropping the bottom sentinel is not the same thing and only
    /// looked like it: it hands the last *element* back to `:last-child`, which
    /// zeroes that element's own margin and nothing else. A `<tr>` whose cells
    /// became an indented code block leaves an empty `<table>` as the last
    /// element, so the zeroing lands on a box that draws nothing, the listing
    /// above it keeps the 16pt margin between them, and the editor reserved a
    /// band of blank space under the end of the note (spec #160). The rule the
    /// editor already applies to its own trailing blocks — a box that paints
    /// nothing is a box of no height and no margin — had never been applied
    /// *inside* a rendered embed, because the boxes in there are WebKit's and
    /// `BlockBoxes` cannot see them. This is where it reaches them.
    func contentHeight(keepsTrailingMargin: Bool = true) async -> CGFloat? {
        let value = try? await web.evaluateJavaScript(
            Self.heightScript(keepsTrailingMargin: keepsTrailingMargin))
        return (value as? NSNumber).map { CGFloat(truncating: $0) }
    }

    /// The script `contentHeight` evaluates, split out so the *choice* can be
    /// tested without a `WKWebView` — one never finishes loading under
    /// `swift test`, so the numbers this returns are gated by
    /// `scripts/render-parity.sh` and only the decision can be pinned here.
    static func heightScript(keepsTrailingMargin: Bool) -> String {
        let measure = keepsTrailingMargin
            ? "b.getBoundingClientRect().height"
            : "paintedContentBottom(b)"
        return """
        (function () {
          \(PaintedContent.bottomJS)
          var b = document.querySelector('.markdown-body');
          if (!b) return 0;
          function pad() {
            var d = document.createElement('div');
            d.style.height = '0'; d.style.margin = '0'; d.style.padding = '0';
            d.style.border = '0';
            return d;
          }
          var top = pad(), bottom = \(keepsTrailingMargin ? "pad()" : "null");
          b.insertBefore(top, b.firstChild);
          if (bottom) b.appendChild(bottom);
          var h = \(measure);
          b.removeChild(top); if (bottom) b.removeChild(bottom);
          return h;
        })()
        """
    }

    func snapshot(height: CGFloat) async -> PlatformImage? {
        var frame = web.frame
        frame.size.height = height.rounded(.up)
        web.frame = frame
        #if canImport(AppKit)
        window?.setContentSize(frame.size)
        #else
        window?.frame = frame
        #endif
        // One turn of the runloop so the resize is laid out before the capture.
        await Task.yield()
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: frame.size)
        config.snapshotWidth = NSNumber(value: Double(frame.size.width))
        return try? await web.takeSnapshot(configuration: config)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { resume(true) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                             withError error: Error) {
        MainActor.assumeIsolated { resume(false) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        MainActor.assumeIsolated { resume(false) }
    }

    /// Resume once and only once — WebKit can report more than one terminal
    /// navigation event, and resuming a continuation twice is a crash.
    private func resume(_ value: Bool) {
        guard let continuation = finished else { return }
        finished = nil
        continuation.resume(returning: value)
    }
}
