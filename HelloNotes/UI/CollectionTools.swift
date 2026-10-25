//
//  CollectionTools.swift
//  HelloNotes
//
//  What a collection offers beyond its notes — the Mind Map of its links and
//  the Assistant (which Ask Your Library was folded into in 1.3.5) — and how
//  each is shown.
//
//  They are the collection's, so they are chosen from the sidebar, where the
//  collection is, and they open in the middle of the window as tabs beside the
//  notes: a map of a whole collection's links wants the room, and a
//  conversation about notes wants to sit where notes are read. They were views
//  of the right panel, which is about the open note (`SidePanel`), and the
//  panel's strip mixed the note's views with the collection's.
//

import SwiftUI

/// A tool tab: something about the collection, open beside its notes.
enum CollectionTool: String, CaseIterable, Identifiable {
    case mindMap, assistant

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mindMap: "Mind Map"
        case .assistant: "Assistant"
        }
    }

    var systemImage: String {
        switch self {
        case .mindMap: "brain"
        case .assistant: "sparkles"
        }
    }
}

/// The open tool tabs of one window, and which of them is showing.
///
/// A value, held by the shell beside the note tabs (`EditorTabs`), because a
/// tool has no editor, no file and nothing to save: opening one adds its tab
/// once and shows it, showing a note puts the tools behind it, and closing the
/// one showing goes back to the note.
struct ToolTabs: Equatable {
    private(set) var open: [CollectionTool] = []
    /// The tool in front of the notes, or `nil` when a note (or nothing) is.
    private(set) var showing: CollectionTool?

    /// Open `tool` — once — and bring it to the front.
    mutating func show(_ tool: CollectionTool) {
        if !open.contains(tool) { open.append(tool) }
        showing = tool
    }

    /// Put the tools behind the notes: a note was chosen.
    mutating func showNotes() { showing = nil }

    /// Close `tool`'s tab. Closing the one in front shows the notes again.
    mutating func close(_ tool: CollectionTool) {
        open.removeAll { $0 == tool }
        if showing == tool { showing = nil }
    }
}

/// A tool, filling the middle of the window.
struct CollectionToolView: View {
    let tool: CollectionTool
    /// The collection the sidebar has selected — what the Mind Map maps, and
    /// whose conversation the Assistant is.
    let collection: Collection?
    var accent: Color

    @Environment(Library.self) private var library

    var body: some View {
        switch tool {
        case .mindMap:
            if let collection {
                MindMapView(collection: collection, accent: accent,
                            onOpenNote: { library.requestOpen($0) })
            } else {
                ChromeEmptyState("No Collection", systemImage: "brain",
                                 description: Text("Open a collection to map its links."))
            }
        case .assistant:
            AssistantHost(collection: collection)
        }
    }
}
