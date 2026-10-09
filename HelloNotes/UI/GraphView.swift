//
//  GraphView.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

// **Not macOS-only.** This file was `#if os(macOS)` and used no AppKit and
// no Mac-only API — the gate was the only thing keeping it off iPad.
import SwiftUI

/// A node in the link graph.
struct GraphNode: Identifiable, Hashable {
    let url: URL
    let label: String
    var id: URL { url }
}

/// A directed edge (indices into the node array): the note at `from` links to
/// the note at `to`.
struct GraphEdge: Hashable {
    let from: Int
    let to: Int
}

/// The shared node palette for the graph and mind-map views — distinct hues
/// that read well in light and dark. The system's, as AppKit resolves them,
/// fixed per appearance like the chrome's own: a system colour resolves to
/// each platform's value, so a folder's colour was the platform's choice.
enum NodePalette {
    static let colors: [Color] = [
        Chrome.Colour.blue, Chrome.Colour.purple, Chrome.Colour.pink,
        Chrome.Colour.orange, Chrome.Colour.teal, Chrome.Colour.green,
        Chrome.Colour.indigo, Chrome.Colour.red, Chrome.Colour.cyan, Chrome.Colour.mint,
        Chrome.Colour.yellow, Chrome.Colour.brown,
    ]

    static func color(_ index: Int) -> Color {
        colors[((index % colors.count) + colors.count) % colors.count]
    }

    /// Semantic edge colours when a note is focused: the notes it links to,
    /// and the notes that link to it.
    static let outgoing: Color = Chrome.Colour.blue
    static let incoming: Color = Chrome.Colour.orange
}

/// Shared zoom controls for the canvas views: −, live percentage, +, Fit.
struct ZoomControls: View {
    @Binding var zoom: CGFloat
    let range: ClosedRange<CGFloat>
    /// Zoom that would fit the whole content in the viewport.
    let fitZoom: () -> CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Button {
                zoom = max(range.lowerBound, zoom / 1.25)
            } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
                .accessibilityLabel("Zoom out")
            Text("\(Int((zoom * 100).rounded()))%")
                .font(Chrome.Style.caption.monospacedDigit())
                .foregroundStyle(Chrome.Colour.secondaryLabel)
                .frame(width: 40)
            Button {
                zoom = min(range.upperBound, zoom * 1.25)
            } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
                .accessibilityLabel("Zoom in")
            Button("Fit") {
                zoom = min(max(fitZoom(), range.lowerBound), range.upperBound)
            }
            .help("Zoom to fit everything")
        }
        .buttonStyle(ChromeBorderlessStyle())
    }
}

/// A native force-directed graph of notes and their `[[wiki-links]]`, drawn
/// with `Canvas` (no WebView). Nodes are coloured by folder and sized by
/// connectivity; edges are directional (arrowheads point at the linked note).
/// Click a note to focus it — its outgoing links and backlinks light up in
/// two colours and everything else dims; double-click to open the note.
/// The canvas scrolls and zooms (pinch or the header controls).
///
/// It never closes itself — it is a panel beside the editor, and a note
/// opened from it opens beside it. A Done button, and a click that opened
/// the note and closed the graph, were here for sheets, behind an
/// `isWindowed` flag; nothing had passed `false` since the Mac's and the
/// iPad's graphs became one view (`GraphPane`), and they went.
struct GraphView: View {
    let nodes: [GraphNode]
    let edges: [GraphEdge]
    let onSelect: (URL) -> Void
    /// The app's accent, for the focus ring; nodes take their colour per
    /// folder. Given, because `Color.accentColor` is not the person's choice.
    var accent: Color
    /// Node labels used to scale by canvas zoom alone, so raising the text
    /// size moved every other surface in the app and left the graph at a flat
    /// 11pt. Zoom still multiplies on top — the two are independent. The text
    /// size is the chrome's one table (`Chrome.Style.points`), where
    /// `@ScaledMetric` scaled by each platform's own.
    private var labelPointSize: CGFloat { Chrome.Style.points(11) }
    /// The focused note (drives directional edge colouring). Owned by the host
    /// so it can also drive scoping.
    var focusedURL: URL?
    var onFocusChange: (URL?) -> Void = { _ in }

    @State private var positions: [CGPoint] = []
    /// World size, derived from the laid-out (and collision-relaxed) nodes.
    @State private var contentSize = CGSize(width: 520, height: 520)
    @State private var zoom: CGFloat = 1
    @State private var gestureBaseZoom: CGFloat?
    @State private var viewportSize: CGSize = .zero
    @State private var didInitialFit = false

    private static let zoomRange: ClosedRange<CGFloat> = 0.4...3

    /// The base canvas the force layout runs in — sized by node count, not the
    /// window, so nodes sit close together and pan/zoom does the rest.
    private var layoutBaseSize: CGSize {
        let side = max(520, Double(nodes.count).squareRoot() * 170)
        return CGSize(width: side, height: side)
    }

    /// Each node's visual footprint — the orb plus the label beneath it —
    /// used by the collision pass so neither orbs nor labels overlap.
    private var nodeFootprints: [CGSize] {
        let deg = degrees
        return nodes.enumerated().map { i, node in
            let diameter = radius(degree: deg[i]) * 2
            let labelWidth = LayoutRelaxation.estimatedTextWidth(node.label, fontSize: 11, maxWidth: 220)
            return CGSize(width: max(diameter, labelWidth), height: diameter + 22)
        }
    }

    private var degrees: [Int] {
        var d = Array(repeating: 0, count: nodes.count)
        for edge in edges {
            if edge.from < d.count { d[edge.from] += 1 }
            if edge.to < d.count { d[edge.to] += 1 }
        }
        return d
    }

    /// A stable colour per containing folder, so related notes share a hue.
    private var nodeColors: [Color] {
        let folders = nodes.map { $0.url.deletingLastPathComponent().standardizedFileURL.path }
        let unique = Array(Set(folders)).sorted()
        let indexOf = Dictionary(uniqueKeysWithValues: unique.enumerated().map { ($1, $0) })
        return folders.map { NodePalette.color(indexOf[$0] ?? 0) }
    }

    private var focusedIndex: Int? {
        focusedURL.flatMap { url in nodes.firstIndex { $0.url == url } }
    }

    private func radius(degree: Int) -> CGFloat {
        8 + min(CGFloat(degree) * 2.5, 16)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                // No title: the panel's own header says "Graph".
                Spacer()
                Text("\(nodes.count) notes · \(edges.count) links")
                    .font(Chrome.Style.caption)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                ZoomControls(zoom: $zoom, range: Self.zoomRange, fitZoom: fitZoom)
            }
            .padding(12)
            ChromeDivider()
            scrollingCanvas
        }
        // No minimum: this is a pane now, and a canvas that demands 560pt
        // inside a 420pt pane draws past its own edge — which is what it did.
        // The canvas scrolls and zooms, so it fits whatever it is given.
    }

    // MARK: - Canvas

    private var scrollingCanvas: some View {
        GeometryReader { viewport in
            ScrollView([.horizontal, .vertical]) {
                graphCanvas
                    .frame(width: contentSize.width * zoom, height: contentSize.height * zoom)
                    // Centre the world in the viewport while it's smaller.
                    .frame(minWidth: viewport.size.width, minHeight: viewport.size.height)
            }
            .background(Chrome.Colour.content)
            .onChange(of: viewport.size, initial: true) { _, size in
                viewportSize = size
                // Open at "everything visible" once, then leave zoom alone.
                if !didInitialFit, size.width > 0 {
                    didInitialFit = true
                    zoom = min(max(fitZoom(), Self.zoomRange.lowerBound), 1.2)
                }
            }
        }
        .overlay(alignment: .bottomLeading) { canvasFooter }
        .task(id: nodes) {
            await relayout()
            // A new node set (scope or collection change) means a new world
            // size — re-fit so the whole layout is visible again.
            if didInitialFit, viewportSize.width > 0 {
                zoom = min(max(fitZoom(), Self.zoomRange.lowerBound), 1.2)
            }
        }
    }

    /// Discoverability footer: a hint while nothing is focused; a direction
    /// legend (plus clear button) while a note is.
    private var canvasFooter: some View {
        HStack(spacing: 10) {
            if let f = focusedIndex {
                Text(nodes[f].label).fontWeight(.semibold).lineLimit(1)
                Label("Links to", systemImage: "arrow.right")
                    .foregroundStyle(NodePalette.outgoing)
                Label("Linked from", systemImage: "arrow.left")
                    .foregroundStyle(NodePalette.incoming)
                Button {
                    onFocusChange(nil)
                } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(ChromeBorderlessStyle())
                    .help("Clear focus")
                    .accessibilityLabel("Clear focus")
            } else {
                Text(PointerPresence.shared.prefersTouch
                     ? "Tap a note to trace its links · double-tap to open"
                     : "Click a note to trace its links · double-click to open")
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
            }
        }
        .font(Chrome.Style.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // A card floating over the canvas, not a material: a blur is the
        // platform's drawing, and a different one on each.
        .background(Chrome.Colour.content, in: Capsule())
        .overlay(Capsule().strokeBorder(Chrome.Colour.separator))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .padding(10)
    }

    private var graphCanvas: some View {
        // Read here, in the body, so a change of text size is observed and
        // redraws the canvas; a read inside the renderer below is not
        // guaranteed to be.
        let labelPointSize = self.labelPointSize
        return Canvas { context, _ in
            guard positions.count == nodes.count else { return }
            let colors = nodeColors
            let deg = degrees
            let focus = focusedIndex

            // Nodes connected to the focus (they stay at full strength).
            var undimmed = Set<Int>()
            if let f = focus {
                undimmed.insert(f)
                for edge in edges {
                    if edge.from == f { undimmed.insert(edge.to) }
                    if edge.to == f { undimmed.insert(edge.from) }
                }
            }

            // Edges — directional: the line stops at the target's rim and ends
            // in an arrowhead. With a focused note, its outgoing links and
            // backlinks take the two semantic colours; the rest fade.
            for edge in edges where edge.from < positions.count && edge.to < positions.count {
                let a = scaled(positions[edge.from])
                let b = scaled(positions[edge.to])
                let rA = radius(degree: deg[edge.from]) * zoom
                let rB = radius(degree: deg[edge.to]) * zoom
                let d = hypot(b.x - a.x, b.y - a.y)
                guard d > rA + rB + 6 else { continue }
                let ux = (b.x - a.x) / d, uy = (b.y - a.y) / d

                let arrowLength = max(5, 6.5 * zoom)
                let start = CGPoint(x: a.x + ux * (rA + 1), y: a.y + uy * (rA + 1))
                let tip = CGPoint(x: b.x - ux * (rB + 1.5), y: b.y - uy * (rB + 1.5))
                let base = CGPoint(x: tip.x - ux * arrowLength, y: tip.y - uy * arrowLength)

                let shading: GraphicsContext.Shading
                var lineWidth = max(1, 1.3 * zoom)
                if let f = focus {
                    if edge.from == f {
                        shading = .color(NodePalette.outgoing.opacity(0.9))
                        lineWidth = max(1.4, 1.8 * zoom)
                    } else if edge.to == f {
                        shading = .color(NodePalette.incoming.opacity(0.9))
                        lineWidth = max(1.4, 1.8 * zoom)
                    } else {
                        shading = .color(Chrome.Colour.secondaryLabel.opacity(0.10))
                    }
                } else {
                    shading = .linearGradient(
                        Gradient(colors: [colors[edge.from].opacity(0.55), colors[edge.to].opacity(0.55)]),
                        startPoint: a, endPoint: b
                    )
                }

                var line = Path()
                line.move(to: start)
                line.addLine(to: base)
                context.stroke(line, with: shading, lineWidth: lineWidth)

                // Arrowhead at the target's rim.
                let wing = arrowLength * 0.55
                var head = Path()
                head.move(to: tip)
                head.addLine(to: CGPoint(x: base.x - uy * wing, y: base.y + ux * wing))
                head.addLine(to: CGPoint(x: base.x + uy * wing, y: base.y - ux * wing))
                head.closeSubpath()
                if focus != nil {
                    context.fill(head, with: shading)
                } else {
                    context.fill(head, with: .color(colors[edge.to].opacity(0.75)))
                }
            }

            // Nodes — folder-coloured orbs with a soft shadow, plus labels.
            for (i, world) in positions.enumerated() {
                let p = scaled(world)
                let r = radius(degree: deg[i]) * zoom
                let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                let circle = Circle().path(in: rect)

                var ctx = context
                if focus != nil && !undimmed.contains(i) { ctx.opacity = 0.25 }

                var shadowed = ctx
                shadowed.addFilter(.shadow(color: .black.opacity(0.30), radius: 3 * zoom, y: 1.5 * zoom))
                shadowed.fill(circle, with: .radialGradient(
                    Gradient(colors: [.white.opacity(0.45), colors[i]]),
                    center: CGPoint(x: p.x - r * 0.35, y: p.y - r * 0.4),
                    startRadius: 0, endRadius: r * 1.5
                ))
                ctx.stroke(circle, with: .color(.white.opacity(0.45)), lineWidth: max(0.8, 0.9 * zoom))

                if i == focusedIndex {
                    let ringRect = rect.insetBy(dx: -4 * zoom, dy: -4 * zoom)
                    ctx.stroke(Circle().path(in: ringRect), with: .color(accent), lineWidth: max(1.6, 2 * zoom))
                }

                ctx.draw(
                    Text(nodes[i].label)
                        .font(.system(size: labelPointSize * zoom, weight: .medium))
                        .foregroundStyle(Chrome.Colour.label),
                    at: CGPoint(x: p.x, y: p.y + r + 10 * zoom)
                )
            }
        }
        // The window root's line height (`chromeDefaults`, every line its size
        // plus three) reaches text drawn into a Canvas too, and there
        // `draw(_:at:)` ignores the point it is given: every node's label was
        // drawn in one pile at the canvas's top-left corner, on both
        // platforms, and no orb had a name. A label is one line, so the
        // canvas takes the default line height back (`GraphLabelTests`).
        .lineHeight(nil)
        .contentShape(.rect)
        // The graph is drawn into a Canvas, so expose a VoiceOver-navigable list
        // of the notes (otherwise it's an opaque rectangle). Activating a node
        // opens its note.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Note graph")
        .accessibilityValue("\(nodes.count) notes")
        .accessibilityChildren {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                Button(node.label) { onSelect(node.url) }
                    .accessibilityHint("\(degrees.indices.contains(index) ? degrees[index] : 0) links. Activate to open.")
            }
        }
        .gesture(
            ExclusiveGesture(
                SpatialTapGesture(count: 2),
                SpatialTapGesture()
            )
            .onEnded { value in
                switch value {
                case .first(let double):
                    // Double-click: open the note.
                    if let i = nearestNode(to: double.location) {
                        onSelect(nodes[i].url)
                    }
                case .second(let single):
                    // Click: focus (or clear on a repeat / empty click).
                    if let i = nearestNode(to: single.location) {
                        onFocusChange(nodes[i].url == focusedURL ? nil : nodes[i].url)
                    } else {
                        onFocusChange(nil)
                    }
                }
            }
        )
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

    // MARK: - Geometry

    private func scaled(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * zoom, y: p.y * zoom)
    }

    /// The zoom that fits the whole world in the current viewport.
    private func fitZoom() -> CGFloat {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return 1 }
        return min(viewportSize.width / contentSize.width,
                   viewportSize.height / contentSize.height) * 0.96
    }

    /// Lay out in world coordinates (independent of window size): the force
    /// layout gives the structure, a collision pass separates any nodes whose
    /// orbs or labels would overlap, and a rebase sizes the world so nothing
    /// clips at the edges.
    private func relayout() async {
        guard !nodes.isEmpty else {
            positions = []
            contentSize = CGSize(width: 520, height: 520)
            return
        }
        // The force layout and collision pass are both O(N²) per iteration —
        // run them off the main actor so a large graph never freezes the UI.
        // (Node count is also capped by the caller; this keeps the boundary
        // case smooth.) The math is pure/`nonisolated`; only Sendable values
        // (edge pairs, footprints, sizes) cross the actor hop.
        let edgePairs = edges.map { ($0.from, $0.to) }
        let footprints = nodeFootprints
        let base = layoutBaseSize
        let count = nodes.count
        let result = await Task.detached(priority: .userInitiated) { () -> (centers: [CGPoint], size: CGSize) in
            var centers = GraphLayout.positions(count: count, edges: edgePairs, size: base)
            LayoutRelaxation.separate(centers: &centers, sizes: footprints, padding: 8, iterations: 80)
            let size = LayoutRelaxation.rebase(centers: &centers, sizes: footprints, margin: 48)
            return (centers, size)
        }.value
        guard !Task.isCancelled else { return }
        contentSize = result.size
        positions = result.centers
    }

    /// Hit-test in view coordinates against each node's drawn radius.
    private func nearestNode(to point: CGPoint) -> Int? {
        let deg = degrees
        // `positions` is recomputed off-main via `.task(id: nodes)`; during the
        // window between a node-set change and the layout landing, `positions`
        // still holds the old array while `nodes`/`degrees` are new. Guard the
        // count (as the draw path does) so `deg[i]`/`nodes[i]` can't go out of
        // range on a click mid-relayout.
        guard positions.count == nodes.count, deg.count == nodes.count else { return nil }
        var best: (index: Int, dist: CGFloat)?
        for (i, world) in positions.enumerated() {
            let p = scaled(world)
            let hitRadius = radius(degree: deg[i]) * zoom + 10
            let d = hypot(p.x - point.x, p.y - point.y)
            if d < hitRadius, best == nil || d < best!.dist { best = (i, d) }
        }
        return best?.index
    }
}
