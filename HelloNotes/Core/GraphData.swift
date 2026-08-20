//
//  GraphData.swift
//  HelloNotes
//
//  Nodes and edges for the link graph, independent of who draws them.
//
//  This lived as two private methods inside `GraphWindowView`, which is a
//  macOS-only window — so the iPad could not have a graph without a second copy
//  of the ranking, the neighbourhood walk and the node cap. Two copies of a
//  layout rule is how the Preview and the editor ended up disagreeing about
//  Markdown; one shared builder is the fix that was already learned once.
//

import Foundation

/// What the graph should show.
enum GraphScope: Hashable {
    /// Every note in the collection, subject to `GraphData.maxNodes`.
    case collection
    /// Only notes within `depth` links of a focused note.
    case aroundFocus
}

nonisolated enum GraphData {

    /// A force-directed layout of every note is O(N²); past this many nodes the
    /// whole-collection view keeps only the most-connected notes (and says so),
    /// so the graph stays legible and fast instead of an unreadable hairball.
    static let maxNodes = 250

    /// Nodes and resolved edges for `scope`, plus how many notes the cap
    /// dropped (0 when nothing was dropped).
    @MainActor
    static func build(for collection: Collection?,
                      scope: GraphScope = .collection,
                      focusedURL: URL? = nil,
                      depth: Int = 1) -> (nodes: [GraphNode], edges: [GraphEdge], dropped: Int) {
        guard let c = collection else { return ([], [], 0) }

        var notes = c.notes
        if scope == .aroundFocus, let focusedURL {
            let keep = neighbourhood(of: focusedURL, in: c, depth: depth)
            notes = notes.filter { keep.contains($0.fileURL) }
        }

        var dropped = 0
        if notes.count > maxNodes {
            // Rank by degree (outgoing + backlinks) and keep the top slice.
            let degree: (URL) -> Int = { url in
                (c.linkGraph.outgoingByURL[url]?.count ?? 0) + (c.linkGraph.backlinksByURL[url]?.count ?? 0)
            }
            dropped = notes.count - maxNodes
            notes = Array(notes.sorted { degree($0.fileURL) > degree($1.fileURL) }.prefix(maxNodes))
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
    @MainActor
    static func neighbourhood(of url: URL, in collection: Collection, depth: Int) -> Set<URL> {
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
}
