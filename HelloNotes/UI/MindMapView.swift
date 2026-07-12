//
//  MindMapView.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  A radial mind map of a note's outgoing links, built from the LinkGraph. The
//  root note sits at the centre; the notes it links to fan out around it, and
//  their links form a second ring. Tap a node to re-centre the map on it, or
//  open the current root note in the editor.
//

#if os(macOS)
import SwiftUI

struct MindMapView: View {
    let notes: [Note]
    let linkGraph: LinkGraph
    var onOpen: (Note) -> Void

    @State private var rootURL: URL
    @Environment(\.dismiss) private var dismiss

    private let maxDepth = 2

    init(rootURL: URL, notes: [Note], linkGraph: LinkGraph, onOpen: @escaping (Note) -> Void) {
        self.notes = notes
        self.linkGraph = linkGraph
        self.onOpen = onOpen
        _rootURL = State(initialValue: rootURL)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geo in
                let model = MindMapModel(rootURL: rootURL, notes: notes, linkGraph: linkGraph, maxDepth: maxDepth)
                let positions = model.positions(in: geo.size)
                ZStack {
                    // Edges
                    Canvas { ctx, _ in
                        for edge in model.edges {
                            guard let a = positions[edge.from], let b = positions[edge.to] else { continue }
                            var path = Path()
                            path.move(to: a)
                            path.addLine(to: b)
                            ctx.stroke(path, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
                        }
                    }
                    // Nodes
                    ForEach(model.nodes) { node in
                        if let p = positions[node.url] {
                            nodeChip(node)
                                .position(p)
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .background(.background)
        }
        .frame(width: 760, height: 640)
    }

    private var header: some View {
        HStack {
            Label("Mind Map", systemImage: "brain").font(.headline)
            Spacer()
            if let root = notes.first(where: { $0.fileURL == rootURL }) {
                Button {
                    onOpen(root); dismiss()
                } label: { Label("Open “\(root.title)”", systemImage: "arrow.up.forward.square") }
            }
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    private func nodeChip(_ node: MindMapModel.Node) -> some View {
        Button {
            rootURL = node.url   // re-centre on this note
        } label: {
            Text(node.title)
                .font(node.depth == 0 ? .headline : (node.depth == 1 ? .callout : .caption))
                .lineLimit(1)
                .padding(.horizontal, node.depth == 0 ? 12 : 9)
                .padding(.vertical, node.depth == 0 ? 7 : 5)
                .background(chipColor(node.depth), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.15)))
                .foregroundStyle(node.depth == 0 ? .white : .primary)
        }
        .buttonStyle(.plain)
        .help(node.depth == 0 ? "Root — click Open to edit" : "Click to re-centre on “\(node.title)”")
    }

    private func chipColor(_ depth: Int) -> Color {
        switch depth {
        case 0: return .accentColor
        case 1: return .accentColor.opacity(0.22)
        default: return .secondary.opacity(0.18)
        }
    }
}

/// Builds the tree of outgoing links from a root and lays it out radially.
struct MindMapModel {
    struct Node: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let title: String
        let depth: Int
        let angle: Double
    }
    struct Edge: Hashable { let from: URL; let to: URL }

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
        // their children's angles.
        let leafCount = max(1, countLeaves(tree))
        var nextLeaf = 0
        var built: [Node] = []
        var edgeList: [Edge] = []
        @discardableResult
        func walk(_ node: Tmp, depth: Int) -> Double {
            let angle: Double
            if node.children.isEmpty {
                angle = (Double(nextLeaf) + 0.5) / Double(leafCount) * 2 * .pi
                nextLeaf += 1
            } else {
                let childAngles = node.children.map { walk($0, depth: depth + 1) }
                angle = childAngles.reduce(0, +) / Double(childAngles.count)
            }
            built.append(Node(url: node.url, title: titleFor(node.url), depth: depth, angle: angle))
            for child in node.children { edgeList.append(Edge(from: node.url, to: child.url)) }
            maxUsedDepth = max(maxUsedDepth, depth)
            return angle
        }
        walk(tree, depth: 0)
        nodes = built
        edges = edgeList

        func countLeaves(_ n: Tmp) -> Int {
            n.children.isEmpty ? 1 : n.children.reduce(0) { $0 + countLeaves($1) }
        }
    }

    /// Screen positions for each node given the canvas size.
    func positions(in size: CGSize) -> [URL: CGPoint] {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let step = (min(size.width, size.height) / 2 - 70) / CGFloat(max(1, maxUsedDepth))
        var result: [URL: CGPoint] = [:]
        for node in nodes {
            if node.depth == 0 {
                result[node.url] = center
            } else {
                let r = step * CGFloat(node.depth)
                result[node.url] = CGPoint(
                    x: center.x + r * CGFloat(cos(node.angle)),
                    y: center.y + r * CGFloat(sin(node.angle))
                )
            }
        }
        return result
    }
}
#endif
