//
//  CollectionMindMap.swift
//  HelloNotes
//
//  The links across a whole collection, arranged as a mind map.
//
//  A mind map is a tree, and a collection's links are not one: a note can be
//  linked from many others, and links run in circles. So the map is a tree
//  *chosen from* the links, and the links the tree leaves out are drawn too,
//  fainter, so that every connection between two notes is on the map:
//
//  * The collection is the centre.
//  * Its most-connected notes head the branches — the most-connected note of
//    each separate group of linked notes, and then any note with a cluster of
//    its own: three links or more besides those to other branch heads. (A
//    first version forbade two heads to be linked at all, and the sample
//    collection, whose Start Here links to Index and Index to the manual's
//    pages, came out as one branch.)
//  * Every other note joins the branch that reaches it in the fewest links,
//    under the note it was reached through.
//  * A link the tree has no line for — between two branches, or across one —
//    is a cross-link.
//
//  Notes with no links in or out have no place on a map of links; the header
//  says how many there are. A force-directed graph of every note was what the
//  collection used to get (the Graph's "Whole Collection" scope), and the
//  Graph is one note's links now.
//
//  Pure, `nonisolated` and `Sendable`: the shell snapshots the link graph on
//  the main actor — `backlinksByURL` holds every link in the collection,
//  already resolved, so nothing is resolved here — and the tree, the
//  cross-links and the layout are worked out off it.
//

import Foundation

nonisolated enum CollectionMindMap {

    /// A note, as the map needs it.
    struct NoteInfo: Sendable, Hashable {
        let url: URL
        let title: String
    }

    /// What the map is built from, taken on the main actor.
    struct Input: Sendable {
        /// The collection's name, at the centre.
        var name: String
        var notes: [NoteInfo]
        /// For each note, the notes that link to it: the link graph's own
        /// `backlinksByURL`, which is every link in the collection resolved.
        var backlinks: [URL: Set<URL>]
    }

    /// The map, and what it leaves out.
    struct Map: Sendable {
        var model: MindMapModel
        /// Notes on the map.
        var shown: Int
        /// Links between the notes on the map — each pair once, whichever way
        /// it runs.
        var links: Int
        /// Linked notes the cap left off.
        var dropped: Int
        /// Notes with no links in or out.
        var unlinked: Int
    }

    /// Notes on one map. The layout separates every pair of chips, which is
    /// O(N²) an iteration; past this the map keeps the most-connected notes
    /// and says how many it left off.
    static let maxNotes = 160
    /// Branches around the centre, at most — more when the collection has more
    /// separate groups of linked notes than this, since each needs one.
    static let maxBranches = 10
    /// How many links of its own — besides those to other branch heads — a
    /// note needs to head a branch beside another in the same group.
    static let minHubLinks = 3

    static func build(_ input: Input) -> Map {
        var titleByURL: [URL: String] = [:]
        for note in input.notes where titleByURL[note.url] == nil { titleByURL[note.url] = note.title }

        // Who is linked to whom, either way, among the collection's own notes.
        var neighbours: [URL: Set<URL>] = [:]
        for (target, sources) in input.backlinks where titleByURL[target] != nil {
            for source in sources where source != target && titleByURL[source] != nil {
                neighbours[target, default: []].insert(source)
                neighbours[source, default: []].insert(target)
            }
        }
        let unlinked = titleByURL.count - neighbours.count

        /// Most-connected first; then by title, so the map is the same map
        /// every time it is drawn.
        func before(_ a: URL, _ b: URL) -> Bool {
            let da = neighbours[a]?.count ?? 0, db = neighbours[b]?.count ?? 0
            if da != db { return da > db }
            let order = (titleByURL[a] ?? "").localizedStandardCompare(titleByURL[b] ?? "")
            if order != .orderedSame { return order == .orderedAscending }
            return a.path < b.path
        }

        var kept = Set(neighbours.keys)
        if kept.count > maxNotes {
            kept = Set(neighbours.keys.sorted(by: before).prefix(maxNotes))
        }
        // Links among the notes kept, best-connected first. A note whose every
        // link went with the cap would sit alone on a map of links: it goes too.
        var adjacent: [URL: [URL]] = [:]
        for note in kept {
            adjacent[note] = (neighbours[note] ?? []).filter(kept.contains).sorted(by: before)
        }
        kept = kept.filter { !(adjacent[$0]?.isEmpty ?? true) }
        let dropped = neighbours.count - kept.count
        let ordered = kept.sorted(by: before)

        // The separate groups of linked notes; each heads at least one branch.
        var group: [URL: Int] = [:]
        var groups: [[URL]] = []
        for start in ordered where group[start] == nil {
            var members = [start]
            group[start] = groups.count
            var index = 0
            while index < members.count {
                for next in adjacent[members[index]] ?? [] where group[next] == nil {
                    group[next] = groups.count
                    members.append(next)
                }
                index += 1
            }
            groups.append(members)
        }

        // Each group's best-connected note heads a branch, and while there is
        // room so does any note with a cluster of its own: enough links to
        // notes that are not heads already.
        var hubs = groups.compactMap { $0.min(by: before) }
        var isHub = Set(hubs)
        for note in ordered where hubs.count < maxBranches && !isHub.contains(note) {
            let own = (adjacent[note] ?? []).filter { !isHub.contains($0) }
            guard own.count >= minHubLinks else { continue }
            hubs.append(note)
            isHub.insert(note)
        }
        hubs.sort(by: before)

        // Every other note joins the branch that reaches it first, a link at a
        // time from every hub at once.
        var parent: [URL: URL] = [:]
        var reached = isHub
        var frontier = hubs
        while !frontier.isEmpty {
            var next: [URL] = []
            for note in frontier {
                for neighbour in adjacent[note] ?? [] where !reached.contains(neighbour) {
                    reached.insert(neighbour)
                    parent[neighbour] = note
                    next.append(neighbour)
                }
            }
            frontier = next
        }

        var children: [URL: [URL]] = [:]
        for note in ordered { if let p = parent[note] { children[p, default: []].append(note) } }

        func id(_ url: URL) -> String { "n:" + url.path }
        func branch(_ url: URL) -> MindMapModel.Branch {
            MindMapModel.Branch(
                id: id(url), title: titleByURL[url] ?? url.deletingPathExtension().lastPathComponent,
                kind: isHub.contains(url) ? .hub(url) : .note(url),
                children: (children[url] ?? []).map(branch))
        }
        let root = MindMapModel.Branch(id: "root", title: input.name, kind: .root, children: hubs.map(branch))

        // Every link the tree has no line for, each pair once.
        var crossLinks: [MindMapModel.Edge] = []
        var seen = Set<[String]>()
        for note in ordered {
            for neighbour in adjacent[note] ?? [] where parent[neighbour] != note && parent[note] != neighbour {
                let pair = [id(note), id(neighbour)].sorted()
                if seen.insert(pair).inserted {
                    crossLinks.append(MindMapModel.Edge(from: pair[0], to: pair[1]))
                }
            }
        }

        // The tree has a line for every note but the hubs; the rest are cross-links.
        let links = (kept.count - hubs.count) + crossLinks.count
        return Map(model: MindMapModel(root: root, crossLinks: crossLinks),
                   shown: kept.count, links: links, dropped: dropped, unlinked: unlinked)
    }
}
