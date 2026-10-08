//
//  SourceEndEditingTests.swift
//  HelloNotesTests
//
//  What is typed in the Markdown pane — Markdown and Split mode — is written
//  when editing stops, as Edit mode's is: not per keystroke (typing writes
//  nothing), and not only at the next flush — a switch of note, mode or app, a
//  tab closing, quitting. Clicking into the sidebar or another pane left it
//  unwritten, and a crash before any flush lost it (docs/implemented.md §51.25).
//
//  `NoteEditorView` in a window, as `MainActorBudgetTests` hosts it — the mode
//  in a defaults suite of its own, since the app's preferences are the
//  person's — typed into through its real text view, and left the way a click
//  elsewhere leaves it: the text view gives up first responder.
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
struct SourceEndEditingTests {

    private static let saved = "# Note\n\nAs saved.\n"
    private static let typed = "Typed here."

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
            turnRunLoop(for: 0.004)
            try? await Task.sleep(for: .milliseconds(1))
        } while Date() < deadline
    }

    private func turnRunLoop(for seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// A note on disk, open in an editor.
    private func openNote() async throws -> (EditorModel, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceEndEditing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Note.md")
        try Data(Self.saved.utf8).write(to: url)
        let editor = EditorModel()
        await editor.open(Note(title: "Note", fileURL: url, lastModified: Date(), fileSize: Self.saved.utf8.count))
        return (editor, dir)
    }

    private func onDisk(_ editor: EditorModel) -> String {
        guard let url = editor.note?.fileURL, let data = try? Data(contentsOf: url) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The note's editor as the shell shows it, in `mode`.
    private func editorView(_ editor: EditorModel) -> some View {
        NoteEditorView(editor: editor, embedProvider: CollectionEmbedProvider(), git: GitService())
    }

    // MARK: - Markdown and Split

    /// Typed into the Markdown pane and left: written — and not before it was
    /// left. Written only at the next flush, it was lost to a crash in between.
    @Test(.scratchDefaults) func endingEditingInTheMarkdownPaneWritesTheNote() async throws {
        for mode in [EditorMode.markdown, .split] {
            let (editor, dir) = try await openNote()
            defer { try? FileManager.default.removeItem(at: dir) }
            let window = host(editorView(editor), mode: mode)
            defer { close(window) }
            let textView = try await textView(SourceTextView.self, in: window, showing: "As saved.")

            try await type(Self.typed, into: textView)
            await pump(0.6)
            #expect(editor.text.contains(Self.typed), "what was typed never reached the note's buffer (\(mode))")
            #expect(onDisk(editor) == Self.saved, "typing in the Markdown pane wrote the note (\(mode))")

            endEditing(textView)
            #expect(await eventually { onDisk(editor).contains(Self.typed) },
                    "leaving the Markdown pane did not write what was typed there (\(mode))")
        }
    }

    // MARK: - The controls

    /// Edit mode writes what was typed when editing stops — the save the
    /// Markdown pane did not have.
    @Test(.scratchDefaults) func endingEditingInEditModeWritesTheNote() async throws {
        let (editor, dir) = try await openNote()
        defer { try? FileManager.default.removeItem(at: dir) }
        let window = host(editorView(editor), mode: .edit)
        defer { close(window) }
        let textView = try await textView(LiveTextView.self, in: window, showing: "As saved.")

        try await type(Self.typed, into: textView)
        await pump(0.6)
        #expect(onDisk(editor) == Self.saved, "typing in Edit mode wrote the note")

        endEditing(textView)
        #expect(await eventually { onDisk(editor).contains(Self.typed) },
                "leaving Edit mode's editor did not write what was typed there")
    }

    /// What was typed in the Markdown pane is in the buffer, and a flush — a
    /// switch of note, mode or app — writes it, as it always did.
    @Test(.scratchDefaults) func aFlushWritesWhatWasTypedInTheMarkdownPane() async throws {
        let (editor, dir) = try await openNote()
        defer { try? FileManager.default.removeItem(at: dir) }
        let window = host(editorView(editor), mode: .markdown)
        defer { close(window) }
        let textView = try await textView(SourceTextView.self, in: window, showing: "As saved.")

        try await type(Self.typed, into: textView)
        await pump(0.6)
        #expect(onDisk(editor) == Self.saved, "typing in the Markdown pane wrote the note")

        await editor.flush(lettingGo: false)
        #expect(onDisk(editor).contains(Self.typed), "a flush did not write what was typed in the Markdown pane")
    }

    // MARK: - Hosting

    #if canImport(AppKit)
    private typealias LiveTextView = MarkdownTextView

    /// `view` in a window never ordered front, with the environment the app
    /// gives it and a defaults suite of its own (`.scratchDefaults`).
    private func host(_ view: some View, mode: EditorMode) -> NSWindow {
        let defaults = ScratchDefaults.suite(mode.rawValue)
        defaults.set(mode.rawValue, forKey: EditorMode.storageKey)
        let hosting = NSHostingView(rootView: view
            .environment(IntelligenceSettings())
            .environment(AppearanceSettings())
            .environment(LiveBuffer())
            // Edit mode's host keeps its documents here; without one, SwiftUI
            // stops the process — the test host with it.
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

    /// The window's text view of `type`, once it shows the note — and once
    /// the layout has settled: Split mode picks side by side or stacked from
    /// its size, and the first arrangement can be replaced by the other.
    private func textView<T: NSTextView>(_ type: T.Type, in window: NSWindow, showing text: String) async throws -> T {
        await pump(0.3)
        for _ in 0..<200 {
            if let content = window.contentView, let found = find(type, in: content),
               found.window != nil, found.string.contains(text) {
                return found
            }
            await pump(0.02)
        }
        return try #require(nil as T?, "no \(type) showing the note")
    }

    /// At the end of the note, as a keyboard types — once the view is taking
    /// the keyboard's input, and checked to have landed in it.
    private func type(_ text: String, into view: NSTextView) async throws {
        for _ in 0..<100 where view.window?.firstResponder !== view {
            view.window?.makeFirstResponder(view)
            await pump(0.02)
        }
        try #require(view.window?.firstResponder === view, "the text view never took the keyboard's input")
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(view.string.contains(text), "what was typed did not land in the text view")
    }

    /// What a click in the sidebar or another pane does to it.
    private func endEditing(_ view: NSTextView) {
        view.window?.makeFirstResponder(nil)
    }
    #else
    private typealias LiveTextView = MarkdownUITextView

    /// `view` in a window of its own on the app's scene, with the environment
    /// the app gives it and a defaults suite of its own (`.scratchDefaults`).
    private func host(_ view: some View, mode: EditorMode) -> UIWindow {
        let defaults = ScratchDefaults.suite(mode.rawValue)
        defaults.set(mode.rawValue, forKey: EditorMode.storageKey)
        let controller = UIHostingController(rootView: AnyView(view
            .environment(IntelligenceSettings())
            .environment(AppearanceSettings())
            .environment(LiveBuffer())
            // Edit mode's host keeps its documents here; without one, SwiftUI
            // stops the process — the test host with it.
            .environment(EditorDocumentStore())
            .defaultAppStorage(defaults)))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        // Taller than wide, the shape that found Split changing arrangement
        // under the keyboard: the keyboard coming up makes the pane wider than
        // tall, and Split's source's text view — made again by the change, the
        // one with the keyboard gone with it — never kept first responder. It
        // was widened while that was open; Split keeps its panes now
        // (implemented.md §51.29, `SplitArrangementTests`).
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 1200)
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

    /// The window's text view of `type`, once it shows the note — and once
    /// the layout has settled: Split mode picks side by side or stacked from
    /// its size, and the first arrangement can be replaced by the other.
    private func textView<T: UITextView>(_ type: T.Type, in window: UIWindow, showing text: String) async throws -> T {
        await pump(0.3)
        for _ in 0..<200 {
            if let found = find(type, in: window), found.window != nil, (found.text ?? "").contains(text) {
                return found
            }
            await pump(0.02)
        }
        return try #require(nil as T?, "no \(type) showing the note")
    }

    /// At the end of the note, as a keyboard types — once the view is taking
    /// the keyboard's input, and checked to have landed in it. On iOS the
    /// keyboard of a window just closed can still be going away, and a text
    /// view asked to take first responder then does not.
    private func type(_ text: String, into view: UITextView) async throws {
        for _ in 0..<100 where !view.isFirstResponder {
            _ = view.becomeFirstResponder()
            await pump(0.02)
        }
        try #require(view.isFirstResponder, "the text view never took the keyboard's input")
        view.selectedRange = NSRange(location: ((view.text ?? "") as NSString).length, length: 0)
        view.insertText(text)
        try #require((view.text ?? "").contains(text), "what was typed did not land in the text view")
    }

    /// What a tap elsewhere, or dismissing the keyboard, does to it.
    private func endEditing(_ view: UITextView) {
        _ = view.resignFirstResponder()
    }
    #endif
}
