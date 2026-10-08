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
//    notes — and the Mac said so in an overlay. iPad silently showed a subset
//    of a large collection's graph with nothing to indicate it.
//
//  The scope and the distance were `.toolbar` items — the platform's bar,
//  which the shell no longer has on either platform (`AdaptiveShell` draws its
//  own), so on iPad nothing drew them and the scope could not be changed at
//  all. They are a strip at the top of the pane now, drawn by the app: the
//  same controls in the same place on both.
//

import SwiftUI

/// The focused collection's link graph, in the right panel. A strip at the top
/// of the pane switches between the whole collection and the neighbourhood of
/// the focused note (the click-to-focus selection), with a configurable link
/// distance.
struct GraphPane: View {
    /// What opening a node does: a double-click or double-tap, or activating
    /// it with VoiceOver. A single click only focuses the node; the graph is a
    /// panel beside the editor, so it stays up while you trace links.
    ///
    /// Supplied rather than decided here, because this is the graph itself and
    /// where a note opens is its host's business — `GraphPanel` is what a
    /// panel beside the notes adds. It passes `Library.requestOpen`, as the
    /// mind map and Ask Library do, so the shell selects the note as it
    /// selects anything asked for that way: Open Quickly closed, the tag
    /// filter and the search cleared.
    var onOpen: (URL) -> Void

    @Environment(Library.self) private var library
    @Environment(AppearanceSettings.self) private var appearance

    /// What the graph shows: every note, or just the notes within `depth`
    /// links of the focused one.

    @State private var scope: GraphScope = .collection
    @State private var focusedURL: URL?
    @State private var depth = 2

    /// Cached graph data, recomputed only when scope/focus/depth/index change
    /// (see `graphKey`) rather than in `body` — the degree sort is
    /// O(N log N) over the whole collection.
    @State private var data: (nodes: [GraphNode], edges: [GraphEdge], dropped: Int) = ([], [], 0)

    /// What `data` depends on — the scope, the focus, the distance, and the
    /// focused collection with its `derivedRevision` — so the `.task` in `body`
    /// rebuilds the graph when any of it changes, and not on every render.
    private var graphKey: String {
        "\(scope)|\(focusedURL?.path ?? "")|\(depth)|\(library.focused?.id ?? "")|\(library.focused?.derivedRevision ?? 0)"
    }

    /// Nodes and edges for the current scope. The rules live in `GraphData`,
    /// apart from any view: they moved there so the Mac's window and the
    /// iPad's sheet could not drift apart, and this pane has been their only
    /// caller since both went.
    private func computeGraphData() -> (nodes: [GraphNode], edges: [GraphEdge], dropped: Int) {
        GraphData.build(for: library.focused, scope: scope, focusedURL: focusedURL, depth: depth)
    }


    private var focusedTitle: String? {
        guard let focusedURL else { return nil }
        return library.focused?.notes.first { $0.fileURL == focusedURL }?.title
    }

    var body: some View {
        VStack(spacing: 0) {
            // Above both branches, so a scope that finds nothing can still be
            // changed back.
            controls
            if data.nodes.isEmpty {
                ChromeEmptyState("No Notes to Graph", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("Open a collection with notes to see its link graph."))
            } else {
                GraphView(nodes: data.nodes, edges: data.edges,
                          onSelect: onOpen,
                          accent: appearance.resolvedAccent,
                          focusedURL: focusedURL,
                          onFocusChange: { url in
                              focusedURL = url
                              if url == nil && scope == .aroundFocus { scope = .collection }
                          })
            }
        }
        .task(id: graphKey) { data = computeGraphData() }
    }

    // MARK: - Controls

    /// What the graph shows and how far it reaches, and — when the cap has
    /// dropped notes — that it has. The cap's notice was a capsule floating
    /// over the top of the graph, across its own row of counts and zoom; it is
    /// a line of this strip instead, under the scope it qualifies.
    ///
    /// The panel can be 220pt wide, and a focused note's title can be any
    /// length, so the pop-ups fall back — the title named, then not, then one
    /// above the other. `ViewThatFits` chooses, as the panel's own header does.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { scopePicker(naming: focusedTitle); depthPicker }
                HStack(spacing: 8) { scopePicker(naming: nil); depthPicker }
                VStack(alignment: .leading, spacing: 4) { scopePicker(naming: nil); depthPicker }
            }
            if data.dropped > 0 {
                Text("Showing the \(GraphData.maxNodes) most-connected notes · \(data.dropped) more hidden")
                    .font(Chrome.Style.caption)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Chrome.Metric.barPadding)
        .padding(.vertical, 6)
        .frame(minHeight: 36)
        .background(Chrome.Colour.chrome)
        .overlay(alignment: .bottom) { ChromeDivider() }
    }

    private func scopePicker(naming title: String?) -> some View {
        ChromePopUp("Scope", selection: $scope, options: [
            ChromeOption(value: GraphScope.collection, title: "Whole Collection"),
            ChromeOption(value: GraphScope.aroundFocus,
                         title: title.map { "Around “\($0)”" } ?? "Around Focused Note"),
        ])
        .labelsHidden()
        .disabled(focusedURL == nil && scope == .collection)
        .help("Show the whole collection, or just the notes near the focused one")
    }

    @ViewBuilder
    private var depthPicker: some View {
        if scope == .aroundFocus {
            ChromePopUp("Link distance", selection: $depth,
                        options: (1...3).map { d in
                            ChromeOption(value: d, title: "\(d) link\(d == 1 ? "" : "s")")
                        })
                .labelsHidden()
                .help("How many links away from the focused note to include")
        }
    }
}
