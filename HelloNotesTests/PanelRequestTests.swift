//
//  PanelRequestTests.swift
//  HelloNotesTests
//
//  Note ▸ Summarise Note, Suggest Tags and Suggest Links run whatever the
//  panel was showing (secondary.md §9, item 1; implemented.md §51.36).
//
//  The command sets the panel's view, shows the panel and sets the request in
//  one update, and the panel ran a request only when it *changed*. A closed
//  panel is not in the window, and the panel's other views (the Graph, and in
//  §51.36 Ask Library, the Assistant and a mind map too) are not this view —
//  so the view was made already holding the request, and nothing ran. It runs a request it appears holding now; and
//  the host clears one once it has run, or every note view that appeared
//  again would run the last one again.
//

import Observation
import SwiftUI
import Testing
@testable import HelloNotes
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@Suite @MainActor
struct PanelRequestTests {

    @Observable final class Host {
        var request: InspectorRequest?
        var shown = true
        var summaries = 0
    }

    struct Panel: View {
        let host: Host
        let editor: EditorModel
        let git = GitService()

        var body: some View {
            if host.shown {
                NoteInspector(editor: editor, onSelectHeading: { _, _ in },
                              summarize: { _ in host.summaries += 1; return "A summary." },
                              allTags: [], selectedTag: .constant(nil),
                              backlinks: [], outgoingLinks: [], unlinkedMentions: [],
                              onOpenNote: { _ in }, onLinkMention: { _ in },
                              onPropertiesChanged: { _, _ in },
                              fileURL: editor.note?.fileURL, git: git,
                              onRestoreRevision: { _ in }, tab: .outline,
                              request: host.request,
                              onRequestHandled: { handled in
                                  if host.request == handled { host.request = nil }
                              })
            }
        }
    }

    /// The panel in a window of its own, and how to take it down again.
    #if canImport(AppKit)
    private func show(_ view: some View) -> () -> Void {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        return { window.contentView = nil; window.close() }
    }
    #else
    private func show(_ view: some View) -> () -> Void {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return { window.isHidden = true; window.rootViewController = nil }
    }
    #endif

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test(.scratchDefaults) func aPanelThatAppearsHoldingARequestRunsIt() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelRequest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Note.md")
        try FileIO.write("# Note\n\nSomething to summarise.\n", to: url)
        let editor = EditorModel()
        await editor.open(Note(title: "Note", fileURL: url, lastModified: Date(), fileSize: 30))

        // The command, with the panel closed: the view is made holding it.
        let host = Host()
        host.request = InspectorRequest(kind: .summarize, token: 1)
        let close = show(Panel(host: host, editor: editor)
            .environment(IntelligenceSettings())
            .environment(AppearanceSettings())
            .environment(EditorDocumentStore())
            .defaultAppStorage(ScratchDefaults.suite("panel-request")))
        defer { close() }

        try await until { host.summaries > 0 && host.request == nil }
        #expect(host.summaries == 1, "a panel made holding the request did not run it")
        #expect(host.request == nil, "the request was not cleared once it had run")

        // The panel closed and opened again does not run it again.
        host.shown = false
        try await Task.sleep(for: .milliseconds(100))
        host.shown = true
        try await Task.sleep(for: .milliseconds(300))
        #expect(host.summaries == 1, "a panel appearing again ran the last request again")
    }
}
