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
import MarkdownCore

/// SwiftUI preview view. Give it a pre-built HTML page (see `GFMRenderer.page`
/// / the app's resource-resolving wrapper) and the note folder for base
/// resolution.
public struct GFMPreview: View {
    private let html: String
    private let baseURL: URL?
    private let pageID: Int?
    private var busEditorID: String?
    private var onDiagramZoomHandler: ((DiagramZoom) -> Void)?
    private var onLinkTapHandler: ((EditorLinkTap) -> Void)?

    /// `html` is a complete page (e.g. `GFMRenderer.page(markdown)`), already
    /// with images inlined by the caller. `baseURL` is the note's folder.
    ///
    /// `pageID`, when given, names the page: two with the same id are the
    /// same page. The web view is handed a page on every redraw of whatever
    /// holds it and loads only a different one — which, without an id, it can
    /// tell only by hashing the page, a pass over all of it on the main actor.
    public init(html: String, baseURL: URL? = nil, pageID: Int? = nil) {
        self.html = html
        self.baseURL = baseURL
        self.pageID = pageID
    }

    /// Everything a preview page takes from the editor's theme, read where the
    /// theme lives — so the page itself can be built anywhere (`page(_:style:)`).
    nonisolated public struct PageStyle: Sendable, Equatable {
        let base: CGFloat
        let box: GFMRenderer.PageBox
        let palette: GFMRenderer.Palette?

        /// The page is measured as a **pane**, not a document — see
        /// `init(markdown:…)`.
        @MainActor public init(theme: EditorTheme, isDark: Bool) {
            base = theme.fontSize
            box = .pane(inset: EditorMetrics.textContainerInset,
                        leading: EditorMetrics.textLeadingInset)
            palette = theme.pagePalette(isDark: isDark)
        }
    }

    /// The page `init(markdown:…)` shows for `markdown`, on any thread: a
    /// whole-document render (cmark-gfm), which a view's initialiser runs on
    /// the main actor every time its parent redraws.
    nonisolated public static func page(_ markdown: String, style: PageStyle) -> String {
        GFMRenderer.page(markdown, base: style.base, box: style.box, palette: style.palette)
    }

    /// Convenience: render raw Markdown to a GitHub page directly.
    /// - Parameter base: the body size in points, used only when no `theme` is
    ///   supplied — when one is, **the theme's own size is what the page is
    ///   measured at**, so the two halves of Edit ≡ Preview cannot be given
    ///   different numbers. They could before: this took a scale and the theme
    ///   took a size, and a caller that passed `textScale` alongside a 17pt
    ///   theme got a 16pt page.
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
    ///
    /// Renders in the initialiser, so on the main actor at every redraw of the
    /// parent: for a page that follows typing, build it off the main actor
    /// with `page(_:style:)` and hand it over with an id.
    public init(markdown: String, baseURL: URL? = nil, base: CGFloat = 16,
                theme: EditorTheme? = nil, isDark: Bool = false) {
        let style = PageStyle(theme: theme ?? EditorTheme(fontSize: base), isDark: isDark)
        self.init(html: Self.page(markdown, style: style), baseURL: baseURL)
    }

    /// Answer heading jumps addressed to the editor `editorID` — the one whose
    /// note this previews. Without it the preview answers none (`EditorBus`).
    public func commandBus(editorID: String) -> Self {
        var copy = self; copy.busEditorID = editorID; return copy
    }

    /// Where a diagram's enlarge button on the page sends its press: any
    /// element carrying `data-hn-zoom` asks for the diagram whose source is its
    /// value (the app's `PreviewSuperset` draws them). No offsets here — a page
    /// has none — so the request carries the source alone.
    public func onDiagramZoom(_ handler: @escaping (DiagramZoom) -> Void) -> Self {
        var copy = self; copy.onDiagramZoomHandler = handler; return copy
    }

    /// Where a link clicked on the page goes, as a tap in Edit does: a wiki
    /// link as `.wiki` — its destination is a `hellonotes-wiki:` address
    /// (`NoteMarkdown`) — and anything else as `.url`. The page never follows
    /// a link itself, except to a place in the page (`PreviewLinkRelay`).
    public func onLinkTap(_ handler: @escaping (EditorLinkTap) -> Void) -> Self {
        var copy = self; copy.onLinkTapHandler = handler; return copy
    }

    public var body: some View {
        // No `.ignoresSafeArea()`. On macOS the split view's detail column
        // spans the whole window and the sidebar is drawn over it; the overlap
        // is published as a safe-area inset, and every other pane view honours
        // it. Preview did not, so it alone started underneath the sidebar with
        // its first glyphs hidden — which reads exactly like the document
        // shifting sideways when you switch out of Edit.
        GFMWebView(html: html, baseURL: baseURL, pageID: pageID, editorID: busEditorID,
                   onDiagramZoom: onDiagramZoomHandler, onLinkTap: onLinkTapHandler)
    }
}

/// Carries the page's "enlarge this diagram" messages to whoever is listening.
///
/// An object of its own, holding the listener weakly, because
/// `WKUserContentController` keeps a strong reference to its handlers for as
/// long as the web view lives — a handler that held the preview's state would
/// keep that alive with it.
@MainActor final class DiagramZoomRelay: NSObject, WKScriptMessageHandler {
    /// The name the page posts to: `window.webkit.messageHandlers.<name>`.
    static let name = "hnDiagramZoom"

    /// Posts the value of a clicked `data-hn-zoom` element. Delegated from the
    /// document, so it holds for every page this web view is handed without
    /// being part of any of them.
    static let script = """
    document.addEventListener('click', function (event) {
      var target = event.target && event.target.closest ? event.target.closest('[data-hn-zoom]') : null;
      if (!target) return;
      event.preventDefault();
      try { window.webkit.messageHandlers.\(name).postMessage(target.getAttribute('data-hn-zoom')); } catch (e) {}
    });
    """

    weak var state: GFMWebLoadState?

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let source = message.body as? String else { return }
        state?.onDiagramZoom?(DiagramZoom(source: source))
    }
}

/// Decides where a link clicked on the page goes.
///
/// Preview's web view had no navigation delegate, so a click on a link was
/// WebKit's to handle: a wiki link went somewhere the app never heard of, and
/// a web link replaced the preview with the page it named. Every link the
/// reader activates is now cancelled and handed to the host
/// (`GFMPreview.onLinkTap`) — except a place in the page itself, a footnote and
/// the way back from it, which the page scrolls to. A page loading is not a
/// link activated, and goes ahead.
///
/// Held by the load state, weakly back, like the message relays: a web view
/// holds its navigation delegate weakly.
@MainActor final class PreviewLinkRelay: NSObject, WKNavigationDelegate {
    weak var state: GFMWebLoadState?

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url,
              let tap = GFMPreview.linkTap(for: url, page: webView.url) else { return .allow }
        state?.onLinkTap?(tap)
        return .cancel
    }

    /// The page is up, headings and all.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        state?.pageDidFinish()
    }
}

extension GFMPreview {
    /// What a link to `url`, clicked on the page at `page`, asks for — `nil`
    /// when it is a place in that page, which the page scrolls to itself.
    nonisolated public static func linkTap(for url: URL, page: URL?) -> EditorLinkTap? {
        if url.scheme == WikiLinkSyntax.urlScheme {
            let written = url.absoluteString.dropFirst(WikiLinkSyntax.urlScheme.count + 1)
            return .wiki(target: written.removingPercentEncoding ?? String(written))
        }
        if url.fragment != nil, let page, withoutFragment(url) == withoutFragment(page) { return nil }
        return .url(url)
    }

    private nonisolated static func withoutFragment(_ url: URL) -> String {
        let text = url.absoluteString
        return text.firstIndex(of: "#").map { String(text[..<$0]) } ?? text
    }
}

/// Keeps the reader's place across pages.
///
/// Every page is a new document (`loadHTMLString`), and a new document starts
/// at the top — so in Split mode, with the preview scrolled down to a diagram,
/// one character typed in the source brought it back to the note's first line
/// once typing paused; in Preview, so did any change made under it. The page
/// now says where it has been scrolled to, as it scrolls, and the next page is
/// told where to open (`PreviewScrollMemory`): it scrolls itself there as soon
/// as it has been parsed — before it has been drawn, where a navigation
/// delegate's "finished" comes after — and again once everything has loaded,
/// for a picture that had no size until then, unless the reader has moved it.
///
/// The same weakly-held relay as `DiagramZoomRelay`, for the same reason.
@MainActor final class PreviewScrollRelay: NSObject, WKScriptMessageHandler {
    /// The name the page posts to: `window.webkit.messageHandlers.<name>`.
    static let name = "hnPreviewScroll"

    /// Where this page opens: its number and its offset, set before the
    /// document is parsed (`GFMWebView.installScripts`).
    static func openingScript(page: Int, offset: Double) -> String {
        "window.__hnScroll = { page: \(page), to: \(offset) };"
    }

    /// Scrolls the page to where it opens, and posts where the reader scrolls
    /// it — at most once a frame, with the page's number, so a report from a
    /// page since replaced is told apart. The scroll it makes itself is not
    /// the reader's, so it is not posted: a page shorter than the offset —
    /// the plain page before a note's diagrams are drawn — would otherwise
    /// report the shortfall as where the reader was.
    static let script = """
    (function () {
      var opening = window.__hnScroll || { page: 0, to: 0 };
      var restoring = false, queued = false, moved = false;
      function post() {
        queued = false;
        if (restoring) return;
        moved = true;
        try {
          window.webkit.messageHandlers.\(name).postMessage({ page: opening.page, y: window.scrollY });
        } catch (e) {}
      }
      window.addEventListener('scroll', function () {
        if (!queued) { queued = true; window.requestAnimationFrame(post); }
      }, { passive: true });
      function restore() {
        if (moved || !(opening.to > 0)) return;
        restoring = true;
        window.scrollTo(0, opening.to);
        window.requestAnimationFrame(function () {
          window.requestAnimationFrame(function () { restoring = false; });
        });
      }
      restore();
      window.addEventListener('load', restore);
    })();
    """

    weak var state: GFMWebLoadState?

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let report = Self.report(from: message.body) else { return }
        state?.scroll.scrolled(to: report.offset, onPage: report.page)
    }

    /// What a page's message says: which page, scrolled how far.
    static func report(from body: Any) -> (page: Int, offset: Double)? {
        guard let fields = body as? [String: Any],
              let page = (fields["page"] as? NSNumber)?.intValue,
              let offset = (fields["y"] as? NSNumber)?.doubleValue else { return nil }
        return (page, offset)
    }
}

/// Where the reader left each note's page, and which page is on screen.
///
/// **A page of the note on screen opens where the last was left**: the page
/// that follows a pause in typing, or a change made under Preview. **A note
/// this preview has not shown opens at the top**, and one it has shown before
/// — a tab switched away from and back to, in the same pane — where it was
/// left: an offset belongs to the note it was measured in, and carried to
/// another it points at nothing in particular. Notes are told apart by the
/// editor the preview answers for (`GFMPreview.commandBus(editorID:)`).
///
/// Pages are numbered as they load, and a report counts only for the page on
/// screen: a message still on its way from the page before — the last frame
/// of a scroll, a tab switch — would otherwise be taken for the new page's.
struct PreviewScrollMemory {
    /// The number of the page loading or on screen.
    private(set) var page = 0
    /// The note that page shows (`""` for a preview that names none).
    private var note = ""
    /// Where each note was left, and which were left most recently — so the
    /// memory stays the size of the notes in use, not of every note opened.
    private var offsets: [String: Double] = [:]
    private var recent: [String] = []
    static let capacity = 64

    /// A page of `note` is about to load: its number, and where it opens.
    mutating func load(note: String?) -> (page: Int, offset: Double) {
        page &+= 1
        self.note = note ?? ""
        return (page, offsets[self.note] ?? 0)
    }

    /// The reader scrolled page `page` to `offset`.
    mutating func scrolled(to offset: Double, onPage page: Int) {
        guard page == self.page, offset.isFinite else { return }
        offsets[note] = max(0, offset)
        guard recent.last != note else { return }
        recent.removeAll { $0 == note }
        recent.append(note)
        if recent.count > Self.capacity { offsets[recent.removeFirst()] = nil }
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

    /// The web view this state belongs to, so a heading jump has something to
    /// scroll. Weak: the coordinator must not keep the view alive.
    weak var web: WKWebView?
    /// Where the page's enlarge buttons send their press, as the host last said.
    var onDiagramZoom: ((DiagramZoom) -> Void)?
    /// Where a link clicked on the page goes, as the host last said.
    var onLinkTap: ((EditorLinkTap) -> Void)?
    /// Decides each navigation the page asks for. Made with the state, so the
    /// web view can be built with it.
    lazy var linkRelay: PreviewLinkRelay = {
        let relay = PreviewLinkRelay()
        relay.state = self
        return relay
    }()
    /// The page's messages arrive here. Made with the state, so the web view
    /// can be built with it.
    lazy var diagramZoomRelay: DiagramZoomRelay = {
        let relay = DiagramZoomRelay()
        relay.state = self
        return relay
    }()
    /// Where the reader left each note's page (`PreviewScrollMemory`).
    var scroll = PreviewScrollMemory()
    /// The page's scroll reports arrive here.
    lazy var scrollRelay: PreviewScrollRelay = {
        let relay = PreviewScrollRelay()
        relay.state = self
        return relay
    }()
    /// Whether the page in the web view has finished loading: a heading can be
    /// scrolled to only in a page that has its headings. Cleared as a load
    /// starts (`GFMWebView.load`), set when it finishes (`PreviewLinkRelay`).
    var pageReady = false

    /// Heading jumps addressed to this preview's editor, shown when the page is
    /// up — straight away, or when it finishes loading (`EditorBus`).
    lazy var headingJumps = HeadingJumpListener(
        isReady: { [weak self] in
            guard let self, let web = self.web else { return false }
            return web.window != nil && self.pageReady
        },
        show: { [weak self] jump in self?.scroll(to: jump.title, ordinal: jump.ordinal) })

    /// The page finished loading: a jump waiting for it can be shown now.
    func pageDidFinish() {
        pageReady = true
        headingJumps.surfaceBecameReady()
    }

    /// Answer heading jumps while this preview is the surface on screen.
    ///
    /// **The outline only ever worked in Edit mode**, and even there it landed
    /// in the wrong place. The jump was posted as a find query for the heading's
    /// own text, so the only listeners were the two inside `MarkdownEditorView`
    /// — Preview, Markdown and Split had none and did nothing at all — and what
    /// those two did was select the first occurrence of those words anywhere in
    /// the file, which is the front matter's `title:` line as often as not.
    ///
    /// Every surface now answers the same positional notification, addressed
    /// to the editor it belongs to (`EditorBus`). It was addressed to no one,
    /// and the `window != nil` guard below was meant to make "the visible one"
    /// the one that answered — but every window's preview is visible, so an
    /// outline tapped in one window scrolled the preview in every other. In
    /// Split both panes are the same editor and both jump, which is what you
    /// want.
    ///
    /// Re-targets when the id changes: the coordinator outlives the note it
    /// was made for, and an observer left on the old id is a jump that lands
    /// nowhere. A jump that arrives while the page is still loading waits for
    /// it (`pageDidFinish`) rather than running its script over a page with no
    /// headings in it yet.
    func observeHeadingJumps(editorID: String?) {
        headingJumps.editorID = editorID
    }

    /// Scroll to the heading whose text is `title`.
    ///
    /// By **text**, not by anchor: cmark-gfm emits bare `<h1>`…`<h6>` with no
    /// `id`, and adding ids would change the rendered HTML that `GFMRender`'s
    /// byte-parity tests compare against GitHub's own API. The page shell is
    /// ours to script; the rendered markdown is not ours to alter.
    ///
    /// `DocumentHeading.title` is `plainText` — inline markup already stripped
    /// — which is the same thing `textContent` gives back, so the two are
    /// directly comparable.
    private func scroll(to title: String, ordinal: Int?) {
        guard let web, web.window != nil, !title.isEmpty else { return }
        guard let json = try? JSONSerialization.data(withJSONObject: [title, ordinal ?? -1]),
              let literal = String(data: json, encoding: .utf8) else { return }
        // **Ordinal first, text second.** Two notes in the sample collection have
        // a heading whose words appear earlier in the prose, and matching on text
        // alone lands on the prose. Headings render in document order, so the
        // n-th `<h1>…<h6>` here is the n-th row in the outline — exact even when
        // two headings share a name. The text match stays as the fallback for a
        // caller that has no ordinal, and is checked against the ordinal's
        // element first so a mismatch degrades rather than jumping somewhere
        // arbitrary.
        web.evaluateJavaScript("""
        (function (args) {
          var t = args[0], n = args[1];
          var hs = document.querySelectorAll('h1,h2,h3,h4,h5,h6');
          if (n >= 0 && n < hs.length && hs[n].textContent.trim() === t) {
            hs[n].scrollIntoView(true);
            return true;
          }
          for (var i = 0; i < hs.length; i++) {
            if (hs[i].textContent.trim() === t) { hs[i].scrollIntoView(true); return true; }
          }
          return false;
        })(\(literal))
        """)
    }

}

#if canImport(AppKit)
struct GFMWebView: NSViewRepresentable {
    let html: String
    let baseURL: URL?
    /// Names the page (`GFMPreview.init(html:baseURL:pageID:)`).
    var pageID: Int? = nil
    /// The editor this preview answers heading jumps for (`EditorBus`).
    var editorID: String? = nil
    /// Where the page's diagram enlarge buttons send their press.
    var onDiagramZoom: ((DiagramZoom) -> Void)? = nil
    /// Where a link clicked on the page goes.
    var onLinkTap: ((EditorLinkTap) -> Void)? = nil
    func makeCoordinator() -> GFMWebLoadState { GFMWebLoadState() }
    func makeNSView(context: Context) -> WKWebView {
        Self.log("make")
        let web = Self.makeWebView(state: context.coordinator)
        context.coordinator.web = web
        context.coordinator.onDiagramZoom = onDiagramZoom
        context.coordinator.onLinkTap = onLinkTap
        context.coordinator.observeHeadingJumps(editorID: editorID)
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.onDiagramZoom = onDiagramZoom
        context.coordinator.onLinkTap = onLinkTap
        context.coordinator.observeHeadingJumps(editorID: editorID)
        Self.load(web, html, pageID, baseURL, context.coordinator, note: editorID)
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
    /// Names the page (`GFMPreview.init(html:baseURL:pageID:)`).
    var pageID: Int? = nil
    /// The editor this preview answers heading jumps for (`EditorBus`).
    var editorID: String? = nil
    /// Where the page's diagram enlarge buttons send their press.
    var onDiagramZoom: ((DiagramZoom) -> Void)? = nil
    /// Where a link clicked on the page goes.
    var onLinkTap: ((EditorLinkTap) -> Void)? = nil
    func makeCoordinator() -> GFMWebLoadState { GFMWebLoadState() }
    func makeUIView(context: Context) -> WKWebView {
        Self.log("make")
        let web = Self.makeWebView(state: context.coordinator)
        context.coordinator.web = web
        context.coordinator.onDiagramZoom = onDiagramZoom
        context.coordinator.onLinkTap = onLinkTap
        context.coordinator.observeHeadingJumps(editorID: editorID)
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.onDiagramZoom = onDiagramZoom
        context.coordinator.onLinkTap = onLinkTap
        context.coordinator.observeHeadingJumps(editorID: editorID)
        Self.load(web, html, pageID, baseURL, context.coordinator, note: editorID)
    }
    // Viewport sizing — docs/layout-architecture.md S1.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: WKWebView,
                      context: Context) -> CGSize? { viewportSizeThatFits(proposal) }
}
#endif

extension GFMWebView {
    static func makeWebView(state: GFMWebLoadState) -> WKWebView {
        let config = WKWebViewConfiguration()
        // JS is needed only for the bundled highlight.js; any `<script>` in the
        // note itself is already escaped by cmark-gfm's tagfilter.
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // What the page says — a diagram's enlarge button pressed, how far it
        // has been scrolled: one handler each for the web view's whole life,
        // and the scripts that say it installed before the first page, so no
        // page can be without them.
        config.userContentController.add(state.diagramZoomRelay, name: DiagramZoomRelay.name)
        config.userContentController.add(state.scrollRelay, name: PreviewScrollRelay.name)
        installScripts(config.userContentController, page: 0, offset: 0)
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = state.linkRelay
        #if canImport(AppKit)
        web.setValue(false, forKey: "drawsBackground")
        #else
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        #endif
        return web
    }

    /// The scripts every page gets — the enlarge buttons', and the scroll
    /// reports' — and where the next page opens. A user script is fixed for
    /// the document it is injected into, so where a page opens is written into
    /// one just before it loads; `WKUserContentController` removes only all of
    /// them at once, so all of them are put back.
    static func installScripts(_ controller: WKUserContentController, page: Int, offset: Double) {
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(
            source: PreviewScrollRelay.openingScript(page: page, offset: offset),
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(
            source: DiagramZoomRelay.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(
            source: PreviewScrollRelay.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    /// Load only when the content actually changed (avoid reload-on-every-
    /// SwiftUI-update flicker) — by the page's id when it has one, and by a
    /// hash of the page, taken once, when it has not. `note` names the note
    /// the page shows, so it opens where that note was left
    /// (`PreviewScrollMemory`).
    static func load(_ web: WKWebView, _ html: String, _ pageID: Int?, _ baseURL: URL?,
                     _ state: GFMWebLoadState, note: String? = nil) {
        let key = pageID ?? html.hashValue
        guard state.loaded != key else {
            log("skip \(html.utf8.count) bytes — already loaded")
            return
        }
        state.loaded = key
        state.pageReady = false
        let opening = state.scroll.load(note: note)
        installScripts(web.configuration.userContentController, page: opening.page, offset: opening.offset)
        log("load \(html.utf8.count) bytes, frame \(web.frame.size), opening at \(opening.offset)")
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
