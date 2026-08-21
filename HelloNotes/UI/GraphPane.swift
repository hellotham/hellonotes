//
//  GraphPane.swift
//  HelloNotes
//
//  The link graph — one view, both platforms.
//
//  It was `GraphWindowView` inside `AuxiliaryWindows.swift`, gated to macOS, and
//  the iPad drew its own `graphSheet`: `GraphData.build(for:)` with every
//  parameter left at its default. The *builder* was shared, and a comment on
//  each side said so — "the same builder the Mac's graph window uses, so the two
//  cannot disagree about what is connected" — which was true and beside the
//  point. What the two disagreed about was everything around it:
//
//  * **Scope.** The Mac can show the whole collection or just the notes within
//    *n* links of a focused one. iPad had only the whole collection.
//  * **Depth.** One to three links. iPad had no control and took the default.
//  * **The cap.** A force-directed layout of every note is O(N²), so past
//    `GraphData.maxNodes` the whole-collection view keeps the most-connected
//    notes — and the Mac says so in an overlay. iPad silently showed a subset
//    of a large collection's graph with nothing to indicate it.
//
//  The controls live in a toolbar on the Mac and have to go somewhere on iPad;
//  that is the one thing the two shells still supply for themselves.
//

import SwiftUI

/// The focused collection's link graph, in its own window. A toolbar scope
/// switches between the whole collection and the neighbourhood of the focused
/// note (the click-to-focus selection), with a configurable link distance.
struct GraphPane: View {
    /// What tapping a node does. The Mac routes it through
    /// `Library.requestOpen` (the graph is a separate window and has to ask the
    /// main one); a sheet can simply select. Supplied rather than assumed, so
    /// neither shell has to be the other.
    var onOpen: (URL) -> Void

    @Environment(Library.self) private var library
    @Environment(AppearanceSettings.self) private var appearance

    /// What the graph shows: every note, or just the notes within `depth`
    /// links of the focused one.

    @State private var scope: GraphScope = .collection
    @State private var focusedURL: URL?
    @State private var depth = 2

    /// Cached graph data, recomputed only when scope/focus/depth/index change
    /// (see `graphKey`) rather than in the window body — the degree sort is
    /// O(N log N) over the whole collection.
    @State private var data: (nodes: [GraphNode], edges: [GraphEdge], dropped: Int) = ([], [], 0)

    /// A force-directed layout of every note is O(N²); past this many nodes the
    /// whole-collection view keeps only the most-connected notes (and says so),
    /// so the graph stays legible and fast instead of an unreadable hairball.

    private var graphKey: String {
        "\(scope)|\(focusedURL?.path ?? "")|\(depth)|\(library.focused?.id ?? "")|\(library.focused?.derivedRevision ?? 0)"
    }

    /// Nodes and edges for the current scope. The rules live in `GraphData`
    /// so the iPad's graph cannot drift from this one.
    private func computeGraphData() -> (nodes: [GraphNode], edges: [GraphEdge], dropped: Int) {
        GraphData.build(for: library.focused, scope: scope, focusedURL: focusedURL, depth: depth)
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
                          onSelect: onOpen,
                          accent: appearance.resolvedAccent,
                          // `isWindowed` is about having room for the graph's
                          // own chrome, which a full-screen sheet has as much
                          // as a window does.
                          isWindowed: true,
                          focusedURL: focusedURL,
                          onFocusChange: { url in
                              focusedURL = url
                              if url == nil && scope == .aroundFocus { scope = .collection }
                          })
                    .overlay(alignment: .top) {
                        if data.dropped > 0 {
                            Text("Showing the \(GraphData.maxNodes) most-connected notes · \(data.dropped) more hidden")
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
                    Text("Whole Collection").tag(GraphScope.collection)
                    Text(focusedTitle.map { "Around “\($0)”" } ?? "Around Focused Note")
                        .tag(GraphScope.aroundFocus)
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
        .task(id: graphKey) { data = computeGraphData() }
    }
}
