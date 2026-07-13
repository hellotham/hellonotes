//
//  MindMapView.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  A radial mind map of a note's connections, built from the LinkGraph. The
//  root note sits at the centre; each branch (a direct neighbour and its
//  subtree) gets its own colour from the shared palette. The canvas scrolls
//  and zooms. Click a node to re-centre the map on it; use the context menu
//  (or the header button, for the root) to open a note in the editor.
//

#if os(macOS)
import SwiftUI

struct MindMapView: View {
    let notes: [Note]
    let linkGraph: LinkGraph
    var onOpen: (Note) -> Void
    /// Root-chip colour — pass the app's resolved accent (`Color.accentColor`
    /// only reflects the asset-catalog accent, not the app's theming system).
    var accent: Color = .accentColor

    @State private var rootURL: URL
    @State private var zoom: CGFloat = 1
    @State private var gestureBaseZoom: CGFloat?
    @State private var viewportSize: CGSize = .zero
    @Environment(\.dismiss) private var dismiss

    private let maxDepth = 2
    private static let zoomRange: ClosedRange<CGFloat> = 0.4...3

    init(rootURL: URL, notes: [Note], linkGraph: LinkGraph,
         accent: Color = .accentColor, onOpen: @escaping (Note) -> Void) {
        self.notes = notes
        self.linkGraph = linkGraph
        self.onOpen = onOpen
        self.accent = accent
        _rootURL = State(initialValue: rootURL)
    }

    private var model: MindMapModel {
        MindMapModel(rootURL: rootURL, notes: notes, linkGraph: linkGraph, maxDepth: maxDepth)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            scrollingMap
        }
        .frame(minWidth: 560, minHeight: 460)
    }

    private var header: some View {
        HStack {
            Label("Mind Map", systemImage: "brain").font(.headline)
            Spacer()
            ZoomControls(zoom: $zoom, range: Self.zoomRange, fitZoom: fitZoom)
            if let root = notes.first(where: { $0.fileURL == rootURL }) {
                Button {
                    onOpen(root); dismiss()
                } label: { Label("Open “\(root.title)”", systemImage: "arrow.up.forward.square") }
            }
        }
        .padding()
    }

    // MARK: - Map canvas

    private var scrollingMap: some View {
        let model = self.model
        let layout = model.layout()
        let contentSize = layout.size
        let positions = layout.positions

        return GeometryReader { viewport in
            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    edgeCanvas(model: model, positions: positions)
                    ForEach(model.nodes) { node in
                        if let p = positions[node.url] {
                            nodeChip(node)
                                .position(x: p.x * zoom, y: p.y * zoom)
                        }
                    }
                }
                .frame(width: contentSize.width * zoom, height: contentSize.height * zoom)
                // Centre the map in the viewport while it's smaller.
                .frame(minWidth: viewport.size.width, minHeight: viewport.size.height)
            }
            .background(.background)
            .onChange(of: viewport.size, initial: true) { _, size in viewportSize = size }
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

    private func edgeCanvas(model: MindMapModel, positions: [URL: CGPoint]) -> some View {
        let colorOf = Dictionary(uniqueKeysWithValues: model.nodes.map { ($0.url, branchColor($0)) })
        return Canvas { ctx, _ in
            for edge in model.edges {
                guard let a0 = positions[edge.from], let b0 = positions[edge.to] else { continue }
                let a = CGPoint(x: a0.x * zoom, y: a0.y * zoom)
                let b = CGPoint(x: b0.x * zoom, y: b0.y * zoom)
                var path = Path()
                path.move(to: a)
                path.addLine(to: b)
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [(colorOf[edge.from] ?? .secondary).opacity(0.55),
                                      (colorOf[edge.to] ?? .secondary).opacity(0.55)]),
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

    private func nodeChip(_ node: MindMapModel.Node) -> some View {
        let color = branchColor(node)
        let isRoot = node.depth == 0
        let fontSize = (isRoot ? 15.0 : node.depth == 1 ? 13.0 : 11.5) * zoom

        return Button {
            rootURL = node.url   // re-centre on this note
        } label: {
            // `fixedSize` makes the chip hug its text (a plain `maxWidth`
            // frame would *expand* to it); long titles are pre-truncated so
            // chips stay bounded — and match the collision-pass estimates.
            Text(MindMapModel.displayTitle(node.title))
                .font(.system(size: fontSize, weight: isRoot ? .semibold : .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, (isRoot ? 13 : 10) * zoom)
                .padding(.vertical, (isRoot ? 8 : 5.5) * zoom)
                .background(
                    node.depth <= 1 ? color : color.opacity(0.26),
                    in: Capsule()
                )
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .foregroundStyle(node.depth <= 1 ? .white : .primary)
                .shadow(color: .black.opacity(0.25), radius: 2.5 * zoom, y: 1.5 * zoom)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let note = notes.first(where: { $0.fileURL == node.url }) {
                Button("Open Note") { onOpen(note) }
            }
            if node.depth != 0 {
                Button("Center Here") { rootURL = node.url }
            }
        }
        .help(node.depth == 0
              ? "The current root — right-click to open it"
              : "Click to re-centre on “\(node.title)”; right-click to open")
    }

    /// The zoom that fits the whole map in the current viewport.
    private func fitZoom() -> CGFloat {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return 1 }
        let size = model.layout().size
        return min(viewportSize.width / size.width, viewportSize.height / size.height) * 0.96
    }
}

/// Builds the tree of connections from a root and lays it out radially.
struct MindMapModel {
    struct Node: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let title: String
        let depth: Int
        let angle: Double
        /// Which depth-1 subtree the node belongs to (colours the branch);
        /// -1 for the root itself.
        let branch: Int
    }
    struct Edge: Hashable { let from: URL; let to: URL }

    /// Distance between rings, in world points — fixed, so the map's density
    /// doesn't depend on the window size (pan/zoom handles overflow).
    static let ringStep: CGFloat = 150

    /// The final node placement: positions in world coordinates plus the world
    /// size that contains every chip.
    struct Layout {
        let positions: [URL: CGPoint]
        let size: CGSize
    }

    private(set) var nodes: [Node] = []
    private(set) var edges: [Edge] = []
    private var maxUsedDepth = 0

    init(rootURL: URL, notes: [Note], linkGraph: LinkGraph, maxDepth: Int) {
        let titleFor: (URL) -> String = { url in
            notes.first { $0.fileURL == url }?.title ?? url.deletingPathExtension().lastPathComponent
        }

        // A note's connected neighbours: notes it links to, plus notes that link
        // to it (a mind map follows connections in both directions).
        func neighbours(of url: URL) -> [URL] {
            var result: [URL] = []
            var seen = Set<URL>()
            for target in linkGraph.outgoingByURL[url] ?? [] {
                if let dest = linkGraph.resolve(target), dest != url, seen.insert(dest).inserted {
                    result.append(dest)
                }
            }
            for src in linkGraph.backlinksByURL[url] ?? [] where src != url {
                if seen.insert(src).inserted { result.append(src) }
            }
            return result
        }

        // Build the connection tree breadth-first, so a note reachable both
        // directly and transitively is claimed at its shallowest depth.
        struct Tmp { let url: URL; var children: [Tmp] }
        var visited: Set<URL> = [rootURL]
        var childrenOf: [URL: [URL]] = [:]
        var frontier = [rootURL]
        var depth = 0
        while depth < maxDepth && !frontier.isEmpty {
            var next: [URL] = []
            for url in frontier {
                for dest in neighbours(of: url) where !visited.contains(dest) {
                    visited.insert(dest)
                    childrenOf[url, default: []].append(dest)
                    next.append(dest)
                }
            }
            frontier = next
            depth += 1
        }
        func assemble(_ url: URL) -> Tmp {
            Tmp(url: url, children: (childrenOf[url] ?? []).map(assemble))
        }
        let tree = assemble(rootURL)

        // Assign each leaf an even slice of the circle; internal nodes average
        // their children's angles. Each depth-1 subtree is one colour branch.
        let leafCount = max(1, countLeaves(tree))
        var nextLeaf = 0
        var built: [Node] = []
        var edgeList: [Edge] = []
        @discardableResult
        func walk(_ node: Tmp, depth: Int, branch: Int) -> Double {
            let angle: Double
            if node.children.isEmpty {
                angle = (Double(nextLeaf) + 0.5) / Double(leafCount) * 2 * .pi
                nextLeaf += 1
            } else {
                let childAngles = node.children.enumerated().map { index, child in
                    walk(child, depth: depth + 1, branch: depth == 0 ? index : branch)
                }
                angle = childAngles.reduce(0, +) / Double(childAngles.count)
            }
            built.append(Node(url: node.url, title: titleFor(node.url), depth: depth,
                              angle: angle, branch: branch))
            for child in node.children { edgeList.append(Edge(from: node.url, to: child.url)) }
            maxUsedDepth = max(maxUsedDepth, depth)
            return angle
        }
        walk(tree, depth: 0, branch: -1)
        nodes = built
        edges = edgeList

        func countLeaves(_ n: Tmp) -> Int {
            n.children.isEmpty ? 1 : n.children.reduce(0) { $0 + countLeaves($1) }
        }
    }

    /// Lay the nodes out: radial rings by depth first, then a collision pass
    /// that pushes overlapping chips apart (the root stays pinned), and a
    /// final rebase so everything sits inside a positive-coordinate world.
    func layout() -> Layout {
        // Radial placement around the origin.
        var centers: [CGPoint] = nodes.map { node in
            guard node.depth > 0 else { return .zero }
            let r = Self.ringStep * CGFloat(node.depth)
            return CGPoint(x: r * CGFloat(cos(node.angle)),
                           y: r * CGFloat(sin(node.angle)))
        }
        let sizes = nodes.map(Self.estimatedChipSize)
        let rootIndex = nodes.firstIndex { $0.depth == 0 }

        LayoutRelaxation.separate(
            centers: &centers, sizes: sizes, padding: 10,
            fixed: rootIndex.map { [$0] } ?? [], iterations: 100
        )
        let size = LayoutRelaxation.rebase(centers: &centers, sizes: sizes, margin: 60)

        var positions: [URL: CGPoint] = [:]
        for (node, center) in zip(nodes, centers) { positions[node.url] = center }
        return Layout(positions: positions, size: size)
    }

    /// Chip text, truncated at the string level so chips stay bounded and the
    /// collision estimates share the exact character count the view renders.
    static func displayTitle(_ title: String) -> String {
        title.count > 28 ? String(title.prefix(27)) + "…" : title
    }

    /// The approximate footprint of a node's chip (mirrors `nodeChip`'s font
    /// and padding at zoom 1).
    static func estimatedChipSize(_ node: Node) -> CGSize {
        let fontSize: CGFloat = node.depth == 0 ? 15 : node.depth == 1 ? 13 : 11.5
        let hPad: CGFloat = node.depth == 0 ? 13 : 10
        let vPad: CGFloat = node.depth == 0 ? 8 : 5.5
        let textWidth = LayoutRelaxation.estimatedTextWidth(
            displayTitle(node.title), fontSize: fontSize, maxWidth: .greatestFiniteMagnitude)
        return CGSize(width: textWidth + hPad * 2, height: fontSize * 1.25 + vPad * 2)
    }
}
#endif
