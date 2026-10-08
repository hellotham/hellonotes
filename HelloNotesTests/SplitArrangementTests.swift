//
//  SplitArrangementTests.swift
//  HelloNotesTests
//
//  Split mode shows the Markdown source and the page side by side when its pane
//  is at least as wide as it is tall, and one above the other when it is not.
//  Changing arrangement must not make the source's text view again. It did:
//  the two arrangements were two branches of an `if` — on the Mac an
//  `HSplitView` swapped for a `VSplitView` — so crossing square replaced the
//  view holding the caret, and with it the keyboard. On an iPad in portrait
//  that is what the keyboard coming up does: the pane loses the keyboard's
//  height, is wider than tall, the source is made again without the keyboard,
//  the keyboard goes, and the pane is taller again (docs/implemented.md §51.29).
//
//  `NoteEditorView` in a window, as `SourceEndEditingTests` hosts it, the mode
//  in a defaults suite of the test's own. Each test checks that the
//  arrangement really changed — the source's width with it — or a pass would
//  prove nothing.
//

import Foundation
import SwiftUI
import Testing
import MarkdownEditor
@testable import HelloNotes
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@Suite(.serialized) @MainActor
struct SplitArrangementTests {

    private static let saved = "# Note\n\nAs saved.\n"
    /// Wider than tall, and taller than wide — each far enough from square
    /// that the editor's own chrome (the title, the bar) cannot tip it back.
    private static let wide = CGSize(width: 1200, height: 800)
    #if canImport(AppKit)
    private static let tall = CGSize(width: 800, height: 1200)
    #else
    /// Narrow enough to stay taller than wide *with the keyboard up*: the
    /// keyboard, which the source keeps now, takes some 330pt of this window's
    /// height on HN-iPad (340pt at the screen's foot) and did not at first.
    private static let tall = CGSize(width: 600, height: 1200)
    /// Taller than wide until the keyboard comes up, and wider than tall once
    /// it has — the shape that found it.
    private static let tallUntilTheKeyboard = CGSize(width: 800, height: 1200)
    #endif
    // MARK: - Crossing square

    /// A window resized across square changes the arrangement, and the source's
    /// text view is the same view afterwards, still taking the keyboard's input
    /// — both ways.
    @Test(.scratchDefaults) func crossingSquareKeepsTheSourcesTextView() async throws {
        await waitForAKeyboardToGo()
        let (editor, dir) = try await openNote()
        defer { try? FileManager.default.removeItem(at: dir) }
        let window = host(editorView(editor), size: Self.wide)
        defer { close(window) }
        let source = try await sourceTextView(in: window)
        try await takeKeyboard(source)
        // Side by side, the source has about half the window; stacked, all of
        // it. Measured against the window, which is itself resized below.
        #expect(width(of: source) < Self.wide.width * 0.6, "the panes were not side by side to begin with")

        resize(window, to: Self.tall)
        await pump(0.5)
        #expect(find(SourceTextView.self, in: window) === source,
                "stacking the panes made the source's text view again")
        #expect(hasKeyboard(source), "stacking the panes took the keyboard from the source")
        // Measured on whichever source is in the window now: a view made again
        // leaves the old one out of the window, still the old width.
        let stacked = try width(ofSourceIn: window)
        #expect(stacked > Self.tall.width * 0.9,
                "the panes did not stack (the source is \(stacked) of \(Self.tall.width)): this proved nothing")

        resize(window, to: Self.wide)
        await pump(0.5)
        #expect(find(SourceTextView.self, in: window) === source,
                "putting the panes side by side made the source's text view again")
        #expect(hasKeyboard(source), "putting the panes side by side took the keyboard from the source")
        #expect(try width(ofSourceIn: window) < Self.wide.width * 0.6, "the panes did not go side by side again")
    }

    #if canImport(UIKit)
    /// The case it was found in. A pane taller than wide, typed into: the
    /// keyboard comes up, SwiftUI's keyboard avoidance gives the pane that much
    /// less height, and it is wider than tall. The source's text view is the
    /// same one afterwards and still has the keyboard.
    @Test(.scratchDefaults) func theKeyboardComingUpKeepsTheSourcesTextView() async throws {
        await waitForAKeyboardToGo()
        let (editor, dir) = try await openNote()
        defer { try? FileManager.default.removeItem(at: dir) }
        let window = host(editorView(editor), size: Self.tallUntilTheKeyboard)
        defer { close(window) }
        let source = try await sourceTextView(in: window)
        let stacked = width(of: source)
        try #require(stacked > Self.tallUntilTheKeyboard.width * 0.9,
                     "the panes were not stacked before the keyboard came up (\(stacked)) — a keyboard left up?")

        let keyboard = KeyboardWatch()
        defer { keyboard.stop() }
        try await takeKeyboard(source)
        source.insertText(" Typed.")
        #expect(await eventually(timeout: .seconds(5)) { keyboard.didShow },
                "the software keyboard never came up — this test needs it (Simulator ▸ I/O ▸ Keyboard)")
        await pump(1)

        #expect(find(SourceTextView.self, in: window) === source,
                "the keyboard coming up made the source's text view again")
        #expect(source.isFirstResponder, "the keyboard coming up took the keyboard from the source")
        let sideBySide = try width(ofSourceIn: window)
        #expect(sideBySide < stacked * 0.75,
                "the keyboard did not put the panes side by side (\(stacked) → \(sideBySide)): this proved nothing")
    }

    /// Whether the keyboard has shown since this was made.
    private final class KeyboardWatch {
        private(set) var didShow = false
        private var token: NSObjectProtocol?
        init() {
            token = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.didShow = true }
            }
        }
        func stop() { token.map(NotificationCenter.default.removeObserver) }
    }
    #endif

    // MARK: - A note, open

    private func openNote() async throws -> (EditorModel, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SplitArrangement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Note.md")
        try Data(Self.saved.utf8).write(to: url)
        let editor = EditorModel()
        await editor.open(Note(title: "Note", fileURL: url, lastModified: Date(), fileSize: Self.saved.utf8.count))
        return (editor, dir)
    }

    private func editorView(_ editor: EditorModel) -> some View {
        NoteEditorView(editor: editor, embedProvider: CollectionEmbedProvider(), git: GitService())
    }

    /// The test's own (`.scratchDefaults`): emptying one suite after each test
    /// still left its plist in the app's preferences.
    private func defaults() -> UserDefaults {
        let defaults = ScratchDefaults.suite()
        defaults.set(EditorMode.split.rawValue, forKey: EditorMode.storageKey)
        return defaults
    }

    #if canImport(AppKit)
    private typealias PlatformWindow = NSWindow
    #else
    private typealias PlatformWindow = UIWindow
    #endif

    /// The width of the source pane in the window now.
    private func width(ofSourceIn window: PlatformWindow) throws -> CGFloat {
        width(of: try #require(find(SourceTextView.self, in: window), "no source text view in the window"))
    }

    /// Let a keyboard an earlier test left on its way out finish going, so it
    /// is not the keyboard this one measures. Nothing to wait for on the Mac.
    private func waitForAKeyboardToGo() async {
        #if canImport(UIKit)
        await pump(1)
        #endif
    }

    private func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while await !condition() {
            guard ContinuousClock.now < deadline else { return false }
            await pump(0.02)
        }
        return true
    }

    /// Turn the main run loop for `seconds`, in small steps, so the hosted
    /// views lay out and their tasks run.
    private func pump(_ seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
            try? await Task.sleep(for: .milliseconds(1))
        } while Date() < deadline
    }

    // MARK: - Hosting

    #if canImport(AppKit)
    private func host(_ view: some View, size: CGSize) -> NSWindow {
        let hosting = NSHostingView(rootView: view
            .environment(IntelligenceSettings())
            .environment(AppearanceSettings())
            .environment(LiveBuffer())
            .environment(EditorDocumentStore())
            .defaultAppStorage(defaults()))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.layoutIfNeeded()
        return window
    }

    private func resize(_ window: NSWindow, to size: CGSize) {
        window.setContentSize(size)
        window.layoutIfNeeded()
    }

    private func close(_ window: NSWindow) {
        window.makeFirstResponder(nil)
        window.contentView = nil
        window.close()
    }

    private func find<T: NSView>(_ type: T.Type, in window: NSWindow) -> T? {
        func search(_ view: NSView) -> T? {
            if let found = view as? T { return found }
            for sub in view.subviews { if let found = search(sub) { return found } }
            return nil
        }
        return window.contentView.flatMap(search)
    }

    /// The window's source text view once it shows the note, and once the
    /// layout has settled.
    private func sourceTextView(in window: NSWindow) async throws -> SourceTextView {
        await pump(0.3)
        for _ in 0..<200 {
            if let found = find(SourceTextView.self, in: window), found.window != nil,
               found.string.contains("As saved.") { return found }
            await pump(0.02)
        }
        return try #require(nil as SourceTextView?, "no source text view showing the note")
    }

    private func takeKeyboard(_ view: SourceTextView) async throws {
        for _ in 0..<100 where view.window?.firstResponder !== view {
            view.window?.makeFirstResponder(view)
            await pump(0.02)
        }
        try #require(hasKeyboard(view), "the source's text view never took the keyboard's input")
    }

    private func hasKeyboard(_ view: SourceTextView) -> Bool {
        view.window != nil && view.window?.firstResponder === view
    }

    /// The source pane's width in the window: its scroll view's, which is what
    /// the arrangement sizes.
    private func width(of view: SourceTextView) -> CGFloat {
        let pane = view.enclosingScrollView ?? view
        return pane.convert(pane.bounds, to: nil).width
    }
    #else
    private func host(_ view: some View, size: CGSize) -> UIWindow {
        let controller = UIHostingController(rootView: AnyView(view
            .environment(IntelligenceSettings())
            .environment(AppearanceSettings())
            .environment(LiveBuffer())
            .environment(EditorDocumentStore())
            .defaultAppStorage(defaults())))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    private func resize(_ window: UIWindow, to size: CGSize) {
        window.frame = CGRect(origin: .zero, size: size)
        window.layoutIfNeeded()
    }

    private func close(_ window: UIWindow) {
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
    }

    private func find<T: UIView>(_ type: T.Type, in window: UIWindow) -> T? {
        func search(_ view: UIView) -> T? {
            if let found = view as? T { return found }
            for sub in view.subviews { if let found = search(sub) { return found } }
            return nil
        }
        return search(window)
    }

    private func sourceTextView(in window: UIWindow) async throws -> SourceTextView {
        await pump(0.3)
        for _ in 0..<200 {
            if let found = find(SourceTextView.self, in: window), found.window != nil,
               (found.text ?? "").contains("As saved.") { return found }
            await pump(0.02)
        }
        return try #require(nil as SourceTextView?, "no source text view showing the note")
    }

    /// On iOS the keyboard of a window just closed can still be going away, and
    /// a text view asked to take first responder then does not.
    private func takeKeyboard(_ view: SourceTextView) async throws {
        for _ in 0..<100 where !view.isFirstResponder {
            _ = view.becomeFirstResponder()
            await pump(0.02)
        }
        try #require(view.isFirstResponder, "the source's text view never took the keyboard's input")
    }

    private func hasKeyboard(_ view: SourceTextView) -> Bool {
        view.window != nil && view.isFirstResponder
    }

    private func width(of view: SourceTextView) -> CGFloat {
        view.convert(view.bounds, to: nil).width
    }
    #endif
}
