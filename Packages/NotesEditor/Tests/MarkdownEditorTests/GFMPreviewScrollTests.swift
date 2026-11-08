//
//  GFMPreviewScrollTests.swift
//  MarkdownEditorTests
//
//  Every page Preview is handed is a new document, and a new document starts
//  at the top: typing one character in Split mode's source brought a preview
//  scrolled down to a diagram back to the note's first line once typing
//  paused. The page now says where it is scrolled to, and the next page opens
//  there (`PreviewScrollRelay`, `PreviewScrollMemory`).
//
//  A `WKWebView` never finishes loading here (nor under XCTest in the app
//  host), so what is tested is what can be: which page opens where, what each
//  load is told, what a report means — and the page's own script, run in
//  JavaScriptCore against a model of the browser's frame: a scroll event is
//  dispatched when the frame is drawn, then the frame callbacks asked for so
//  far. Seen working in the app on the HN-iPad simulator (implemented.md §51.23).
//

import Foundation
import JavaScriptCore
import Testing
import WebKit
@testable import MarkdownEditor

@MainActor
struct GFMPreviewScrollTests {

    // MARK: - Which page opens where

    /// The page that follows a pause in typing — or a change made under
    /// Preview — opens where the reader left the one before, and one the
    /// reader never scrolled opens where that one did.
    @Test func aPageOfTheNoteOnScreenOpensWhereTheLastWasLeft() {
        var memory = PreviewScrollMemory()
        #expect(memory.load(note: "A") == (1, 0))
        memory.scrolled(to: 480, onPage: 1)
        #expect(memory.load(note: "A") == (2, 480), "a new page of the note went back to the top")
        #expect(memory.load(note: "A") == (3, 480), "a page nobody scrolled forgot where the note was")
    }

    /// An offset belongs to the note it was measured in: a note this preview
    /// has not shown opens at the top, and one it has — a tab switched away
    /// from and back to — opens where it was left.
    @Test func aNoteOpensAtTheTopTheFirstTimeAndWhereItWasLeftAfter() {
        var memory = PreviewScrollMemory()
        _ = memory.load(note: "A")
        memory.scrolled(to: 480, onPage: 1)
        #expect(memory.load(note: "B") == (2, 0), "another note opened at the first one's offset")
        memory.scrolled(to: 120, onPage: 2)
        #expect(memory.load(note: "A") == (3, 480), "a note switched back to lost its place")
        #expect(memory.load(note: "B") == (4, 120))
    }

    /// A report still on its way from a page that has since been replaced —
    /// the last frame of a scroll, a switch of tab — is not the new page's.
    /// The control: the same report, from the page on screen, counts.
    @Test func aReportFromAPageSinceReplacedIsNotTaken() {
        var memory = PreviewScrollMemory()
        _ = memory.load(note: "A")
        memory.scrolled(to: 480, onPage: 1)
        _ = memory.load(note: "B")
        memory.scrolled(to: 900, onPage: 1)
        #expect(memory.load(note: "B") == (3, 0), "a report from note A's page was taken for note B's")
        #expect(memory.load(note: "A") == (4, 480), "a report from a replaced page moved the note it came from")
        memory.scrolled(to: 900, onPage: 4)
        #expect(memory.load(note: "A") == (5, 900), "a report from the page on screen was not taken")
    }

    /// A preview that names no note keeps one place for whatever it shows.
    @Test func aPreviewThatNamesNoNoteKeepsItsPlace() {
        var memory = PreviewScrollMemory()
        _ = memory.load(note: nil)
        memory.scrolled(to: 64, onPage: 1)
        #expect(memory.load(note: nil) == (2, 64))
    }

    /// What a page cannot mean is not taken: a number that is not one, or a
    /// place above the top (the overscroll of a bounce).
    @Test func aReportThatMeansNothingIsNotTaken() {
        var memory = PreviewScrollMemory()
        _ = memory.load(note: "A")
        memory.scrolled(to: 300, onPage: 1)
        memory.scrolled(to: .nan, onPage: 1)
        #expect(memory.load(note: "A") == (2, 300))
        memory.scrolled(to: -40, onPage: 2)
        #expect(memory.load(note: "A") == (3, 0))
    }

    /// The memory keeps the notes in use, not every note ever opened.
    @Test func theMemoryKeepsTheNotesInUse() {
        var memory = PreviewScrollMemory()
        for index in 0...PreviewScrollMemory.capacity {
            let (page, _) = memory.load(note: "Note \(index)")
            memory.scrolled(to: Double(index + 1), onPage: page)
        }
        #expect(memory.load(note: "Note 0").offset == 0, "the note used longest ago was kept past the capacity")
        #expect(memory.load(note: "Note 1").offset == 2, "a note still in use was forgotten")
    }

    // MARK: - Between launches

    /// **A note this preview has not shown opens where the host says it was
    /// left** — kept beyond the app, since an iPhone ends a suspended app when
    /// it likes (implemented.md §51.69) — and one it has shown, where this
    /// preview left it: the host's place is older than the reader's last
    /// scroll. The control: with no place from the host, the top.
    @Test func aNoteNotYetShownOpensWhereTheHostSaysItWasLeft() {
        var memory = PreviewScrollMemory()
        var asked = 0
        let kept: () -> Double? = { asked += 1; return 640 }
        #expect(memory.load(note: "A", opening: kept) == (1, 640), "the place kept between launches was not used")
        memory.scrolled(to: 200, onPage: 1)
        #expect(memory.load(note: "A", opening: kept) == (2, 200), "the host's older place won over the reader's scroll")
        #expect(asked == 1, "the host was asked about a note this preview had shown")
        #expect(memory.load(note: "B", opening: { nil }) == (3, 0))
    }

    /// A place the host keeps that cannot be one — the top, above it, not a
    /// number — opens the note at its top.
    @Test func aKeptPlaceThatMeansNothingOpensAtTheTop() {
        for nonsense in [0, -40, Double.nan, .infinity] {
            var memory = PreviewScrollMemory()
            #expect(memory.load(note: "A", opening: { nonsense }) == (1, 0), "a kept place of \(nonsense) was used")
        }
    }

    /// **The host hears where the reader scrolls — from the page on screen
    /// only**: a report from a page since replaced would have been kept as the
    /// new note's place. The control: the page on screen's report is heard.
    @Test func theHostHearsOnlyTheReportsThatCount() {
        let state = GFMWebLoadState()
        var heard: [Double] = []
        state.onPlaceChange = { heard.append($0) }
        _ = state.scroll.load(note: "A")
        state.scrollRelay.take(["page": 1, "y": 480])
        #expect(heard == [480], "the page on screen's report was not heard")
        _ = state.scroll.load(note: "B")
        state.scrollRelay.take(["page": 1, "y": 900])
        #expect(heard == [480], "a report from note A's replaced page was told as note B's place")
        state.scrollRelay.take(["page": 2, "y": -20])
        #expect(heard == [480, 0], "the bounce above the top was told as a place above it")
        state.scrollRelay.take("not a report")
        #expect(heard == [480, 0])
    }

    /// The page is told to open where the host says, before it is parsed —
    /// the same opening script as a place this preview remembers.
    @Test func aPageIsToldTheHostsPlace() {
        let web = WKWebView(frame: Self.paneFrame)
        let state = GFMWebLoadState()
        state.openingPlace = { 640 }
        GFMWebView.load(web, "<p>one</p>", 1, nil, state, note: "A")
        let opening = web.configuration.userContentController.userScripts
            .first { $0.injectionTime == .atDocumentStart }?.source
        #expect(opening == PreviewScrollRelay.openingScript(page: 1, offset: 640))
    }

    /// A pane's size, for a web view that has been laid out.
    static let paneFrame = CGRect(x: 0, y: 0, width: 428, height: 650)

    /// **A page waits for its web view's size.** Handed over before the view
    /// had one, a page was put where its note was left in one layout — with
    /// no column margins, which came only after it had loaded — and shown in
    /// another (implemented.md §51.69). Held, it loads as the view is given a
    /// size, with the latest page handed over, told where it opens and its
    /// column's margins at that width. The control: a view with a size loads
    /// at once.
    @Test func aPageWaitsForItsWebViewsSize() {
        let state = GFMWebLoadState()
        state.openingPlace = { 1_530 }
        let web = GFMWebView.makeWebView(state: state)
        state.web = web
        func opening() -> String? {
            web.configuration.userContentController.userScripts
                .first { $0.injectionTime == .atDocumentStart }?.source
        }
        GFMWebView.load(web, "<p>one</p>", 1, nil, state, note: "A")
        GFMWebView.load(web, "<p>two</p>", 2, nil, state, note: "A")
        #expect(state.loaded == nil, "a page loaded into a web view with no size")
        #expect(state.scroll.page == 0, "a page held for a size took a number")

        web.frame = Self.paneFrame
        #if !canImport(AppKit)
        web.layoutIfNeeded()
        #endif
        #expect(state.loaded == 2, "the latest page did not load once the view had a size")
        #expect(opening() == PreviewScrollRelay.openingScript(page: 1, offset: 1_530),
                "the page that waited was not told where its note was left")

        let sized = WKWebView(frame: Self.paneFrame)
        let ready = GFMWebLoadState()
        GFMWebView.load(sized, "<p>one</p>", 1, nil, ready, note: "A")
        #expect(ready.loaded == 1, "a view with a size did not load at once")
    }

    // MARK: - What each load is told

    /// Each page is told, before it is parsed, which page it is and where it
    /// opens, and its text column's margins — and still gets the enlarge
    /// buttons' script and the scroll reports'. A page handed over again is not
    /// loaded again, and does not take a new number: the page on screen keeps
    /// reporting for itself.
    @Test func eachPageIsToldWhereItOpens() throws {
        let web = WKWebView(frame: Self.paneFrame)
        let state = GFMWebLoadState()
        func scripts() -> [WKUserScript] { web.configuration.userContentController.userScripts }
        func opening() -> String? { scripts().first { $0.injectionTime == .atDocumentStart }?.source }

        GFMWebView.load(web, "<p>one</p>", 1, nil, state, note: "A")
        #expect(opening() == PreviewScrollRelay.openingScript(page: 1, offset: 0))
        #expect(scripts().contains { $0.source == GFMWebLoadState.marginScript((0, 0))
                                     && $0.injectionTime == .atDocumentStart })
        #expect(scripts().contains { $0.source == DiagramZoomRelay.script && $0.injectionTime == .atDocumentEnd })
        #expect(scripts().contains { $0.source == PreviewScrollRelay.script && $0.injectionTime == .atDocumentEnd })
        // The room past the end, and before the scroll relay — a page left
        // scrolled into its room is put back there only once the room exists.
        let ends = scripts().filter { $0.injectionTime == .atDocumentEnd }.map(\.source)
        let room = try #require(ends.firstIndex(of: PreviewRoom.script), "the page has no room past its end")
        #expect(room < (ends.firstIndex(of: PreviewScrollRelay.script) ?? -1))
        #expect(scripts().count == 5)

        state.scroll.scrolled(to: 480, onPage: 1)
        GFMWebView.load(web, "<p>one</p>", 1, nil, state, note: "A")
        #expect(state.scroll.page == 1, "a page handed over again took a new number, so its reports stopped counting")
        GFMWebView.load(web, "<p>two</p>", 2, nil, state, note: "A")
        #expect(opening() == PreviewScrollRelay.openingScript(page: 2, offset: 480),
                "the next page of the note was not told where the last was left")
        #expect(scripts().count == 5, "a load left the scripts of the one before")
    }

    /// What a page posts is read as it was sent.
    @Test func aReportIsReadAsThePageSentIt() throws {
        let report = try #require(PreviewScrollRelay.report(from: ["page": 3, "y": 480.5]))
        #expect(report.page == 3 && report.offset == 480.5)
        #expect(PreviewScrollRelay.report(from: "480") == nil)
        #expect(PreviewScrollRelay.report(from: ["y": 480]) == nil)
    }

    /// **An offset no page has is passed over.** A page's script posts it,
    /// and the host keeps it as a whole number of points, so an infinite one
    /// trapped the app as it kept the reader's place (implemented.md §51.72).
    /// The control is the same page's real offset, read as sent.
    @Test func anOffsetNoPageHasIsPassedOver() throws {
        for offset in [Double.infinity, -Double.infinity, Double.nan, 1e300, PreviewScrollRelay.maximumOffset * 2] {
            #expect(PreviewScrollRelay.report(from: ["page": 3, "y": offset]) == nil, "\(offset) was taken for a place")
        }
        #expect(try #require(PreviewScrollRelay.report(from: ["page": 3, "y": 1_234_567.0])).offset == 1_234_567)
    }

    // MARK: - The page's own script

    /// The page's script in JavaScriptCore, told to open at `offset`, with
    /// the parts of a browser it uses. `frame()` draws a frame: the scroll
    /// event, if the page scrolled since the last one, then the frame
    /// callbacks asked for so far. `readerScrolls(y)` is the reader.
    private func page(opening offset: Double, number: Int = 7) throws -> JSContext {
        let context = try #require(JSContext())
        var failure: String?
        context.exceptionHandler = { _, value in failure = value?.toString() }
        context.evaluateScript("""
        var window = this;
        var posted = [], scrolledTo = [], listeners = {}, frameCallbacks = [], scrollPending = false;
        window.scrollY = 0;
        window.scrollTo = function (x, y) {
          scrolledTo.push(y);
          if (window.scrollY !== y) { window.scrollY = y; scrollPending = true; }
        };
        window.addEventListener = function (type, handler) {
          (listeners[type] = listeners[type] || []).push(handler);
        };
        window.requestAnimationFrame = function (callback) { frameCallbacks.push(callback); return frameCallbacks.length; };
        window.webkit = { messageHandlers: { \(PreviewScrollRelay.name): { postMessage: function (m) { posted.push(m); } } } };
        function fire(type) { (listeners[type] || []).slice().forEach(function (h) { h(); }); }
        function frame() {
          if (scrollPending) { scrollPending = false; fire('scroll'); }
          var callbacks = frameCallbacks; frameCallbacks = [];
          callbacks.forEach(function (c) { c(); });
        }
        function readerScrolls(y) { window.scrollY = y; scrollPending = true; }
        """)
        context.evaluateScript(PreviewScrollRelay.openingScript(page: number, offset: offset))
        context.evaluateScript(PreviewScrollRelay.script)
        #expect(failure == nil, "the page's script threw: \(failure ?? "")")
        return context
    }

    private func frames(_ count: Int, in context: JSContext) {
        for _ in 0..<count { context.evaluateScript("frame()") }
    }

    private func scrolledTo(in context: JSContext) -> [Double] {
        (context.objectForKeyedSubscript("scrolledTo").toArray() ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
    }

    private func posted(in context: JSContext) -> [(page: Int, offset: Double)] {
        (context.objectForKeyedSubscript("posted").toArray() ?? []).compactMap { PreviewScrollRelay.report(from: $0) }
    }

    /// A page told to open down the note scrolls itself there as soon as it
    /// has been parsed — and does not report that scroll as the reader's. A
    /// page shorter than the offset, the plain one before a note's diagrams
    /// are drawn, would otherwise have reported how far it could go as where
    /// the reader was.
    @Test func aPageOpensWhereItIsToldAndDoesNotReportItsOwnScroll() throws {
        let context = try page(opening: 480)
        #expect(scrolledTo(in: context) == [480], "the page did not open where it was told")
        frames(3, in: context)
        #expect(posted(in: context).isEmpty, "the page reported its own opening scroll as the reader's")
    }

    /// Where the reader scrolls it is reported, with the page's number, at
    /// most once a frame.
    @Test func theReadersScrollIsReportedOnceAFrame() throws {
        let context = try page(opening: 480)
        frames(3, in: context)
        context.evaluateScript("readerScrolls(560); fire('scroll'); readerScrolls(600)")
        frames(1, in: context)
        let reports = posted(in: context)
        #expect(reports.count == 1, "a frame's scroll was reported \(reports.count) times")
        #expect(reports.first?.page == 7 && reports.first?.offset == 600)
    }

    /// Once everything has loaded — a picture with no size of its own grows
    /// the page — it is scrolled there again, unless the reader has moved it
    /// since; and a page opening at the top is not scrolled at all.
    @Test func aPageIsScrolledAgainWhenLoadedUnlessTheReaderMovedIt() throws {
        let untouched = try page(opening: 480)
        frames(3, in: untouched)
        untouched.evaluateScript("window.scrollY = 300; fire('load')")
        #expect(scrolledTo(in: untouched) == [480, 480], "a page that grew once loaded was not put back where it opens")
        frames(3, in: untouched)
        #expect(posted(in: untouched).isEmpty, "putting it back was reported as the reader's")

        let moved = try page(opening: 480)
        frames(3, in: moved)
        moved.evaluateScript("readerScrolls(900)")
        frames(1, in: moved)
        moved.evaluateScript("fire('load')")
        #expect(scrolledTo(in: moved) == [480], "the page took the reader back after they had moved it")

        let top = try page(opening: 0)
        top.evaluateScript("fire('load')")
        #expect(scrolledTo(in: top).isEmpty, "a page opening at the top was scrolled")
    }
}
