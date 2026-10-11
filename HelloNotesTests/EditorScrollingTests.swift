//
//  EditorScrollingTests.swift
//  HelloNotesTests
//
//  A note scrolls past its end until its last line is about the middle of
//  the window, the line being written at the bottom is never cut off, and the
//  editor fills its pane, its scroller at the pane's edge — checked in the
//  editor **as the app hosts it**: `NoteEditorView` in a window, scrolled to
//  the end a wheel step at a time, nothing laid out by hand.
//
//  Build 28 broke the first two on the Mac and no test saw it. The room past
//  the end was a wider limit on the clip view, which a wheel honours — every
//  test, here and in the package, scrolled by wheel or asked the clip view
//  directly, and passed — and which a trackpad's scrolling did not keep to: the
//  note stopped at its last line, drawn cut through the middle where the text
//  view's frame ended under it. A trackpad cannot be driven from a test (its
//  gesture events, synthesised, scroll nothing), so the room is asked for
//  where every way of scrolling finds it: in the document, the text view's own
//  frame reaching half the view below the last line (`TextPlacement`).
//
//  The third: the editor was framed to the text column, 32pt short of the
//  pane by default, so its scroller sat 32pt in from the window's edge.
//
//  `AppearanceSettings()` reads the person's own preferences and writes them
//  on every set, so nothing here sets a width: what the column should be is
//  worked out from the settings as they are.
//

import Foundation
import SwiftUI
import Testing
import MarkdownEditor
import WebKit
@testable import HelloNotes
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@Suite(.serialized) @MainActor
struct EditorScrollingTests {

    /// Several screens of one-line paragraphs, ending in a line of text.
    static let paragraphs = (1...120).map { "Paragraph \($0) of a note long enough to scroll several screens." }
    static let note = "# Scrolling\n\n" + paragraphs.joined(separator: "\n\n")
    static let lastLine = paragraphs[paragraphs.count - 1]

    /// Turn the main run loop for `seconds`, in small steps, and let the main
    /// actor's tasks run between them — a test that only turns the run loop
    /// never runs those (AGENTS.md).
    private func pump(_ seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            turnRunLoop(for: 0.004)
            try? await Task.sleep(for: .milliseconds(1))
        } while Date() < deadline
    }

    private func turnRunLoop(for seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// `text` on disk, open in an editor.
    private func openNote(_ text: String) async throws -> (EditorModel, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorScrolling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Scrolling.md")
        try Data(text.utf8).write(to: url)
        let editor = EditorModel()
        await editor.open(Note(title: "Scrolling", fileURL: url, lastModified: Date(), fileSize: text.utf8.count))
        return (editor, dir)
    }

    private func editorView(_ editor: EditorModel) -> some View {
        NoteEditorView(editor: editor, embedProvider: CollectionEmbedProvider(), git: GitService())
    }

    #if canImport(AppKit)

    /// Scrolled to the end by the wheel, a step at a time, the note's last line
    /// comes up to about the middle of the window.
    @Test(.scratchDefaults) func theNoteScrollsPastItsEndToTheMiddle() async throws {
        let (editor, dir) = try await openNote(Self.note)
        defer { try? FileManager.default.removeItem(at: dir) }
        let window = host(editorView(editor))
        defer { close(window) }
        let textView = try await liveTextView(in: window)
        try await expectScrollsPastTheEnd(textView)
    }

    /// The way a note is usually opened: in an editor already showing another
    /// — a click in the sidebar — and here a short one, which needed no room
    /// past its end. The long note's text grows the same text view afterwards.
    @Test(.scratchDefaults) func aLongNoteOpenedAfterAShortOneScrollsPastItsEnd() async throws {
        let (editor, dir) = try await openNote("# Short\n\nOne line.\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let window = host(editorView(editor))
        defer { close(window) }
        _ = try await liveTextView(in: window, showing: "One line.")
        let long = dir.appendingPathComponent("Long.md")
        try Data(Self.note.utf8).write(to: long)
        await editor.open(Note(title: "Long", fileURL: long, lastModified: Date(), fileSize: Self.note.utf8.count))
        let textView = try await liveTextView(in: window)
        try await expectScrollsPastTheEnd(textView)
    }

    /// Scrolled to the end by the wheel, the last line comes up to about the
    /// middle — and the room that lets it is the document's own.
    private func expectScrollsPastTheEnd(_ textView: NSTextView, lastLine: String = Self.lastLine) async throws {
        let scrollView = try #require(textView.enclosingScrollView)
        let clip = scrollView.contentView

        await scrollToTheEnd(scrollView)
        let viewport = visibleHeight(of: clip)
        let last = try lineRect(containing: lastLine, in: textView, convertedTo: clip)
        let below = clip.bounds.maxY - clip.contentInsets.bottom - last.maxY
        #expect(viewport > 300, "the editor is \(viewport)pt tall — this test is not looking at a window")
        #expect(below >= viewport / 2 - last.height,
                "scrolled to the end, \(below)pt shows below the last line of a \(viewport)pt view — it cannot come up to the middle")
        let inDocument = textView.frame.maxY - textView.convert(last, from: clip).maxY
        #expect(inDocument >= viewport / 2,
                "the text view ends \(inDocument)pt below its last line in a \(viewport)pt view — the room is not in the document, where a trackpad finds it")
    }

    /// A note written from a few lines to several screens — the way a note
    /// gets long — scrolls past its end: the room is worked out as the note
    /// grows, not once when it was short.
    @Test(.scratchDefaults) func aNoteThatGrowsPastTheWindowScrollsPastItsEnd() async throws {
        let (editor, dir) = try await openNote("# Growing\n\nThe first line.")
        defer { try? FileManager.default.removeItem(at: dir) }
        let window = host(editorView(editor))
        defer { close(window) }
        let textView = try await liveTextView(in: window, showing: "The first line.")
        try await takeTheKeyboard(textView)
        for line in 1...50 {
            textView.insertNewline(nil)
            textView.insertNewline(nil)
            textView.insertText("Line \(line) written at the end.", replacementRange: NSRange(location: NSNotFound, length: 0))
            await pump(0.03)
        }
        await pump(0.3)
        try await expectScrollsPastTheEnd(textView, lastLine: "Line 50 written")
    }

    /// Markdown mode scrolls past its end as Edit does — it had no room at all.
    @Test(.scratchDefaults) func theMarkdownPaneScrollsPastItsEndToo() async throws {
        let (editor, dir) = try await openNote(Self.note)
        defer { try? FileManager.default.removeItem(at: dir) }
        let window = host(editorView(editor), mode: .markdown)
        defer { close(window) }
        let textView = try await textView(SourceTextView.self, in: window)
        try await expectScrollsPastTheEnd(textView)
    }

    /// Each mode's view fills the pane — its scroller at the window's edge —
    /// and Edit's and Markdown's text sit in the column the settings give.
    @Test(.scratchDefaults) func everyModeFillsItsPane() async throws {
        let (editor, dir) = try await openNote(Self.note)
        defer { try? FileManager.default.removeItem(at: dir) }
        let appearance = AppearanceSettings()
        let column = TextWidth.column(characterWidth: TextWidth.characterWidth(size: appearance.editorFontSize),
                                      reading: appearance.readingWidth, editing: appearance.editorWidth)
        for mode in [EditorMode.edit, .markdown, .preview] {
            let window = host(editorView(editor), mode: mode)
            defer { close(window) }
            let content = try #require(window.contentView)
            await pump(0.5)
            let scrolling: NSView
            switch mode {
            case .edit, .markdown:
                let shown: NSTextView = mode == .edit
                    ? try await textView(MarkdownTextView.self, in: window)
                    : try await textView(SourceTextView.self, in: window)
                scrolling = try #require(shown.enclosingScrollView)
                let expected = column.resolve(in: shown.bounds.width).leading
                let base = mode == .edit ? EditorMetrics.textContainerInset.width : SourceTextView.inset.width
                #expect(abs(shown.textContainerOrigin.x - (base + expected)) < 0.5,
                        "\(mode): the text starts at \(shown.textContainerOrigin.x), not in its column")
            default:
                scrolling = try #require(find(WKWebView.self, in: content), "no preview")
            }
            let frame = scrolling.convert(scrolling.bounds, to: nil)
            #expect(abs(frame.maxX - content.bounds.maxX) < 0.5,
                    "\(mode): the scrolling view ends at \(frame.maxX), not at the pane's edge (\(content.bounds.maxX))")
        }
    }

    private func takeTheKeyboard(_ textView: MarkdownTextView) async throws {
        let window = try #require(textView.window)
        for _ in 0..<100 where window.firstResponder !== textView {
            window.makeFirstResponder(textView)
            await pump(0.02)
        }
        try #require(window.firstResponder === textView, "the text view never took the keyboard's input")
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        await pump(0.2)
    }

    /// Writing at the end of the note — the caret on the last line, typing,
    /// Return, typing — every line written is wholly on screen: inside the
    /// clip view's visible part *and* inside the text view, which draws
    /// nothing outside its own frame. From a note that starts short, so the
    /// writing crosses the bottom of the window, as a note being written does.
    @Test(.scratchDefaults) func theLineBeingWrittenAtTheEndIsNeverCutOff() async throws {
        let (editor, dir) = try await openNote("# Growing\n\nThe first line.")
        defer { try? FileManager.default.removeItem(at: dir) }
        let window = host(editorView(editor))
        defer { close(window) }
        let textView = try await liveTextView(in: window, showing: "The first line.")
        let scrollView = try #require(textView.enclosingScrollView)
        let clip = scrollView.contentView

        try await takeTheKeyboard(textView)

        for number in 1...40 {
            let line = "Written at the end, line \(number)."
            textView.insertNewline(nil)
            await pump(0.05)
            for word in line.split(separator: " ", omittingEmptySubsequences: false) {
                textView.insertText(String(word) + " ", replacementRange: NSRange(location: NSNotFound, length: 0))
                await pump(0.03)
            }
            await pump(0.1)
            let rect = try lineRect(containing: line, in: textView, convertedTo: clip)
            let visibleTop = clip.bounds.minY + clip.contentInsets.top
            let visibleBottom = clip.bounds.maxY - clip.contentInsets.bottom
            #expect(rect.minY >= visibleTop - 0.5 && rect.maxY <= visibleBottom + 0.5,
                    "“\(line)” sits at \(rect.minY)…\(rect.maxY), outside the visible \(visibleTop)…\(visibleBottom)")
            let inTextView = textView.convert(rect, from: clip)
            #expect(inTextView.maxY <= textView.bounds.maxY + 0.5,
                    "“\(line)” ends at \(inTextView.maxY), below the text view's own frame (\(textView.bounds.maxY)) — drawn cut off")
        }
    }

    // MARK: Hosting

    private func host(_ view: some View, mode: EditorMode = .edit) -> NSWindow {
        let defaults = ScratchDefaults.suite(mode.rawValue)
        defaults.set(mode.rawValue, forKey: EditorMode.storageKey)
        let hosting = NSHostingView(rootView: view
            .environment(IntelligenceSettings())
            .environment(AppearanceSettings())
            .environment(EditorDocumentStore())
            .defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = window.contentView?.bounds ?? .zero
        window.layoutIfNeeded()
        return window
    }

    private func close(_ window: NSWindow) {
        window.makeFirstResponder(nil)
        window.contentView = nil
        window.close()
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let found = view as? T { return found }
        for sub in view.subviews {
            if let found = find(type, in: sub) { return found }
        }
        return nil
    }

    /// Edit mode's text view, once it holds `text` and has settled.
    private func liveTextView(in window: NSWindow, showing text: String = Self.lastLine) async throws -> MarkdownTextView {
        try await textView(MarkdownTextView.self, in: window, showing: text)
    }

    /// The window's text view of `type`, once it holds `text` and has settled.
    private func textView<T: NSTextView>(_ type: T.Type, in window: NSWindow,
                                         showing text: String = Self.lastLine) async throws -> T {
        await pump(0.3)
        for _ in 0..<200 {
            if let content = window.contentView, let found = find(type, in: content),
               found.window != nil, found.string.contains(text) {
                await pump(0.3)
                return found
            }
            await pump(0.02)
        }
        return try #require(nil as T?, "no \(type) showing the note")
    }

    /// The height of the clip view nothing covers.
    private func visibleHeight(of clip: NSClipView) -> CGFloat {
        clip.bounds.height - clip.contentInsets.top - clip.contentInsets.bottom
    }

    /// Down by the wheel until the note will go no further: real scroll-wheel
    /// events, handed to the scroll view as the window would hand them, and
    /// the window laid out between them. Not `clip.scroll(to:)` — that asks the
    /// clip view's limit directly, and a wheel does not necessarily ask it the
    /// same way.
    private func scrollToTheEnd(_ scrollView: NSScrollView) async {
        let clip = scrollView.contentView
        var still = 0
        for _ in 0..<600 {
            let before = clip.bounds.origin.y
            guard let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                      wheel1: -120, wheel2: 0, wheel3: 0),
                  let event = NSEvent(cgEvent: wheel) else { break }
            scrollView.scrollWheel(with: event)
            await pump(0.01)
            if clip.bounds.origin.y <= before + 0.5 { still += 1 } else { still = 0 }
            if still >= 5 { break }
        }
        await pump(0.3)
    }

    /// The rect of the laid-out line holding the last `needle` in the note,
    /// in `view`'s coordinates.
    private func lineRect(containing needle: String,
                          in textView: NSTextView, convertedTo view: NSView) throws -> CGRect {
        let text = textView.string as NSString
        let found = text.range(of: needle, options: .backwards)
        try #require(found.location != NSNotFound, "“\(needle)” is not in the note")
        var line: CGRect?
        if let layoutManager = textView.textLayoutManager, let content = layoutManager.textContentManager {
            let location = try #require(content.location(content.documentRange.location, offsetBy: found.location))
            layoutManager.ensureLayout(for: NSTextRange(location: location))
            layoutManager.enumerateTextSegments(in: NSTextRange(location: location), type: .standard,
                                                options: [.rangeNotRequired]) { _, frame, _, _ in
                line = frame
                return false
            }
        } else if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: found.location, length: 1),
                                                  actualCharacterRange: nil)
            line = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        }
        let segment = try #require(line, "no line laid out for “\(needle)”")
        let origin = textView.textContainerOrigin
        return textView.convert(segment.offsetBy(dx: origin.x, dy: origin.y), to: view)
    }

    #else

    /// Scrolled to the end as a finger does, the note's last line comes up to
    /// about the middle of the screen.
    @Test(.scratchDefaults) func theNoteScrollsPastItsEndToTheMiddle() async throws {
        let (editor, dir) = try await openNote(Self.note)
        defer { try? FileManager.default.removeItem(at: dir) }
        let window = host(editorView(editor))
        defer { close(window) }
        let textView = try await liveTextView(in: window)

        await scrollToTheEnd(textView)
        let viewport = textView.bounds.height - textView.adjustedContentInset.top - textView.adjustedContentInset.bottom
        let last = try lineRect(containing: Self.lastLine, in: textView)
        let visibleBottom = textView.contentOffset.y + textView.bounds.height - textView.adjustedContentInset.bottom
        let below = visibleBottom - last.maxY
        #expect(below >= viewport / 2 - last.height,
                "scrolled to the end, \(below)pt shows below the last line of a \(viewport)pt view — it cannot come up to the middle")
    }

    private func host(_ view: some View) -> UIWindow {
        let defaults = ScratchDefaults.suite("scrolling")
        defaults.set(EditorMode.edit.rawValue, forKey: EditorMode.storageKey)
        let controller = UIHostingController(rootView: AnyView(view
            .environment(IntelligenceSettings())
            .environment(AppearanceSettings())
            .environment(EditorDocumentStore())
            .defaultAppStorage(defaults)))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 1000)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    private func close(_ window: UIWindow) {
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
    }

    private func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let found = view as? T { return found }
        for sub in view.subviews {
            if let found = find(type, in: sub) { return found }
        }
        return nil
    }

    private func liveTextView(in window: UIWindow) async throws -> MarkdownUITextView {
        await pump(0.3)
        for _ in 0..<200 {
            if let found = find(MarkdownUITextView.self, in: window), found.window != nil,
               (found.text ?? "").contains(Self.lastLine) {
                await pump(0.3)
                return found
            }
            await pump(0.02)
        }
        return try #require(nil as MarkdownUITextView?, "no editor showing the note")
    }

    /// Down a finger's swipe at a time, each within the limit a scroll view
    /// gives a pan — its content size and insets as they stand — and laid out
    /// between steps.
    private func scrollToTheEnd(_ textView: MarkdownUITextView) async {
        for _ in 0..<400 {
            let before = textView.contentOffset.y
            let furthest = textView.contentSize.height + textView.adjustedContentInset.bottom - textView.bounds.height
            textView.setContentOffset(CGPoint(x: 0, y: min(before + 240, max(before, furthest))), animated: false)
            textView.layoutIfNeeded()
            await pump(0.02)
            if textView.contentOffset.y <= before + 0.5 { break }
        }
        await pump(0.2)
    }

    private func lineRect(containing needle: String, in textView: MarkdownUITextView) throws -> CGRect {
        let text = (textView.text ?? "") as NSString
        let found = text.range(of: needle, options: .backwards)
        try #require(found.location != NSNotFound, "“\(needle)” is not in the note")
        let start = try #require(textView.position(from: textView.beginningOfDocument, offset: found.location))
        let end = try #require(textView.position(from: start, offset: found.length))
        let range = try #require(textView.textRange(from: start, to: end))
        return textView.firstRect(for: range)
    }

    #endif
}
