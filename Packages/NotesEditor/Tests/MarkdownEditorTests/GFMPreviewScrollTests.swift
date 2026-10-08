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

    // MARK: - What each load is told

    /// Each page is told, before it is parsed, which page it is and where it
    /// opens — and still gets the enlarge buttons' script and the scroll
    /// reports'. A page handed over again is not loaded again, and does not
    /// take a new number: the page on screen keeps reporting for itself.
    @Test func eachPageIsToldWhereItOpens() throws {
        let web = WKWebView()
        let state = GFMWebLoadState()
        func scripts() -> [WKUserScript] { web.configuration.userContentController.userScripts }
        func opening() -> String? { scripts().first { $0.injectionTime == .atDocumentStart }?.source }

        GFMWebView.load(web, "<p>one</p>", 1, nil, state, note: "A")
        #expect(opening() == PreviewScrollRelay.openingScript(page: 1, offset: 0))
        #expect(scripts().contains { $0.source == DiagramZoomRelay.script && $0.injectionTime == .atDocumentEnd })
        #expect(scripts().contains { $0.source == PreviewScrollRelay.script && $0.injectionTime == .atDocumentEnd })
        #expect(scripts().count == 3)

        state.scroll.scrolled(to: 480, onPage: 1)
        GFMWebView.load(web, "<p>one</p>", 1, nil, state, note: "A")
        #expect(state.scroll.page == 1, "a page handed over again took a new number, so its reports stopped counting")
        GFMWebView.load(web, "<p>two</p>", 2, nil, state, note: "A")
        #expect(opening() == PreviewScrollRelay.openingScript(page: 2, offset: 480),
                "the next page of the note was not told where the last was left")
        #expect(scripts().count == 3, "a load left the scripts of the one before")
    }

    /// What a page posts is read as it was sent.
    @Test func aReportIsReadAsThePageSentIt() throws {
        let report = try #require(PreviewScrollRelay.report(from: ["page": 3, "y": 480.5]))
        #expect(report.page == 3 && report.offset == 480.5)
        #expect(PreviewScrollRelay.report(from: "480") == nil)
        #expect(PreviewScrollRelay.report(from: ["y": 480]) == nil)
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
