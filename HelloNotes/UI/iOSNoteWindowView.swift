//
//  iOSNoteWindowView.swift
//  HelloNotes
//
//  Created by Chris Tham on 21/8/2026.
//
//  A standalone window for a single note, on iPad — the counterpart of the
//  Mac's `NoteWindowView`, opened by the same `openWindow(value: NoteRef(url))`
//  from the same File ▸ Open in New Window command and the same palette row.
//
//  `AppActions.note.openInNewWindow` is an *optional* closure, and on iOS it was
//  nil: the menu item and the palette row were both built, both drew, and both
//  did nothing when chosen. iPadOS has supported multiple scenes since iOS 13
//  and the app's generated scene manifest already declares
//  `UIApplicationSupportsMultipleScenes` — what was missing was a view to put
//  in the second scene, because the Mac's is `#if os(macOS)` and hosts
//  `NoteEditorView`, which is too.
//
//  Its own `EditorModel`, exactly as the Mac's has: a second window on the same
//  note is a second buffer, and sharing the main window's would make closing a
//  tab tear down a window's document.
//

#if os(iOS)
import SwiftUI
import MarkdownEditor

struct iOSNoteWindowView: View {
    let fileURL: URL

    @Environment(Library.self) private var library
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(LLMSettings.self) private var llmSettings
    @Environment(\.openWindow) private var openWindow

    @State private var editor = EditorModel()
    @State private var didLoad = false
    @AppStorage("iosEditorViewMode") private var storedMode = EditorMode.edit.rawValue

    private var mode: EditorMode { EditorMode(rawValue: storedMode) ?? .edit }

    /// The collection this note belongs to — link resolution and completion are
    /// scoped to it, never to whatever the main window happens to be focused on.
    private var collection: Collection? { library.collection(containing: fileURL) }

    private var note: Note? { collection?.notes.first { $0.fileURL == fileURL } }

    var body: some View {
        NavigationStack {
            Group {
                if let note = editor.note {
                    NoteEditorPane(
                        editor: editor,
                        note: note,
                        collection: collection,
                        appearance: appearance,
                        llmSettings: llmSettings,
                        mode: mode,
                        onOpenWikiLink: openWikiLink,
                        // No `onRename`: renaming rewrites every wiki link in
                        // the collection and moves the file this window is
                        // built around. That belongs where the sidebar can
                        // follow it, not in a window whose only subject would
                        // vanish mid-edit.
                        onRename: nil
                    )
                } else {
                    ContentUnavailableView(
                        "Note Unavailable",
                        systemImage: "doc.text",
                        description: Text("This note could not be opened.")
                    )
                }
            }
            .navigationTitle(note?.title ?? fileURL.deletingPathExtension().lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    iOSEditorModePicker(mode: Binding(
                        get: { mode },
                        set: { storedMode = $0.rawValue }))
                }
            }
        }
        .task {
            guard !didLoad else { return }
            didLoad = true
            if let note { await editor.open(note) }
        }
        // The same registration the Mac's `NoteWindowView` makes. It used to
        // watch `scenePhase` here instead, because `TerminationGuard` was
        // macOS-only — which covered this window and left the main window's
        // tabs with no drain at all.
        .task { TerminationGuard.current?.register(editor) { await editor.flush() } }
        .onDisappear {
            TerminationGuard.current?.unregister(editor)
            Task { await editor.flush() }
        }
    }

    /// Mirror the main window's link handling, but open notes in new windows —
    /// the same rule the Mac's note window follows.
    private func openWikiLink(_ target: String) {
        let webSchemes: Set<String> = ["http", "https", "mailto", "file"]
        if let url = URL(string: target),
           let scheme = url.scheme?.lowercased(),
           webSchemes.contains(scheme) {
            UIApplication.shared.open(url)
            return
        }
        // `[[Note#heading]]` resolves on the note title; the `#heading` fragment
        // points within the note (scroll-to-heading is a main-window affordance).
        let base = target.split(separator: "#", maxSplits: 1,
                                omittingEmptySubsequences: false).first
            .map(String.init) ?? target
        guard let collection else { return }
        // The link graph first, because it resolves aliases and relative paths
        // that a title comparison cannot — the same order `iOSContentView` uses.
        if let url = collection.linkGraph.resolve(base),
           let match = collection.notes.first(where: { $0.fileURL == url }) {
            openWindow(value: NoteRef(match.fileURL))
        } else if let match = collection.notes.first(where: {
            $0.title.localizedCaseInsensitiveCompare(base) == .orderedSame
        }) {
            openWindow(value: NoteRef(match.fileURL))
        }
    }
}
#endif
