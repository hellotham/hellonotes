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

/// The focused collection's link graph, in its own window. A toolbar scope
/// switches between the whole collection and the neighbourhood of the focused
/// note (the click-to-focus selection), with a configurable link distance.
struct GraphWindowView: View {
    @Environment(Library.self) private var library
    @Environment(AppearanceSettings.self) private var appearance

    /// What the graph shows: every note, or just the notes within `depth`
    /// links of the focused one.
    private enum Scope: Hashable {
        case collection
        case aroundFocus
    }

    @State private var scope: Scope = .collection
    @State private var focusedURL: URL?
    @State private var depth = 2

    /// Cached graph data, recomputed only when scope/focus/depth/index change
    /// (see `graphKey`) rather than in the window body — the degree sort is
    /// O(N log N) over the whole collection.
    @State private var data: (nodes: [GraphNode], edges: [GraphEdge], dropped: Int) = ([], [], 0)

    /// A force-directed layout of every note is O(N²); past this many nodes the
    /// whole-collection view keeps only the most-connected notes (and says so),
    /// so the graph stays legible and fast instead of an unreadable hairball.
    private static let maxNodes = 250

    private var graphKey: String {
        "\(scope)|\(focusedURL?.path ?? "")|\(depth)|\(library.focused?.id ?? "")|\(library.focused?.derivedRevision ?? 0)"
    }

    /// Nodes and resolved edges for the current scope, plus how many notes were
    /// dropped by the `maxNodes` cap (0 when nothing was dropped).
    private func computeGraphData() -> (nodes: [GraphNode], edges: [GraphEdge], dropped: Int) {
        guard let c = library.focused else { return ([], [], 0) }

        var notes = c.notes
        if scope == .aroundFocus, let focusedURL {
            let keep = neighbourhood(of: focusedURL, in: c, depth: depth)
            notes = notes.filter { keep.contains($0.fileURL) }
        }

        var dropped = 0
        if notes.count > Self.maxNodes {
            // Rank by degree (outgoing + backlinks) and keep the top slice.
            let degree: (URL) -> Int = { url in
                (c.linkGraph.outgoingByURL[url]?.count ?? 0) + (c.linkGraph.backlinksByURL[url]?.count ?? 0)
            }
            dropped = notes.count - Self.maxNodes
            notes = Array(notes.sorted { degree($0.fileURL) > degree($1.fileURL) }.prefix(Self.maxNodes))
        }

        let indexByURL = Dictionary(uniqueKeysWithValues: notes.enumerated().map { ($1.fileURL, $0) })
        var edges: [GraphEdge] = []
        for (i, note) in notes.enumerated() {
            for target in c.linkGraph.outgoingByURL[note.fileURL] ?? [] {
                if let destURL = c.linkGraph.resolve(target), let j = indexByURL[destURL], j != i {
                    edges.append(GraphEdge(from: i, to: j))
                }
            }
        }
        return (notes.map { GraphNode(url: $0.fileURL, label: $0.title) }, edges, dropped)
    }

    /// Every note within `depth` links of `url`, following links both ways.
    private func neighbourhood(of url: URL, in collection: Collection, depth: Int) -> Set<URL> {
        var visited: Set<URL> = [url]
        var frontier = [url]
        for _ in 0..<depth {
            var next: [URL] = []
            for u in frontier {
                var adjacent: [URL] = []
                for target in collection.linkGraph.outgoingByURL[u] ?? [] {
                    if let dest = collection.linkGraph.resolve(target) { adjacent.append(dest) }
                }
                adjacent += collection.linkGraph.backlinksByURL[u] ?? []
                for v in adjacent where !visited.contains(v) {
                    visited.insert(v)
                    next.append(v)
                }
            }
            frontier = next
        }
        return visited
    }

    private var focusedTitle: String? {
        guard let focusedURL else { return nil }
        return library.focused?.notes.first { $0.fileURL == focusedURL }?.title
    }

    var body: some View {
        Group {
            if data.nodes.isEmpty {
                ContentUnavailableView("No Notes to Graph", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("Open a collection with notes to see its link graph."))
            } else {
                GraphView(nodes: data.nodes, edges: data.edges,
                          onSelect: { library.requestOpen($0) },
                          accent: appearance.resolvedAccent,
                          isWindowed: true,
                          focusedURL: focusedURL,
                          onFocusChange: { url in
                              focusedURL = url
                              if url == nil && scope == .aroundFocus { scope = .collection }
                          })
                    .overlay(alignment: .top) {
                        if data.dropped > 0 {
                            Text("Showing the \(Self.maxNodes) most-connected notes · \(data.dropped) more hidden")
                                .font(.caption)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.thinMaterial, in: Capsule())
                                .padding(.top, 8)
                        }
                    }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Scope", selection: $scope) {
                    Text("Whole Collection").tag(Scope.collection)
                    Text(focusedTitle.map { "Around “\($0)”" } ?? "Around Focused Note")
                        .tag(Scope.aroundFocus)
                }
                .pickerStyle(.menu)
                .disabled(focusedURL == nil && scope == .collection)
                .help("Show the whole collection, or just the notes near the focused one")

                if scope == .aroundFocus {
                    Picker("Link distance", selection: $depth) {
                        ForEach(1...3, id: \.self) { d in
                            Text("\(d) link\(d == 1 ? "" : "s")").tag(d)
                        }
                    }
                    .pickerStyle(.menu)
                    .help("How many links away from the focused note to include")
                }
            }
        }
        .navigationTitle(library.focused.map { "Graph — \($0.name)" } ?? "Graph")
        .frame(minWidth: 480, minHeight: 360)
        .task(id: graphKey) { data = computeGraphData() }
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
