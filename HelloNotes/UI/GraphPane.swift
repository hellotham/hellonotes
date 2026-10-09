//
//  GraphPane.swift
//  HelloNotes
//
//  One note's links in and out — one view, both platforms, in the right panel.
//
//  It began as `GraphWindowView` inside `AuxiliaryWindows.swift`, gated to
//  macOS, while the iPad drew its own `graphSheet` from the same builder with
//  every parameter left at its default — so the two disagreed about the scope,
//  the depth and whether a capped graph said it was capped. One pane fixed
//  that, with its controls drawn by the app rather than a platform toolbar.
//
//  It was also, until 1.3.3, the *whole collection's* graph, with a picker that
//  could narrow it to the notes around a node clicked in it. The panel it sits
//  in is about the open note, so that is what the graph is about now: the note
//  at the centre, what links to it and what it links to around it, and a
//  distance that reaches a link or two further. The collection's links are the
//  Mind Map's (`CollectionMindMap`), a tab of its own.
//

import SwiftUI

/// One note's links in and out, in the right panel: the open note at the
/// centre, what links to it and what it links to around it, and — with the
/// distance raised — the notes a link or two further on.
///
/// It was the whole collection's link graph with a scope picker that could
/// narrow it to "Around Focused Note", where the focus was a click in the
/// graph rather than the note being edited. The note was the one thing the
/// panel beside it could have been about and was not. The whole collection's
/// links are the Mind Map's now (`CollectionMindMap`), drawn as a mind map
/// and opened as a tab, because they are about the collection.
struct GraphPane: View {
    /// The note the graph is about.
    let noteURL: URL
    /// What opening a node does: a double-click or double-tap, or activating
    /// it with VoiceOver. A single click only focuses the node; the graph is a
    /// panel beside the editor, so it stays up while you trace links.
    ///
    /// Supplied rather than decided here, because where a note opens is the
    /// host's business — `NoteGraphPanel` passes `Library.requestOpen`, so the
    /// shell selects the note as it selects anything asked for that way. The
    /// graph then follows: it is about the open note.
    var onOpen: (URL) -> Void

    @Environment(Library.self) private var library
    @Environment(AppearanceSettings.self) private var appearance

    /// How many links out the graph reaches: 1 is the note's own links in and
    /// out.
    @AppStorage("noteGraphDepth") private var depth = 1
    /// The node a single click highlighted. Starts on the note itself.
    @State private var focusedURL: URL?

    /// Cached graph data, recomputed only when the note, the distance or the
    /// collection's index change (see `graphKey`) rather than in `body`.
    @State private var data: (nodes: [GraphNode], edges: [GraphEdge], dropped: Int) = ([], [], 0)

    /// The collection the note is in — not the focused one, which with two
    /// collections open can be another.
    private var collection: Collection? { library.collection(containing: noteURL) }

    /// What `data` depends on — the note, the distance, and the collection with
    /// its `derivedRevision` — so the graph rebuilds when any of it changes,
    /// and not on every render.
    private var graphKey: String {
        "\(noteURL.path)|\(depth)|\(collection?.id ?? "")|\(collection?.derivedRevision ?? 0)"
    }

    private var noteTitle: String {
        collection?.notes.first { $0.fileURL == noteURL }?.title
            ?? noteURL.deletingPathExtension().lastPathComponent
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            if data.nodes.count < 2 {
                ChromeEmptyState("No Links", systemImage: "point.3.connected.trianglepath.dotted",
                                 description: Text("Nothing links to “\(noteTitle)”, and it links to no other note."))
            } else {
                GraphView(nodes: data.nodes, edges: data.edges,
                          onSelect: onOpen,
                          accent: appearance.resolvedAccent,
                          focusedURL: focusedURL ?? noteURL,
                          onFocusChange: { focusedURL = $0 })
            }
        }
        .task(id: graphKey) {
            data = GraphData.build(around: noteURL, in: collection, depth: depth)
        }
        .onChange(of: noteURL) { _, _ in focusedURL = nil }
    }

    // MARK: - Controls

    /// How far the graph reaches, and — when the cap has dropped notes — that
    /// it has. The panel can be 220pt wide, so the line under the picker wraps
    /// rather than pushing it off the edge.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Links in and out")
                    .font(Chrome.Typeface.status)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                    .lineLimit(1)
                Spacer(minLength: 4)
                ChromePopUp("Link distance", selection: $depth,
                            options: (1...3).map { d in
                                ChromeOption(value: d, title: d == 1 ? "Direct links" : "Within \(d) links")
                            })
                    .labelsHidden()
                    .help("Show only the notes linked to and from this one, or reach a link or two further")
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
}
