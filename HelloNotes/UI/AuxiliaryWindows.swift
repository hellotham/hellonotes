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

/// The focused collection's link graph, in its own window.
struct GraphWindowView: View {
    @Environment(Library.self) private var library
    @Environment(AppearanceSettings.self) private var appearance

    /// Nodes and resolved edges for the focused collection.
    private var graphData: (nodes: [GraphNode], edges: [GraphEdge]) {
        guard let c = library.focused else { return ([], []) }
        let notes = c.notes
        let indexByURL = Dictionary(uniqueKeysWithValues: notes.enumerated().map { ($1.fileURL, $0) })
        var edges: [GraphEdge] = []
        for (i, note) in notes.enumerated() {
            for target in c.linkGraph.outgoingByURL[note.fileURL] ?? [] {
                if let destURL = c.linkGraph.resolve(target), let j = indexByURL[destURL], j != i {
                    edges.append(GraphEdge(from: i, to: j))
                }
            }
        }
        return (notes.map { GraphNode(url: $0.fileURL, label: $0.title) }, edges)
    }

    var body: some View {
        let data = graphData
        Group {
            if data.nodes.isEmpty {
                ContentUnavailableView("No Notes to Graph", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("Open a collection with notes to see its link graph."))
            } else {
                GraphView(nodes: data.nodes, edges: data.edges,
                          onSelect: { library.requestOpen($0) },
                          accent: appearance.resolvedAccent,
                          isWindowed: true)
            }
        }
        .navigationTitle(library.focused.map { "Graph — \($0.name)" } ?? "Graph")
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

/// A note's link neighbourhood, in its own window.
struct MindMapWindowView: View {
    let rootURL: URL

    @Environment(Library.self) private var library
    @Environment(AppearanceSettings.self) private var appearance

    private var collection: Collection? { library.collection(containing: rootURL) }

    var body: some View {
        Group {
            if let c = collection {
                MindMapView(rootURL: rootURL, notes: c.notes, linkGraph: c.linkGraph,
                            accent: appearance.resolvedAccent) { note in
                    library.requestOpen(note.id)
                }
            } else {
                ContentUnavailableView("Note Unavailable", systemImage: "brain",
                                       description: Text("This note's collection is no longer open."))
            }
        }
        .navigationTitle("Mind Map")
        .frame(minWidth: 480, minHeight: 360)
    }
}

// MARK: - Ask Library

/// Retrieval-augmented Q&A over every open collection, in its own window.
struct LibraryChatWindowView: View {
    @Environment(Library.self) private var library
    @Environment(LLMSettings.self) private var llmSettings

    var body: some View {
        LibraryChatView(intelligence: IntelligenceService(settings: llmSettings),
                        notes: library.allNotes,
                        searches: library.collections.map(\.search)) { note in
            library.requestOpen(note.id)
        }
        .navigationTitle("Ask Library")
    }
}

// MARK: - Assistant

/// The agentic assistant, in its own window. Owns its model, permission
/// broker, and skill store, and re-points them at whichever collection is
/// focused — so it works independently of the main window's lifecycle.
struct AssistantWindowView: View {
    @Environment(Library.self) private var library
    @Environment(LLMSettings.self) private var llmSettings

    @State private var model: AssistantModel?
    @State private var permissions = PermissionBroker()
    @State private var skills = SkillStore()
    @State private var showLLMSettings = false

    var body: some View {
        Group {
            if let model {
                AssistantView(model: model) { showLLMSettings = true }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Assistant")
        .sheet(isPresented: $showLLMSettings) {
            LLMSettingsView(settings: llmSettings)
        }
        .task {
            if model == nil {
                let m = AssistantModel(settings: llmSettings)
                m.registry = ToolRegistry(tools: CollectionTools.all())
                model = m
            }
            syncFocusedServices()
        }
        .onChange(of: library.focusedID) { _, _ in syncFocusedServices() }
        .onChange(of: library.allNotes) { _, _ in
            if let c = library.focused { skills.refresh(from: c.notes) }
        }
    }

    /// Point the assistant's tools and chat store at the focused collection.
    private func syncFocusedServices() {
        guard let model, let c = library.focused else { return }
        model.toolContext = ToolContext(
            collection: c, search: c.search, git: c.git, permissions: permissions,
            settings: llmSettings, skills: skills)
        model.sessionStore = ChatSessionStore(collectionURL: c.rootURL)
        skills.refresh(from: c.notes)
    }
}
#endif
