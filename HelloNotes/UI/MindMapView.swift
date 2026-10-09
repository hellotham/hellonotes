//
//  MindMapView.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  The Mind Map: the links across a whole collection, drawn as a radial mind
//  map — the collection at the centre, its most-connected notes heading the
//  branches, every other note on the branch that reaches it first, and the
//  links the tree leaves out drawn as faint cross-links (`CollectionMindMap`
//  chooses the tree). Each branch takes its own palette colour; a branch's
//  head is a solid chip, the notes on it outlined ones. Click a note to open
//  it. The canvas scrolls and zooms.
//
//  Until 1.3.3 this drew *one* note's ideas — its headings as branches and the
//  links inside each section as leaves — and lived in the right panel beside
//  the note, while the collection's links were the Graph's. That put "a map of
//  links" in two places under two names, the wrong way round: the Graph is one
//  note's links in and out now, in the panel, and the map of the collection's
//  links is this, a tab of its own. The note's headings are the Outline's.
//

// **Not macOS-only.** This file was `#if os(macOS)` and used no AppKit and
// no Mac-only API — the gate was the only thing keeping it off iPad.
import SwiftUI

struct MindMapView: View {
    /// The collection whose links are mapped.
    let collection: Collection
    /// Root-chip colour — the app's resolved accent. Given, because
    /// `Color.accentColor` is not the person's choice.
    var accent: Color
    /// Open a note in the editor.
    var onOpenNote: (URL) -> Void

    /// Chip text used to scale by canvas zoom alone, ignoring the text size.
    /// The *same* factor feeds `estimatedChipSize`, so the chips grow with
    /// their labels — scaling only the font would clip every title. It is the
    /// chrome's own factor (`ChromeTextScale`), one table on both platforms,
    /// where `@ScaledMetric` scaled by each platform's.
    private var typeScale: CGFloat { ChromeTextScale.shared.factor }

    @State private var zoom: CGFloat = 1
    @State private var gestureBaseZoom: CGFloat?
    @State private var viewportSize: CGSize = .zero
    @State private var didInitialFit = false
    /// The map and its layout, built once per state of the collection's links
    /// and text size — snapshotted on the main actor, worked out off it.
    @State private var built: Built?

    private struct Built {
        let map: CollectionMindMap.Map
        let layout: MindMapModel.Layout
    }

    /// What the map is built from: the collection, its index's revision (which
    /// moves whenever a note's links do), how many notes it has, and the text
    /// size.
    private struct BuildKey: Equatable {
        let collectionID: Collection.ID
        let revision: Int
        let noteCount: Int
        let scale: CGFloat
    }

    private static let zoomRange: ClosedRange<CGFloat> = 0.25...3

    var body: some View {
        VStack(spacing: 0) {
            header
            ChromeDivider()
            scrollingMap
        }
        .onChange(of: collection.id) { _, _ in didInitialFit = false }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Label("Mind Map", systemImage: "brain")
                    .font(Chrome.Style.headline)
                    .fixedSize()
                Text(collection.name)
                    .font(Chrome.Typeface.body)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                    .lineLimit(1)
                Spacer(minLength: 8)
                ZoomControls(zoom: $zoom, range: Self.zoomRange, fitZoom: fitZoom)
            }
            // What the map shows and what it leaves out, on a line of its own:
            // beside the title, a phone's width cut the counts off mid-word.
            // What it leaves out was a `.help` tooltip — a hover, which an
            // iPad and a phone do not have. With nothing linked, the empty
            // state says so instead.
            if let built, built.map.shown > 0 {
                Text(facts(built.map))
                    .font(Chrome.Typeface.status)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // 16 is the Mac's `.padding()`, said rather than asked for: the
        // default amount is platform-specific.
        .padding(16)
    }

    /// What the map shows, then the notes it does not: those past the cap,
    /// and those with no links at all.
    private func facts(_ map: CollectionMindMap.Map) -> String {
        var parts = ["\(map.shown) note\(map.shown == 1 ? "" : "s") · \(map.links) link\(map.links == 1 ? "" : "s")"]
        if map.dropped > 0 {
            parts.append("\(map.dropped) more linked note\(map.dropped == 1 ? "" : "s") left off — the map keeps the \(CollectionMindMap.maxNotes) most-connected")
        }
        if map.unlinked > 0 {
            parts.append("\(map.unlinked) note\(map.unlinked == 1 ? " has" : "s have") no links, so \(map.unlinked == 1 ? "it is" : "they are") not on the map")
        }
        return parts.joined(separator: ". ") + "."
    }

    // MARK: - Map canvas

    private var scrollingMap: some View {
        Group {
            if let built {
                if built.map.shown == 0 {
                    ChromeEmptyState("No Links Yet", systemImage: "brain",
                                     description: Text("Link notes to each other with [[wiki links]], and the map draws how they connect."))
                } else {
                    map(built.map.model, built.layout)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // On the container, which outlives the switch from the spinner to the
        // map: on either branch, it would build once more when it appeared.
        .task(id: BuildKey(collectionID: collection.id, revision: collection.derivedRevision,
                           noteCount: collection.notes.count, scale: typeScale)) { await build() }
    }

    /// Build the map for the collection and text size on screen. The snapshot
    /// is a copy of two values the collection already holds; the tree, the
    /// cross-links and the O(N²) layout are worked out off the main actor.
    private func build() async {
        let input = CollectionMindMap.Input(
            name: collection.name,
            notes: collection.notes.map { CollectionMindMap.NoteInfo(url: $0.fileURL, title: $0.title) },
            backlinks: collection.linkGraph.backlinksByURL)
        let scale = typeScale
        let result = await offMain { () -> (CollectionMindMap.Map, MindMapModel.Layout) in
            let map = CollectionMindMap.build(input)
            return (map, map.model.layout(textScale: scale))
        }
        guard !Task.isCancelled else { return }
        built = Built(map: result.0, layout: result.1)
        if !didInitialFit, viewportSize.width > 0 {
            didInitialFit = true
            zoom = min(max(fitZoom(), Self.zoomRange.lowerBound), 1.1)
        }
    }

    private func map(_ model: MindMapModel, _ layout: MindMapModel.Layout) -> some View {
        let contentSize = layout.size
        let positions = layout.positions

        return GeometryReader { viewport in
            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    edgeCanvas(model: model, positions: positions)
                    ForEach(model.nodes) { node in
                        if let p = positions[node.id] {
                            nodeChip(node)
                                .position(x: p.x * zoom, y: p.y * zoom)
                        }
                    }
                }
                .frame(width: contentSize.width * zoom, height: contentSize.height * zoom)
                // Centre the map in the viewport while it's smaller.
                .frame(minWidth: viewport.size.width, minHeight: viewport.size.height)
            }
            .background(Chrome.Colour.content)
            .onChange(of: viewport.size, initial: true) { _, size in
                viewportSize = size
                if !didInitialFit, size.width > 0 {
                    didInitialFit = true
                    zoom = min(max(fitZoom(), Self.zoomRange.lowerBound), 1.1)
                }
            }
        }
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let base = gestureBaseZoom ?? zoom
                    gestureBaseZoom = base
                    zoom = min(max(base * value.magnification, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
                }
                .onEnded { _ in gestureBaseZoom = nil }
        )
    }

    /// The tree's lines, in their branches' colours, and the cross-links under
    /// them: thinner, dashed and neutral, so the tree stays readable and every
    /// link is still there.
    private func edgeCanvas(model: MindMapModel, positions: [String: CGPoint]) -> some View {
        let colorOf = Dictionary(uniqueKeysWithValues: model.nodes.map { ($0.id, branchColor($0)) })
        return Canvas { ctx, _ in
            for edge in model.crossLinks {
                guard let a0 = positions[edge.from], let b0 = positions[edge.to] else { continue }
                var path = Path()
                path.move(to: CGPoint(x: a0.x * zoom, y: a0.y * zoom))
                path.addLine(to: CGPoint(x: b0.x * zoom, y: b0.y * zoom))
                ctx.stroke(path, with: .color(Chrome.Colour.tertiaryLabel.opacity(0.55)),
                           style: StrokeStyle(lineWidth: max(0.75, 0.9 * zoom),
                                              dash: [4 * zoom, 4 * zoom]))
            }
            for edge in model.edges {
                guard let a0 = positions[edge.from], let b0 = positions[edge.to] else { continue }
                let a = CGPoint(x: a0.x * zoom, y: a0.y * zoom)
                let b = CGPoint(x: b0.x * zoom, y: b0.y * zoom)
                var path = Path()
                path.move(to: a)
                path.addLine(to: b)
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [(colorOf[edge.from] ?? Chrome.Colour.secondaryLabel).opacity(0.55),
                                      (colorOf[edge.to] ?? Chrome.Colour.secondaryLabel).opacity(0.55)]),
                    startPoint: a, endPoint: b
                )
                ctx.stroke(path, with: shading, lineWidth: max(1, 1.4 * zoom))
            }
        }
    }

    // MARK: - Nodes

    /// The hue a node draws from: its branch's palette colour (the root uses
    /// the app accent).
    private func branchColor(_ node: MindMapModel.Node) -> Color {
        node.depth == 0 ? accent : NodePalette.color(node.branch)
    }

    @ViewBuilder
    private func nodeChip(_ node: MindMapModel.Node) -> some View {
        let color = branchColor(node)
        let isRoot = node.depth == 0
        let fontSize = (isRoot ? 15.0 : node.depth == 1 ? 13.0 : 11.5) * typeScale * zoom

        // `fixedSize` makes the chip hug its text (a plain `maxWidth` frame
        // would *expand* to it); long titles are pre-truncated so chips stay
        // bounded — and match the collision-pass estimates.
        let chip = HStack(spacing: 4 * zoom) {
            if case .note = node.kind {
                Image(systemName: "doc.text")
                    .font(.system(size: fontSize * 0.85))
            }
            Text(MindMapModel.displayTitle(node.title))
                .font(.system(size: fontSize, weight: isRoot ? .semibold : .medium))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, (isRoot ? 13 : 10) * zoom)
        .padding(.vertical, (isRoot ? 8 : 5.5) * zoom)
        .background(chipBackground(node, color: color), in: Capsule())
        .overlay(chipBorder(node, color: color))
        .foregroundStyle(chipForeground(node, color: color))
        .shadow(color: .black.opacity(0.25), radius: 2.5 * zoom, y: 1.5 * zoom)

        if let url = node.url {
            Button { onOpenNote(url) } label: { chip }
                .buttonStyle(ChromePlainStyle())
                .contextMenu { Button("Open Note") { onOpenNote(url) } }
                .help(node.kind == .hub(url)
                      ? "“\(node.title)” — the most-connected note on this branch. Click to open it."
                      : "“\(node.title)” — click to open it")
        } else {
            chip
                .accessibilityAddTraits(.isHeader)
                .help("The collection “\(node.title)”")
        }
    }

    private func chipBackground(_ node: MindMapModel.Node, color: Color) -> Color {
        switch node.kind {
        case .root, .hub: color
        case .note: Color.clear
        }
    }

    @ViewBuilder
    private func chipBorder(_ node: MindMapModel.Node, color: Color) -> some View {
        switch node.kind {
        case .note:
            Capsule().strokeBorder(color, lineWidth: max(1, 1.3 * zoom))
        case .root, .hub:
            Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1)
        }
    }

    private func chipForeground(_ node: MindMapModel.Node, color: Color) -> AnyShapeStyle {
        switch node.kind {
        case .root, .hub: AnyShapeStyle(.white)
        case .note: AnyShapeStyle(color)
        }
    }

    /// The zoom that fits the whole map in the current viewport.
    private func fitZoom() -> CGFloat {
        guard viewportSize.width > 0, viewportSize.height > 0, let size = built?.layout.size else { return 1 }
        return min(viewportSize.width / size.width, viewportSize.height / size.height) * 0.96
    }
}

// MARK: - Model

/// A mind map as nodes on rings: built from a tree (`Branch`), with the
/// cross-links the tree has no line for, and laid out radially. What the tree
/// is — which note heads which branch — is `CollectionMindMap`'s business.
nonisolated struct MindMapModel: Sendable {
    enum Kind: Hashable, Sendable {
        /// The centre: the collection.
        case root
        /// A note heading a branch.
        case hub(URL)
        /// Any other note.
        case note(URL)
    }

    struct Node: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let depth: Int
        let angle: Double
        /// Which depth-1 subtree the node belongs to (colours the branch);
        /// -1 for the root itself.
        let branch: Int
        let kind: Kind

        /// The note the node is, if it is one.
        var url: URL? {
            switch kind {
            case .root: nil
            case .hub(let url), .note(let url): url
            }
        }
    }

    struct Edge: Hashable, Sendable {
        let from: String
        let to: String
    }

    /// A node and what hangs from it, in the order they are drawn round.
    struct Branch: Sendable {
        var id: String
        var title: String
        var kind: Kind
        var children: [Branch] = []
    }

    /// Distance between rings, in world points.
    static let ringStep: CGFloat = 150

    /// The final node placement: positions in world coordinates plus the world
    /// size that contains every chip.
    struct Layout: Sendable {
        let positions: [String: CGPoint]
        let size: CGSize
    }

    private(set) var nodes: [Node] = []
    /// The tree's own lines: each node to the one it hangs from.
    private(set) var edges: [Edge] = []
    /// Lines between nodes the tree does not connect directly.
    private(set) var crossLinks: [Edge] = []

    init(root: Branch, crossLinks: [Edge] = []) {
        // Each leaf gets an even slice of the circle; a node with children sits
        // at the average of theirs. Each depth-1 subtree is one colour branch.
        let leafCount = max(1, Self.countLeaves(root))
        var nextLeaf = 0
        var built: [Node] = []
        var edgeList: [Edge] = []

        @discardableResult
        func walk(_ item: Branch, depth: Int, branch: Int) -> Double {
            let angle: Double
            if item.children.isEmpty {
                angle = (Double(nextLeaf) + 0.5) / Double(leafCount) * 2 * .pi
                nextLeaf += 1
            } else {
                let childAngles = item.children.enumerated().map { index, child -> Double in
                    edgeList.append(Edge(from: item.id, to: child.id))
                    return walk(child, depth: depth + 1, branch: depth == 0 ? index : branch)
                }
                angle = childAngles.reduce(0, +) / Double(childAngles.count)
            }
            built.append(Node(id: item.id, title: item.title, depth: depth,
                              angle: angle, branch: branch, kind: item.kind))
            return angle
        }
        walk(root, depth: 0, branch: -1)

        nodes = built
        edges = edgeList
        self.crossLinks = crossLinks
    }

    private static func countLeaves(_ item: Branch) -> Int {
        item.children.isEmpty ? 1 : item.children.reduce(0) { $0 + countLeaves($1) }
    }

    /// Chip text, truncated at the string level so chips stay bounded and the
    /// collision estimates share the exact character count the view renders.
    nonisolated static func displayTitle(_ title: String) -> String {
        title.count > 32 ? String(title.prefix(31)) + "…" : title
    }

    // MARK: Layout

    /// Lay the nodes out: radial rings by depth first, then a collision pass
    /// that pushes overlapping chips apart (the root stays pinned), and a
    /// final rebase so everything sits inside a positive-coordinate world.
    func layout(textScale: CGFloat = 1) -> Layout {
        var centers: [CGPoint] = nodes.map { node in
            guard node.depth > 0 else { return .zero }
            let r = Self.ringStep * CGFloat(node.depth)
            return CGPoint(x: r * CGFloat(cos(node.angle)),
                           y: r * CGFloat(sin(node.angle)))
        }
        let sizes = nodes.map { Self.estimatedChipSize($0, textScale: textScale) }
        let rootIndex = nodes.firstIndex { $0.depth == 0 }

        LayoutRelaxation.separate(
            centers: &centers, sizes: sizes, padding: 10,
            fixed: rootIndex.map { [$0] } ?? [], iterations: 100
        )
        let size = LayoutRelaxation.rebase(centers: &centers, sizes: sizes, margin: 60)

        var positions: [String: CGPoint] = [:]
        for (node, center) in zip(nodes, centers) { positions[node.id] = center }
        return Layout(positions: positions, size: size)
    }

    /// The approximate footprint of a node's chip (mirrors `nodeChip`'s font
    /// and padding at zoom 1).
    nonisolated static func estimatedChipSize(_ node: Node, textScale: CGFloat = 1) -> CGSize {
        let fontSize: CGFloat = (node.depth == 0 ? 15 : node.depth == 1 ? 13 : 11.5) * textScale
        let hPad: CGFloat = node.depth == 0 ? 13 : 10
        let vPad: CGFloat = node.depth == 0 ? 8 : 5.5
        var textWidth = LayoutRelaxation.estimatedTextWidth(
            displayTitle(node.title), fontSize: fontSize, maxWidth: .greatestFiniteMagnitude)
        if case .note = node.kind { textWidth += fontSize }   // leading icon
        return CGSize(width: textWidth + hPad * 2, height: fontSize * 1.25 + vPad * 2)
    }
}
