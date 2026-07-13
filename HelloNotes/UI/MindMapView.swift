//
//  MindMapView.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  A radial mind map of a note's *ideas*: the note title at the centre, its
//  heading hierarchy as branches, top-level bullets as sub-ideas, and the
//  `[[wiki-links]]` inside each section attached as linked-note leaves — the
//  bridge from ideas to files. (The file-to-file link view lives in Graph.)
//  Each top-level branch takes its own palette colour; ideas render as solid
//  chips, linked notes as outlined ones. Click an idea to show it in the
//  note; click a linked note to open it. The canvas scrolls and zooms.
//

#if os(macOS)
import SwiftUI

struct MindMapView: View {
    /// The note whose ideas are mapped.
    let rootTitle: String
    let rootURL: URL
    /// The note's Markdown source.
    let text: String
    /// Resolves a `[[wiki-link]]` target to an existing note, if any.
    var resolveLink: (String) -> (url: URL, title: String)?
    /// Root-chip colour — pass the app's resolved accent.
    var accent: Color = .accentColor
    /// Open a linked note in the editor.
    var onOpenNote: (URL) -> Void = { _ in }
    /// Reveal a section in the note (`nil` = just open the note).
    var onShowSection: (String?) -> Void = { _ in }

    @State private var zoom: CGFloat = 1
    @State private var gestureBaseZoom: CGFloat?
    @State private var viewportSize: CGSize = .zero
    @State private var didInitialFit = false
    @Environment(\.dismiss) private var dismiss

    private static let zoomRange: ClosedRange<CGFloat> = 0.4...3

    private var model: MindMapModel {
        MindMapModel(rootTitle: rootTitle, text: text, resolveLink: resolveLink)
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
            Button {
                onShowSection(nil)
            } label: { Label("Open “\(rootTitle)”", systemImage: "arrow.up.forward.square") }
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
            .background(.background)
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

    private func edgeCanvas(model: MindMapModel, positions: [String: CGPoint]) -> some View {
        let colorOf = Dictionary(uniqueKeysWithValues: model.nodes.map { ($0.id, branchColor($0)) })
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

    @ViewBuilder
    private func nodeChip(_ node: MindMapModel.Node) -> some View {
        let color = branchColor(node)
        let isRoot = node.depth == 0
        let fontSize = (isRoot ? 15.0 : node.depth == 1 ? 13.0 : 11.5) * zoom

        Button {
            switch node.kind {
            case .linkedNote(let url): onOpenNote(url)
            case .root: onShowSection(nil)
            case .section: onShowSection(node.title)
            case .bullet: onShowSection(nil)
            }
        } label: {
            // `fixedSize` makes the chip hug its text (a plain `maxWidth`
            // frame would *expand* to it); long titles are pre-truncated so
            // chips stay bounded — and match the collision-pass estimates.
            HStack(spacing: 4 * zoom) {
                if case .linkedNote = node.kind {
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
        }
        .buttonStyle(.plain)
        .contextMenu {
            switch node.kind {
            case .linkedNote(let url):
                Button("Open Note") { onOpenNote(url) }
            case .section:
                Button("Show in Note") { onShowSection(node.title) }
            case .root, .bullet:
                Button("Open Note") { onShowSection(nil) }
            }
        }
        .help(chipHelp(node))
    }

    private func chipBackground(_ node: MindMapModel.Node, color: Color) -> Color {
        switch node.kind {
        case .root, .section: color
        case .bullet: color.opacity(0.22)
        case .linkedNote: Color.clear
        }
    }

    @ViewBuilder
    private func chipBorder(_ node: MindMapModel.Node, color: Color) -> some View {
        switch node.kind {
        case .linkedNote:
            Capsule().strokeBorder(color, lineWidth: max(1, 1.3 * zoom))
        default:
            Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1)
        }
    }

    private func chipForeground(_ node: MindMapModel.Node, color: Color) -> AnyShapeStyle {
        switch node.kind {
        case .root, .section: AnyShapeStyle(.white)
        case .bullet: AnyShapeStyle(.primary)
        case .linkedNote: AnyShapeStyle(color)
        }
    }

    private func chipHelp(_ node: MindMapModel.Node) -> String {
        switch node.kind {
        case .root: "The note — click to open it"
        case .section: "Section — click to show it in the note"
        case .bullet: "Idea — click to open the note"
        case .linkedNote: "Linked note — click to open “\(node.title)”"
        }
    }

    /// The zoom that fits the whole map in the current viewport.
    private func fitZoom() -> CGFloat {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return 1 }
        let size = model.layout().size
        return min(viewportSize.width / size.width, viewportSize.height / size.height) * 0.96
    }
}

// MARK: - Model

/// Builds a note's idea tree from its Markdown: headings nest as sections,
/// top-level bullets become sub-ideas, and `[[wiki-links]]` attach to the
/// section they appear in as linked-note leaves. Pure parsing — testable
/// without a view.
struct MindMapModel {
    enum Kind: Hashable {
        case root
        case section
        case bullet
        case linkedNote(URL)
    }

    struct Node: Identifiable, Hashable {
        let id: String
        let title: String
        let depth: Int
        let angle: Double
        /// Which depth-1 subtree the node belongs to (colours the branch);
        /// -1 for the root itself.
        let branch: Int
        let kind: Kind
    }

    struct Edge: Hashable {
        let from: String
        let to: String
    }

    /// Distance between rings, in world points.
    static let ringStep: CGFloat = 150
    /// Bullets kept per section, and a ceiling on total ideas, so a huge note
    /// stays a readable map rather than a starburst.
    static let maxBulletsPerSection = 6
    static let maxNodes = 70

    /// The final node placement: positions in world coordinates plus the world
    /// size that contains every chip.
    struct Layout {
        let positions: [String: CGPoint]
        let size: CGSize
    }

    private(set) var nodes: [Node] = []
    private(set) var edges: [Edge] = []
    private var maxUsedDepth = 0

    // MARK: Parsing

    private final class Item {
        let title: String
        let kind: Kind
        var children: [Item] = []
        var bulletCount = 0
        var linkedTargets = Set<String>()

        init(title: String, kind: Kind) {
            self.title = title
            self.kind = kind
        }
    }

    init(rootTitle: String, text: String, resolveLink: (String) -> (url: URL, title: String)?) {
        let root = Item(title: rootTitle, kind: .root)

        // (heading level, section) — bullets and links attach to the last one.
        var stack: [(level: Int, item: Item)] = [(0, root)]
        var inCodeFence = false
        var totalItems = 0

        func attach(_ item: Item, to parent: Item) -> Bool {
            guard totalItems < Self.maxNodes else { return false }
            parent.children.append(item)
            totalItems += 1
            return true
        }

        for rawLine in FrontMatter.body(of: text).components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inCodeFence.toggle(); continue }
            if inCodeFence || line.isEmpty { continue }

            // Headings nest by level.
            if let (level, title) = Self.heading(line) {
                // The customary `# Note Title` first heading *is* the root.
                if level == 1, title.compare(rootTitle, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                    stack = [(1, root)]
                    continue
                }
                while stack.count > 1 && stack.last!.level >= level { stack.removeLast() }
                let section = Item(title: Self.cleanInline(title), kind: .section)
                if attach(section, to: stack.last!.item) {
                    stack.append((level, section))
                }
                continue
            }

            let current = stack.last!.item

            // Wiki links anywhere in the line become linked-note leaves of the
            // current section (embeds `![[…]]` excluded).
            for target in Self.wikiTargets(line) {
                guard let resolved = resolveLink(target),
                      resolved.title.compare(rootTitle, options: .caseInsensitive) != .orderedSame,
                      current.linkedTargets.insert(resolved.title.lowercased()).inserted
                else { continue }
                _ = attach(Item(title: resolved.title, kind: .linkedNote(resolved.url)), to: current)
            }

            // Top-level bullets become sub-ideas (skip ones that were nothing
            // but a wiki link — the leaf above already represents them).
            if !rawLine.hasPrefix(" "), !rawLine.hasPrefix("\t"),
               let content = Self.bullet(line) {
                let cleaned = Self.cleanInline(content)
                guard !cleaned.isEmpty, current.bulletCount < Self.maxBulletsPerSection else { continue }
                current.bulletCount += 1
                _ = attach(Item(title: cleaned, kind: .bullet), to: current)
            }
        }

        // Flatten: each leaf gets an even slice of the circle; internal nodes
        // average their children. Each depth-1 subtree is one colour branch.
        let leafCount = max(1, Self.countLeaves(root))
        var nextLeaf = 0
        var nextID = 0
        var built: [Node] = []
        var edgeList: [Edge] = []
        var deepest = 0

        @discardableResult
        func walk(_ item: Item, depth: Int, branch: Int, id: String) -> Double {
            let angle: Double
            if item.children.isEmpty {
                angle = (Double(nextLeaf) + 0.5) / Double(leafCount) * 2 * .pi
                nextLeaf += 1
            } else {
                let childAngles = item.children.enumerated().map { index, child -> Double in
                    nextID += 1
                    let childID = "n\(nextID)"
                    edgeList.append(Edge(from: id, to: childID))
                    return walk(child, depth: depth + 1,
                                branch: depth == 0 ? index : branch, id: childID)
                }
                angle = childAngles.reduce(0, +) / Double(childAngles.count)
            }
            built.append(Node(id: id, title: item.title, depth: depth,
                              angle: angle, branch: branch, kind: item.kind))
            deepest = max(deepest, depth)
            return angle
        }
        walk(root, depth: 0, branch: -1, id: "root")

        nodes = built
        edges = edgeList
        maxUsedDepth = deepest
    }

    // MARK: Line parsing helpers

    /// `## Title` → (2, "Title").
    private static func heading(_ line: String) -> (level: Int, title: String)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" })
        guard hashes.count <= 6 else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        let title = rest.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : (hashes.count, title)
    }

    /// `- idea` / `* idea` / `1. idea` → "idea"; nil when the bullet is
    /// nothing but a wiki link (the linked-note leaf covers it).
    private static func bullet(_ line: String) -> String? {
        var content: String?
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            content = String(line.dropFirst(prefix.count))
        }
        if content == nil,
           let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }),
           line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
           line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " " {
            content = String(line[line.index(dot, offsetBy: 2)...])
        }
        guard var text = content?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        // Task checkboxes: `- [ ] thing` / `- [x] thing`.
        for box in ["[ ] ", "[x] ", "[X] "] where text.hasPrefix(box) {
            text = String(text.dropFirst(box.count))
        }
        // A bullet that is exactly one wiki link is represented by its leaf.
        let bare = text.trimmingCharacters(in: .whitespaces)
        if bare.hasPrefix("[["), bare.hasSuffix("]]"),
           !bare.dropFirst(2).dropLast(2).contains("]") {
            return nil
        }
        return text
    }

    /// `[[Target]]`, `[[Target#h]]`, `[[Target|alias]]` → "Target"
    /// (embeds `![[…]]` excluded).
    private static let wikiLinkRegex = try? NSRegularExpression(
        pattern: #"(?<!\!)\[\[([^\]\|#\n]+)(?:#[^\]\|\n]*)?(?:\|[^\]\n]*)?\]\]"#
    )

    private static func wikiTargets(_ line: String) -> [String] {
        guard let regex = wikiLinkRegex else { return [] }
        let range = NSRange(line.startIndex..., in: line)
        return regex.matches(in: line, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: line) else { return nil }
            let target = line[r].trimmingCharacters(in: .whitespaces)
            return target.isEmpty ? nil : target
        }
    }

    /// Strip inline Markdown down to readable idea text.
    static func cleanInline(_ text: String) -> String {
        var s = text
        // `[[a|b]]` → b, `[[a#h]]` → a, `[[a]]` → a; embeds vanish.
        s = s.replacingOccurrences(of: #"!\[\[[^\]]*\]\]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[\[([^\]\|#]+)(?:#[^\]\|]*)?\|([^\]]+)\]\]"#,
                                   with: "$2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[\[([^\]\|#]+)(?:#[^\]\|]*)?\]\]"#,
                                   with: "$1", options: .regularExpression)
        // `[text](url)` → text.
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        for token in ["**", "__", "==", "~~", "`", "*"] {
            s = s.replacingOccurrences(of: token, with: "")
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Chip text, truncated at the string level so chips stay bounded and the
    /// collision estimates share the exact character count the view renders.
    nonisolated static func displayTitle(_ title: String) -> String {
        title.count > 32 ? String(title.prefix(31)) + "…" : title
    }

    private static func countLeaves(_ item: Item) -> Int {
        item.children.isEmpty ? 1 : item.children.reduce(0) { $0 + countLeaves($1) }
    }

    // MARK: Layout

    /// Lay the nodes out: radial rings by depth first, then a collision pass
    /// that pushes overlapping chips apart (the root stays pinned), and a
    /// final rebase so everything sits inside a positive-coordinate world.
    func layout() -> Layout {
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

        var positions: [String: CGPoint] = [:]
        for (node, center) in zip(nodes, centers) { positions[node.id] = center }
        return Layout(positions: positions, size: size)
    }

    /// The approximate footprint of a node's chip (mirrors `nodeChip`'s font
    /// and padding at zoom 1).
    nonisolated static func estimatedChipSize(_ node: Node) -> CGSize {
        let fontSize: CGFloat = node.depth == 0 ? 15 : node.depth == 1 ? 13 : 11.5
        let hPad: CGFloat = node.depth == 0 ? 13 : 10
        let vPad: CGFloat = node.depth == 0 ? 8 : 5.5
        var textWidth = LayoutRelaxation.estimatedTextWidth(
            displayTitle(node.title), fontSize: fontSize, maxWidth: .greatestFiniteMagnitude)
        if case .linkedNote = node.kind { textWidth += fontSize }   // leading icon
        return CGSize(width: textWidth + hPad * 2, height: fontSize * 1.25 + vPad * 2)
    }
}
#endif
