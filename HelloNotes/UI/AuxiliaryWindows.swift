//
//  AuxiliaryWindows.swift
//  HelloNotes
//
//  Created by Chris Tham on 13/7/2026.
//
//  Windows for the app's exploration and reference surfaces — Graph, Mind Map,
//  Ask Library, and the Assistant. These were once sheets, but sheets are for
//  focused, self-contained tasks; these are things you keep open *beside* your
//  notes. Each window reads the shared Library from the environment and asks
//  the main window to show a note via `Library.requestOpen`.
//

import SwiftUI

// MARK: - Graph

/// The graph, in a window of its own.
///
/// The graph itself is `GraphPane`, shared with the iPad's sheet — this is the
/// scene around it. It used to be the whole thing, and the iPad drew a lesser
/// graph beside it with no scope, no depth and no word when the node cap
/// dropped notes.
struct GraphWindowView: View {
    @Environment(Library.self) private var library

    var body: some View {
        // A separate window has to ask the main one to open a note; a sheet can
        // just select.
        GraphPane(onOpen: { library.requestOpen($0) })
            // The floor belongs to the *window*, not to the graph: a sheet is
            // given its size and has no use for a minimum. Keeping it here is
            // what lets `GraphPane` carry no platform gate at all.
            .frame(minWidth: 480, minHeight: 360)
    }
}

// MARK: - Mind map

/// Identifies a mind-map window by its root note (distinct from `NoteRef`, so
/// it opens a mind-map scene rather than a note editor).
struct MindMapRef: Hashable, Codable {
    let url: URL
    init(_ url: URL) { self.url = url }
}

/// A mind map in a window of its own.
///
/// The map is `MindMapPane`, shared with the iPad's sheet; this is the scene
/// around it — the window minimum, and reading the note off disk, because a
/// window has no editor to take the text from.
struct MindMapWindowView: View {
    let rootURL: URL

    @Environment(Library.self) private var library
    @Environment(LiveBuffer.self) private var liveBuffer
    @State private var fileText: String?

    /// What is being typed, when the editor is holding this note; what is on
    /// disk otherwise.
    ///
    /// This read the file unconditionally, so the Mac's mind map showed the
    /// note as of the last autosave while the iPad's — a sheet in the same
    /// scene, handed the live buffer — showed what you were typing. Now that
    /// both platforms open a window, the window has to be able to see it.
    private var text: String? { liveBuffer.text(for: rootURL) ?? fileText }

    var body: some View {
        MindMapPane(rootURL: rootURL,
                    text: text,
                    onOpenNote: { library.requestOpen($0) },
                    onShowSection: showSection)
            .frame(minWidth: 480, minHeight: 360)
            .task(id: rootURL) {
                // Only when the editor is not holding it — reading a file we
                // already have in memory is a coordinated read for nothing.
                guard liveBuffer.text(for: rootURL) == nil else { return }
                fileText = await offMain { try? FileIO.readString(at: rootURL) }
            }
    }

    /// Open the root note in the main window and scroll to `heading`.
    private func showSection(_ heading: String?) {
        library.requestOpen(rootURL)
        guard let heading else { return }
        Task { @MainActor in
            // Give the main window a beat to switch notes before searching.
            try? await Task.sleep(for: .milliseconds(400))
            NotificationCenter.default.post(name: .hnEditorFindQuery, object: nil,
                                            userInfo: ["query": heading])
            try? await Task.sleep(for: .milliseconds(1200))
            NotificationCenter.default.post(name: .hnEditorClearHighlights, object: nil)
        }
    }
}

// MARK: - Ask Library

/// Retrieval-augmented Q&A over every open collection, in its own window.
struct LibraryChatWindowView: View {
    /// What opening a result does. A separate window asks the main one; a sheet
    /// can select directly. Defaults to the window's behaviour.
    var onOpenNote: ((Note) -> Void)?

    @Environment(Library.self) private var library
    @Environment(LLMSettings.self) private var llmSettings

    /// Taken once, as the window appears. Held in `@State` rather than read
    /// from the library in `body`, because taking it *is* a mutation — a body
    /// that re-evaluated would find it already gone.
    @State private var seed: String?

    var body: some View {
        LibraryChatView(intelligence: IntelligenceService(settings: llmSettings),
                        notes: library.allNotes,
                        searches: library.collections.map(\.search),
                        onOpenNote: { note in
                            if let onOpenNote { onOpenNote(note) }
                            else { library.requestOpen(note.id) }
                        },
                        initialQuestion: seed)
        .navigationTitle("Ask Library")
        .task { seed = library.takePendingLibraryQuestion() }
    }
}

// MARK: - Assistant

/// The agentic assistant, in its own window. The window is all this adds —
/// everything it owns lives in `AssistantHost`, which iOS presents as a sheet.
struct AssistantWindowView: View {
    var body: some View {
        AssistantHost()
            .navigationTitle("Assistant")
    }
}
