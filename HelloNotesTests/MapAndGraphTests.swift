//
//  MapAndGraphTests.swift
//  HelloNotesTests
//
//  The Mind Map is the links across a collection, as a tab; the Graph is one
//  note's links in and out, in the panel. They were the other way round — a
//  map of one note's ideas in the panel, called the Mind Map, and the whole
//  collection's graph called the Graph — and the panel held the collection's
//  tools beside the note's views.
//

import Foundation
import Testing
@testable import HelloNotes

// MARK: - The Mind Map

struct CollectionMindMapTests {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/mind-map/\(name).md") }

    /// A collection of `notes`, linked as `links` says — each pair from, to.
    private func input(_ notes: [String], links: [(String, String)]) -> CollectionMindMap.Input {
        var backlinks: [URL: Set<URL>] = [:]
        for (from, to) in links { backlinks[url(to), default: []].insert(url(from)) }
        return CollectionMindMap.Input(name: "Vault",
                                       notes: notes.map { CollectionMindMap.NoteInfo(url: url($0), title: $0) },
                                       backlinks: backlinks)
    }

    private func notes(_ map: CollectionMindMap.Map) -> [MindMapModel.Node] {
        map.model.nodes.filter { $0.url != nil }
    }

    private func isHub(_ node: MindMapModel.Node) -> Bool {
        if case .hub = node.kind { return true }
        return false
    }

    /// Every linked note is on the map once, under the collection; a note with
    /// no links has no place on a map of links, and is counted instead.
    @Test func everyLinkedNoteIsOnTheMapOnce() {
        let map = CollectionMindMap.build(input(["A", "B", "C", "D", "Lonely"],
                                                links: [("A", "B"), ("C", "A"), ("B", "D")]))
        #expect(notes(map).map(\.title).sorted() == ["A", "B", "C", "D"])
        #expect(map.shown == 4 && map.unlinked == 1 && map.dropped == 0)
        #expect(map.model.nodes.first { $0.depth == 0 }?.title == "Vault")
    }

    /// All the connections, not a tree's worth of them: every linked pair is a
    /// line of the tree or a cross-link — once, whichever way the link runs,
    /// and whether it runs both ways.
    @Test func everyLinkIsALineOrACrossLink() {
        let links = [("A", "B"), ("B", "C"), ("C", "A"), ("A", "D"), ("D", "A"), ("B", "D")]
        let map = CollectionMindMap.build(input(["A", "B", "C", "D"], links: links))
        let pairs = Set(links.map { Set([$0.0, $0.1]) })
        #expect(map.links == pairs.count)
        let lines = map.model.edges.filter { $0.from != "root" }
        #expect(lines.count + map.model.crossLinks.count == pairs.count)
        #expect(!map.model.crossLinks.isEmpty, "a cycle drew no cross-link")
    }

    /// Each separate group of linked notes heads a branch of its own, from its
    /// best-connected note, and the rest of the group hangs from it.
    @Test func eachGroupHeadsABranch() {
        let map = CollectionMindMap.build(input(["Hub", "X", "Y", "Z", "P", "Q"],
                                                links: [("Hub", "X"), ("Hub", "Y"), ("Z", "Hub"), ("P", "Q")]))
        let hubs = map.model.nodes.filter(isHub)
        // P and Q tie on links; the title decides, so the map is always the same.
        #expect(Set(hubs.map(\.title)) == ["Hub", "P"])
        #expect(hubs.allSatisfy { $0.depth == 1 })
        let hub = try? #require(hubs.first { $0.title == "Hub" })
        for title in ["X", "Y", "Z"] {
            let node = notes(map).first { $0.title == title }
            #expect(node?.depth == 2 && node?.branch == hub?.branch, "\(title) is not on Hub's branch")
        }
    }

    /// A well-connected note beside the first heads a branch of its own: the
    /// sample collection's Start Here links to Index, and Index to the manual's
    /// pages, which made the whole map one branch while it said "never beside
    /// another hub".
    @Test func aClusterBesideTheFirstHeadsItsOwnBranch() {
        let map = CollectionMindMap.build(input(["A", "B", "C", "D", "E", "F", "G", "H"],
            links: [("A", "B"), ("A", "C"), ("A", "D"), ("A", "E"), ("E", "F"), ("E", "G"), ("E", "H")]))
        let hubs = map.model.nodes.filter(isHub)
        #expect(Set(hubs.map(\.title)) == ["A", "E"], "\(hubs.map(\.title))")
        let e = hubs.first { $0.title == "E" }
        for title in ["F", "G", "H"] {
            #expect(notes(map).first { $0.title == title }?.branch == e?.branch, "\(title) is not on E's branch")
        }
        // The link between the two heads is still on the map.
        #expect(map.links == 7)
    }

    /// Past the cap, the most-connected notes stay, and the rest are counted.
    @Test func theCapKeepsTheMostConnected() {
        let count = CollectionMindMap.maxNotes + 40
        let names = (0..<count).map { String(format: "N%03d", $0) }
        // A ring, and one note linked to all of the first ten as well.
        var links = (0..<count).map { (names[$0], names[($0 + 1) % count]) }
        links += (1...10).map { ("N000", names[$0]) }
        let map = CollectionMindMap.build(input(names, links: links))
        #expect(map.shown <= CollectionMindMap.maxNotes)
        #expect(map.shown + map.dropped == count)
        #expect(notes(map).contains { $0.title == "N000" }, "the best-connected note went with the cap")
    }

    /// The same links draw the same map, branch for branch.
    @Test func theSameLinksDrawTheSameMap() {
        let same = input(["A", "B", "C", "D", "E"], links: [("A", "B"), ("A", "C"), ("D", "E"), ("B", "C")])
        let first = CollectionMindMap.build(same), second = CollectionMindMap.build(same)
        #expect(first.model.nodes == second.model.nodes)
        #expect(first.model.edges == second.model.edges)
        #expect(first.model.crossLinks == second.model.crossLinks)
    }

    /// Every node is placed, inside a world of positive size.
    @Test func everyNodeIsPlaced() {
        let map = CollectionMindMap.build(input(["A", "B", "C"], links: [("A", "B"), ("B", "C")]))
        let layout = map.model.layout()
        #expect(Set(layout.positions.keys) == Set(map.model.nodes.map(\.id)))
        #expect(layout.size.width > 0 && layout.size.height > 0)
    }

    /// A collection with no links draws an empty map, not a crash.
    @Test func noLinksIsAnEmptyMap() {
        let map = CollectionMindMap.build(input(["A", "B"], links: []))
        #expect(map.shown == 0 && map.unlinked == 2 && notes(map).isEmpty)
    }
}

// MARK: - The panel and the tabs

struct SidePanelTests {
    /// The panel is about the open note. The collection's views are tabs, and
    /// a choice stored while they were the panel's falls back to the outline
    /// (`ContentView.panel` reads the stored value leniently).
    @Test func thePanelHoldsTheNotesViewsOnly() {
        #expect(SidePanel.allCases == [.outline, .tags, .references, .properties, .history, .graph])
        for gone in ["mindMap", "assistant", "askLibrary"] {
            #expect(SidePanel(rawValue: gone) == nil, "\(gone) is a view of the panel again")
        }
    }
}

struct ToolTabsTests {
    @Test func openingAToolAddsItsTabOnceAndShowsIt() {
        var tabs = ToolTabs()
        tabs.show(.mindMap)
        tabs.show(.assistant)
        tabs.show(.mindMap)
        #expect(tabs.open == [.mindMap, .assistant])
        #expect(tabs.showing == .mindMap)
    }

    @Test func aNoteChosenPutsTheToolsBehindIt() {
        var tabs = ToolTabs()
        tabs.show(.askLibrary)
        tabs.showNotes()
        #expect(tabs.showing == nil)
        #expect(tabs.open == [.askLibrary], "choosing a note closed the tool's tab")
    }

    @Test func closingTheToolInFrontShowsTheNotes() {
        var tabs = ToolTabs()
        tabs.show(.mindMap)
        tabs.show(.assistant)
        tabs.close(.mindMap)
        #expect(tabs.showing == .assistant, "closing a tab behind the front one moved the front")
        tabs.close(.assistant)
        #expect(tabs.showing == nil && tabs.open.isEmpty)
    }
}

// MARK: - The Graph

@Suite @MainActor
struct NoteGraphTests {

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// One note's links in and out: what it links to and what links to it,
    /// one link deep — and a link further with the distance raised.
    @Test func theGraphIsTheNotesLinksInAndOut() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteGraph-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = [
            "Centre": "Links out to [[Out]].\n",
            "Out": "Links on to [[Far]].\n",
            "In": "Links to [[Centre]].\n",
            "Far": "The end of the line.\n",
            "Elsewhere": "Linked to nothing.\n",
        ]
        for (title, body) in notes {
            try FileIO.write("# \(title)\n\n\(body)", to: root.appendingPathComponent("\(title).md"))
        }
        let collection = Collection(rootURL: root)
        collection.scan()
        let before = collection.derivedRevision
        collection.refreshDerived()
        try await until { collection.derivedRevision != before }
        let centre = try #require(collection.note(titled: "Centre")).fileURL

        let direct = GraphData.build(around: centre, in: collection, depth: 1)
        #expect(Set(direct.nodes.map(\.label)) == ["Centre", "Out", "In"])
        #expect(direct.edges.count == 2)

        let further = GraphData.build(around: centre, in: collection, depth: 2)
        #expect(Set(further.nodes.map(\.label)) == ["Centre", "Out", "In", "Far"])
    }
}
