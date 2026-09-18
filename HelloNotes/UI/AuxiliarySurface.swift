//
//  AuxiliarySurface.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  Graph, Ask Library, Assistant, Mind Map — the surfaces that sit beside the
//  notes rather than inside them.
//
//  **The app opens no windows of its own.** A window happens when someone asks
//  for one by name — New Window, Open in New Window — and those two commands
//  are on both platforms, as every command here is. Nothing else makes a scene.
//
//  It used to. The Mac opened a `Window` for each of these and the iPad a
//  sheet; that was unified into one rule keyed on width — a canvas wide enough
//  to hold a second surface *beside* the notes got a window. The rule assumed a
//  second scene can sit beside the first, and on iPadOS it cannot: in
//  full-screen apps, and in Split View, the system puts the new scene where the
//  old one was, and closing it left the app entirely (measured on the simulator,
//  17 Sep 2026 — Done in the Assistant showed the Home Screen with the app still
//  running). Nothing in the SDK distinguishes iPad's windowed mode from
//  full-screen: `UIWindowScene.isFullScreen` is Mac Catalyst only, and
//  `sizeRestrictions` is non-nil in both (probed, iPadOS 27).
//
//  A sheet was the first answer, and it was the wrong shape for a different
//  reason: **an editor never blocks editing.** A modal over the note is a note
//  you cannot type in, and these are surfaces you keep open *while* you write.
//  So they are **panes** — the trailing panel, beside the editor, which is a
//  column wherever one fits (`ShellMetrics.hasInspectorColumn`). One rule, one
//  shape, both platforms; only a phone, which has no room for a column, falls
//  back to presenting the pane as a sheet.
//

import SwiftUI

/// A surface that opens beside the notes.
enum AuxiliarySurface: Identifiable, Hashable {
    case graph
    case askLibrary
    case assistant
    /// The mind map of one note.
    case mindMap(URL)

    /// Identity — one surface at a time, and a mind map is per note.
    var id: String {
        switch self {
        case .graph: "graph"
        case .askLibrary: "askLibrary"
        case .assistant: "assistant"
        case .mindMap(let url): "mindMap:" + url.path
        }
    }

    var title: String {
        switch self {
        case .graph: "Graph"
        case .askLibrary: "Ask Library"
        case .assistant: "Assistant"
        case .mindMap: "Mind Map"
        }
    }

    var symbol: String {
        switch self {
        case .graph: "point.3.connected.trianglepath.dotted"
        case .askLibrary: "sparkles.rectangle.stack"
        case .assistant: "sparkles"
        case .mindMap: "point.topleft.down.curvedto.point.bottomright.up"
        }
    }
}

/// Opening an auxiliary surface — one decision, both shells.
///
/// A type rather than a bare closure because every call site says
/// `auxiliary.open(.assistant)`, and that reads as the app's own vocabulary
/// rather than as a presentation detail. What it does is show the surface in
/// the trailing panel.
@MainActor
struct AuxiliaryOpener {
    /// Show this surface in the panel; `nil` closes it.
    let present: (AuxiliarySurface?) -> Void

    func open(_ surface: AuxiliarySurface) { present(surface) }
}

/// The content of an auxiliary surface.
struct AuxiliarySurfaceView: View {
    let surface: AuxiliarySurface

    var body: some View {
        switch surface {
        case .graph: GraphSurface()
        case .askLibrary: LibraryChatSurface()
        case .assistant: AssistantSurface()
        case .mindMap(let url): MindMapSurface(rootURL: url)
        }
    }
}

/// An auxiliary surface in the trailing panel — a **pane**, beside the editor.
///
/// Not a sheet and not a window: *an editor never blocks editing*. A sheet over
/// the note stops you typing in it, which is the objection to the modal these
/// used to be, and a window is a scene the system places where it likes. The
/// panel is a column wherever one fits (`ShellMetrics.hasInspectorColumn`), so
/// the note stays live beside the Assistant, the graph or the mind map. Only a
/// canvas with no room for a column — a phone — presents this as a sheet.
///
/// The title and the way out are drawn here, in a plain row rather than a
/// navigation bar, because this is the only chrome these surfaces have on
/// either platform. The surfaces themselves draw neither: two titles and two
/// Done buttons is what the phone showed while each side supplied its own.
struct AuxiliaryPane: View {
    let surface: AuxiliarySurface
    /// Close the panel. The shell owns that state, so this is not `dismiss`.
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(surface.title, systemImage: surface.symbol).font(.headline)
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal).padding(.vertical, 10)
            Divider()
            AuxiliarySurfaceView(surface: surface)
        }
    }
}

// MARK: - Graph

/// The link graph. `GraphPane` is the graph itself; this supplies what a
/// surface beside the notes needs — asking the shell to open a note.
struct GraphSurface: View {
    @Environment(Library.self) private var library

    var body: some View {
        GraphPane(onOpen: { library.requestOpen($0) })
    }
}

// MARK: - Mind map

/// The mind map of one note.
struct MindMapSurface: View {
    let rootURL: URL

    @Environment(Library.self) private var library
    @Environment(LiveBuffer.self) private var liveBuffer
    @State private var fileText: String?

    /// What is being typed, when the editor is holding this note; what is on
    /// disk otherwise.
    ///
    /// This read the file unconditionally, so the Mac's mind map showed the
    /// note as of the last autosave while the iPad's — handed the live buffer —
    /// showed what you were typing. One surface, one answer: the live text.
    private var text: String? { liveBuffer.text(for: rootURL) ?? fileText }

    var body: some View {
        MindMapPane(rootURL: rootURL,
                    text: text,
                    onOpenNote: { library.requestOpen($0) },
                    onShowSection: showSection)
            .task(id: rootURL) {
                // Only when the editor is not holding it — reading a file we
                // already have in memory is a coordinated read for nothing.
                guard liveBuffer.text(for: rootURL) == nil else { return }
                fileText = await offMain { try? FileIO.readString(at: rootURL) }
            }
    }

    /// Open the root note and scroll to `heading`.
    private func showSection(_ heading: String?) {
        library.requestOpen(rootURL)
        guard let heading else { return }
        Task { @MainActor in
            // Give the shell a beat to switch notes before searching.
            try? await Task.sleep(for: .milliseconds(400))
            NotificationCenter.default.post(name: .hnEditorFindQuery, object: nil,
                                            userInfo: ["query": heading])
            try? await Task.sleep(for: .milliseconds(1200))
            NotificationCenter.default.post(name: .hnEditorClearHighlights, object: nil)
        }
    }
}

// MARK: - Ask Library

/// Retrieval-augmented Q&A over every open collection.
struct LibraryChatSurface: View {
    /// What opening a result does; by default, ask the shell to show it.
    var onOpenNote: ((Note) -> Void)?

    @Environment(Library.self) private var library
    @Environment(IntelligenceSettings.self) private var intelligenceSettings

    /// Taken once, as the surface appears. Held in `@State` rather than read
    /// from the library in `body`, because taking it *is* a mutation — a body
    /// that re-evaluated would find it already gone.
    @State private var seed: String?

    var body: some View {
        LibraryChatView(intelligence: IntelligenceService(settings: intelligenceSettings),
                        notes: library.allNotes,
                        searches: library.collections.map(\.search),
                        onOpenNote: { note in
                            if let onOpenNote { onOpenNote(note) }
                            else { library.requestOpen(note.id) }
                        },
                        initialQuestion: seed)
        .task { seed = library.takePendingLibraryQuestion() }
    }
}

// MARK: - Assistant

/// The agentic assistant. Everything it owns lives in `AssistantHost`.
struct AssistantSurface: View {
    var body: some View { AssistantHost() }
}
