//
//  GraphData.swift
//  HelloNotes
//
//  Nodes and edges for the link graph, independent of who draws them.
//
//  This lived as two private methods inside `GraphWindowView`, which was a
//  macOS-only window — so the iPad could not have a graph without a second copy
//  of the ranking, the neighbourhood walk and the node cap. Two copies of a
//  layout rule is how the Preview and the editor ended up disagreeing about
//  Markdown; one shared builder is the fix that was already learned once.
//

import Foundation

nonisolated enum GraphData {

    /// A force-directed layout is O(N²); past this many nodes the graph keeps
    /// only the most-connected notes (and says so), so it stays legible and
    /// fast instead of an unreadable hairball. A neighbourhood three links
    /// deep in a well-linked collection can reach it.
    static let maxNodes = 250

    /// The note at `url` and every note within `depth` links of it, in either
    /// direction — what links to it and what it links to — with the links among
    /// them, plus how many notes the cap dropped (0 when nothing was dropped).
    ///
    /// This is the Graph: one note's links in and out. The whole collection's
    /// links are the Mind Map's (`CollectionMindMap`), drawn as a mind map
    /// rather than as a graph. The graph used to offer both, a scope picker
    /// choosing between "Whole Collection" and "Around Focused Note", which is
    /// how the two views came to be confused with each other.
    @MainActor
    static func build(around url: URL, in collection: Collection?,
                      depth: Int = 1) -> (nodes: [GraphNode], edges: [GraphEdge], dropped: Int) {
        guard let c = collection else { return ([], [], 0) }

        let keep = neighbourhood(of: url, in: c, depth: depth)
        var notes = c.notes.filter { keep.contains($0.fileURL) }

        var dropped = 0
        if notes.count > maxNodes {
            // Rank by degree (outgoing + backlinks) and keep the top slice —
            // always with the note itself, which is what the graph is about.
            let degree: (URL) -> Int = { u in
                (c.linkGraph.outgoingByURL[u]?.count ?? 0) + (c.linkGraph.backlinksByURL[u]?.count ?? 0)
            }
            dropped = notes.count - maxNodes
            let ranked = notes.sorted { a, b in
                if (a.fileURL == url) != (b.fileURL == url) { return a.fileURL == url }
                return degree(a.fileURL) > degree(b.fileURL)
            }
            notes = Array(ranked.prefix(maxNodes))
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
