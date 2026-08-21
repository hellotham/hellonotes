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

#if os(macOS)
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

/// A note's idea map, in its own window.
struct MindMapWindowView: View {
    let rootURL: URL

    @Environment(Library.self) private var library
    @Environment(AppearanceSettings.self) private var appearance

    /// The note's text, loaded off-main once per note — not in `body`, which
    /// would synchronously re-read the file on every render.
    @State private var text: String?

    private var collection: Collection? { library.collection(containing: rootURL) }

    private var rootTitle: String {
        collection?.notes.first { $0.fileURL == rootURL }?.title
            ?? rootURL.deletingPathExtension().lastPathComponent
    }

    var body: some View {
        Group {
            if let c = collection, let text {
                MindMapView(
                    rootTitle: rootTitle,
                    rootURL: rootURL,
                    text: text,
                    resolveLink: { target in
                        guard let url = c.linkGraph.resolve(target),
                              let note = c.notes.first(where: { $0.fileURL == url }) else { return nil }
                        return (url, note.title)
                    },
                    accent: appearance.resolvedAccent,
                    onOpenNote: { library.requestOpen($0) },
                    onShowSection: { heading in showSection(heading) }
                )
            } else if collection != nil {
                ProgressView()   // text still loading
            } else {
                ContentUnavailableView("Note Unavailable", systemImage: "brain",
                                       description: Text("This note's collection is no longer open."))
            }
        }
        .navigationTitle("Mind Map — \(rootTitle)")
        .frame(minWidth: 480, minHeight: 360)
        .task(id: rootURL) {
            let url = rootURL
            text = await offMain { try? FileIO.readString(at: url) }
        }
    }

    /// Open the mapped note in the main window and, when a section was
    /// clicked, scroll the editor to that heading.
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
                        onOpenNote: { note in library.requestOpen(note.id) },
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
#endif
