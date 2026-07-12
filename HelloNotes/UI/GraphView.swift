//
//  GraphView.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(macOS)
import SwiftUI

/// A node in the link graph.
struct GraphNode: Identifiable, Hashable {
    let url: URL
    let label: String
    var id: URL { url }
}

/// A directed edge (indices into the node array).
struct GraphEdge: Hashable {
    let from: Int
    let to: Int
}

/// A native force-directed graph of the collection's notes and `[[wiki-links]]`,
/// drawn with `Canvas` (no WebView). Click a node to open that note.
struct GraphView: View {
    let nodes: [GraphNode]
    let edges: [GraphEdge]
    let onSelect: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var positions: [CGPoint] = []
    @State private var layoutSize: CGSize = .zero

    private var degrees: [Int] {
        var d = Array(repeating: 0, count: nodes.count)
        for edge in edges {
            if edge.from < d.count { d[edge.from] += 1 }
            if edge.to < d.count { d[edge.to] += 1 }
        }
        return d
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Graph", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Spacer()
                Text("\(nodes.count) notes · \(edges.count) links")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            graphCanvas
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    private var graphCanvas: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard positions.count == nodes.count else { return }
                // Edges.
                for edge in edges where edge.from < positions.count && edge.to < positions.count {
                    var path = Path()
                    path.move(to: positions[edge.from])
                    path.addLine(to: positions[edge.to])
                    context.stroke(path, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
                }
                // Nodes + labels.
                let deg = degrees
                for (i, point) in positions.enumerated() {
                    let radius = 5 + min(CGFloat(deg[i]) * 1.5, 12)
                    let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                    context.fill(Circle().path(in: rect), with: .color(.accentColor))
                    context.draw(
                        Text(nodes[i].label).font(.caption2).foregroundStyle(.primary),
                        at: CGPoint(x: point.x, y: point.y + radius + 8)
                    )
                }
            }
            .background(.background)
            .contentShape(.rect)
            .gesture(
                SpatialTapGesture().onEnded { value in
                    if let i = nearestNode(to: value.location) {
                        onSelect(nodes[i].url)
                        dismiss()
                    }
                }
            )
            .onAppear { layout(in: geo.size) }
            .onChange(of: geo.size) { _, newSize in layout(in: newSize) }
            .onChange(of: nodes) { _, _ in layout(in: geo.size) }
        }
    }

    private func layout(in size: CGSize) {
        guard size.width > 0, size.height > 0, !nodes.isEmpty else { return }
        // Recompute only when the node set or size meaningfully changed.
        guard positions.count != nodes.count || size != layoutSize else { return }
        layoutSize = size
        positions = GraphLayout.positions(
            count: nodes.count,
            edges: edges.map { ($0.from, $0.to) },
            size: size
        )
    }

    private func nearestNode(to point: CGPoint) -> Int? {
        var best: (index: Int, dist: CGFloat)?
        for (i, p) in positions.enumerated() {
            let d = hypot(p.x - point.x, p.y - point.y)
            if d < 16, best == nil || d < best!.dist { best = (i, d) }
        }
        return best?.index
    }
}
#endif
