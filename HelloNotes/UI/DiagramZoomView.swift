//
//  DiagramZoomView.swift
//  HelloNotes
//
//  One Mermaid diagram, as large as you want it.
//
//  A diagram in a note is drawn at the width of the column — right for reading
//  the note, wrong for reading a forty-node flowchart. Three routes open this,
//  under one name: the button in a diagram's corner (Edit and Preview both draw
//  one), the bar's button and Note Actions ▸ View Diagram — "View diagram" on
//  the bar and as Preview's corner button's tooltip, title case in the menu, as
//  every command there is. (Edit's corner button is drawn by the text and has
//  no label.) They had three names — Enlarge diagram, Enlarge Mermaid diagrams,
//  Mermaid Diagrams — for one view. What opens: the diagram fitted to the
//  sheet, then pinch, the zoom controls or a double-click to go closer, and ‹ ›
//  through the note's other diagrams.
//
//  It replaces a sheet that was not a zoom. `MermaidPreviewView` was written at
//  noon on 11 July, when the editor could not yet draw a diagram in the note —
//  by five that afternoon it could — and it re-rendered every diagram in the
//  note into a fixed 680×560 list, each scaled down to fit. Once the note drew
//  its own diagrams, the sheet showed the same pictures smaller.
//
//  **Drawn as vectors**, by the renderer the note's pictures come from
//  (`DiagramDrawing`), so 800% is as sharp as 100% — and into a canvas the size
//  of the *viewport*, not of the zoomed diagram. A scroll view pans an empty
//  frame of the zoomed size and the canvas behind it draws what shows: scaled
//  content would be a layer eight times the diagram's size in each direction.
//

import SwiftUI
import MarkdownCore
import MarkdownEditor

/// Which diagrams the zoom shows, and which one it opens on.
///
/// `nonisolated` so the text-based `make` can run off the main actor: finding a
/// note's diagrams in its text is a whole-document parse.
nonisolated struct DiagramZoomRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    /// The note's diagrams, in order.
    let sources: [String]
    /// The one to open on.
    let start: Int

    /// The zoom for the diagrams in `text` — a whole-document parse, so call it
    /// off the main actor. See `make(diagrams:zoom:caret:)`.
    static func make(text: String, zoom: DiagramZoom?, caret: Int?) -> DiagramZoomRequest? {
        make(diagrams: MarkdownParsing.mermaidDiagrams(in: text), zoom: zoom, caret: caret)
    }

    /// The zoom for `diagrams`: on `zoom`'s diagram when a diagram's button
    /// asked, on the one nearest `caret` when the bar or the menu did. Nil when
    /// the note has no diagram to show.
    ///
    /// By place first — two identical diagrams are two diagrams, and pressing
    /// the second one's button opens the second. By source next: Preview has a
    /// page, not offsets. And if the note no longer holds the diagram at all
    /// (it changed under the press), that diagram alone rather than a
    /// different one.
    static func make(diagrams: [MermaidDiagram], zoom: DiagramZoom?, caret: Int?) -> DiagramZoomRequest? {
        let sources = diagrams.map(\.source)
        guard let zoom else {
            guard !diagrams.isEmpty else { return nil }
            return DiagramZoomRequest(sources: sources, start: nearest(to: caret, in: diagrams))
        }
        if let location = zoom.location,
           let at = diagrams.firstIndex(where: { NSLocationInRange(location, $0.range) }),
           diagrams[at].source == zoom.source {
            return DiagramZoomRequest(sources: sources, start: at)
        }
        if let at = sources.firstIndex(of: zoom.source) {
            return DiagramZoomRequest(sources: sources, start: at)
        }
        return DiagramZoomRequest(sources: [zoom.source], start: 0)
    }

    /// The diagram the caret is in, or else the one closest to it — the
    /// earlier of two equally close. The first, with no caret to go by.
    static func nearest(to caret: Int?, in diagrams: [MermaidDiagram]) -> Int {
        guard let caret else { return 0 }
        func distance(_ range: NSRange) -> Int {
            if caret < range.location { return range.location - caret }
            if caret >= NSMaxRange(range) { return caret - NSMaxRange(range) + 1 }
            return 0
        }
        return diagrams.indices.min { distance(diagrams[$0].range) < distance(diagrams[$1].range) } ?? 0
    }
}

struct DiagramZoomView: View {
    let request: DiagramZoomRequest

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var index: Int
    @State private var drawing: DiagramDrawing?
    @State private var failed = false
    @State private var zoom: CGFloat = 1
    @State private var viewport: CGSize = .zero
    /// The diagram the zoom was last fitted to. Fitting happens once per
    /// diagram, so a change of appearance redraws it without undoing a zoom.
    @State private var fittedIndex: Int?

    static let zoomRange: ClosedRange<CGFloat> = 0.1...8
    /// The most a diagram is enlarged on opening. A small one fitted to the
    /// sheet would be blown up rather than enlarged; the controls go further.
    static let openingZoomLimit: CGFloat = 3
    /// Clear space around the diagram, at every zoom.
    static let margin: CGFloat = 24

    init(request: DiagramZoomRequest) {
        self.request = request
        _index = State(initialValue: min(max(0, request.start), max(0, request.sources.count - 1)))
    }

    private var count: Int { request.sources.count }
    private var title: String { count > 1 ? "Diagram \(index + 1) of \(count)" : "Diagram" }

    var body: some View {
        VStack(spacing: 0) {
            ChromeSheetBar(title) {
                EmptyView()
            } trailing: {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            picture
            ChromeDivider()
            footer
        }
        // The size of the slides sheet, the other sheet that shows the note
        // larger than the column does.
        .chromeSheetFrame(width: 960, height: 680)
        .task(id: Preparation(index: index, isDark: colorScheme == .dark)) { await prepare() }
        .onChange(of: viewport) { _, _ in fitIfNeeded() }
    }

    @ViewBuilder private var picture: some View {
        Group {
            if let drawing {
                ZoomingDiagram(drawing: drawing, zoom: $zoom, viewport: $viewport,
                               range: Self.zoomRange, margin: Self.margin, fitZoom: fitZoom)
                    .accessibilityLabel(title)
            } else if failed {
                ChromeEmptyState("Couldn’t Draw This Diagram", systemImage: "exclamationmark.triangle",
                                 description: Text("Its Mermaid source in the note has something this renderer can’t read."))
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The note's own canvas: the diagram is drawn for it, transparent.
        .background(Color(EditorTheme.canvas(isDark: colorScheme == .dark)))
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if count > 1 {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(index <= 0)
                    .help("Previous diagram")
                    .accessibilityLabel("Previous diagram")
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(index >= count - 1)
                    .help("Next diagram")
                    .accessibilityLabel("Next diagram")
            }
            Spacer()
            ZoomControls(zoom: $zoom, range: Self.zoomRange, fitZoom: fitZoom)
                .disabled(drawing == nil)
        }
        .buttonStyle(ChromeBorderlessStyle())
        .font(Chrome.Style.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Chrome.Colour.chrome)
    }

    /// What a drawing depends on: which diagram, and in which appearance.
    private struct Preparation: Hashable {
        let index: Int
        let isDark: Bool
    }

    /// Lay the diagram out off the main actor — parsing and layout are
    /// computation, and a large flowchart's layout is not free.
    private func prepare() async {
        let source = request.sources[index]
        let isDark = colorScheme == .dark
        let prepared = await offMain { MermaidDiagramRenderer.drawing(source: source, isDark: isDark) }
        guard !Task.isCancelled else { return }
        drawing = prepared
        failed = prepared == nil
        fitIfNeeded()
    }

    /// Open each diagram whole: fitted to the sheet, up to `openingZoomLimit`.
    private func fitIfNeeded() {
        guard fittedIndex != index, drawing != nil, viewport.width > 0, viewport.height > 0 else { return }
        fittedIndex = index
        zoom = min(max(fitZoom(), Self.zoomRange.lowerBound), Self.openingZoomLimit)
    }

    /// The zoom at which the whole diagram fits, inside its margin.
    private func fitZoom() -> CGFloat {
        guard let drawing, viewport.width > 0, viewport.height > 0 else { return 1 }
        let width = (viewport.width - 2 * Self.margin) / drawing.size.width
        let height = (viewport.height - 2 * Self.margin) / drawing.size.height
        return max(0.01, min(width, height))
    }

    private func step(_ delta: Int) {
        let next = min(max(0, index + delta), count - 1)
        guard next != index else { return }
        // Nothing of the last diagram — not its drawing, not its place.
        drawing = nil
        failed = false
        index = next
    }
}

/// A diagram drawn at `zoom`: scrolled by a scroll view, pinched, and
/// double-clicked or double-tapped in and back out.
private struct ZoomingDiagram: View {
    let drawing: DiagramDrawing
    @Binding var zoom: CGFloat
    /// The visible size, reported so the sheet can fit the diagram to it.
    @Binding var viewport: CGSize
    let range: ClosedRange<CGFloat>
    let margin: CGFloat
    let fitZoom: () -> CGFloat

    /// The content point at the viewport's top-left corner.
    @State private var offset: CGPoint = .zero
    @State private var position = ScrollPosition(point: .zero)
    /// The zoom a pinch started from.
    @State private var pinchBase: CGFloat?
    /// Where on screen the next zoom change holds still: under the fingers for
    /// a pinch, under the pointer for a double-click, the middle otherwise.
    @State private var anchor: CGPoint?

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Color.clear
                .frame(width: contentSize(zoom).width, height: contentSize(zoom).height)
                .contentShape(Rectangle())
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, geometry in
            if offset != geometry.visibleRect.origin { offset = geometry.visibleRect.origin }
            if viewport != geometry.containerSize { viewport = geometry.containerSize }
        }
        .background {
            Canvas { context, _ in
                let origin = placement(zoom)
                context.withCGContext { cg in
                    cg.translateBy(x: origin.x - offset.x, y: origin.y - offset.y)
                    cg.scaleBy(x: zoom, y: zoom)
                    drawing.draw(in: cg)
                }
            }
        }
        // Every change of zoom — pinch, double-click, the controls, Fit — goes
        // through here, so the point being looked at stays where it is.
        .onChange(of: zoom) { old, new in follow(from: old, to: new) }
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let base = pinchBase ?? zoom
                    pinchBase = base
                    anchor = value.startLocation
                    zoom = clamped(base * value.magnification)
                }
                .onEnded { _ in
                    pinchBase = nil
                    anchor = nil
                }
        )
        .onTapGesture(count: 2) { location in
            anchor = location
            let fit = fitZoom()
            zoom = clamped(zoom > fit * 1.05 ? fit : max(zoom, fit) * 2.5)
        }
        .accessibilityElement()
        .accessibilityAddTraits(.isImage)
        .accessibilityValue("\(Int((zoom * 100).rounded())) percent")
        .accessibilityZoomAction { action in
            zoom = clamped(action.direction == .zoomIn ? zoom * 1.25 : zoom / 1.25)
        }
    }

    private func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// The scroll view's content at `zoom`: the diagram and its margin, or the
    /// viewport if that is larger — a small diagram does not scroll.
    private func contentSize(_ zoom: CGFloat) -> CGSize {
        CGSize(width: max(viewport.width, drawing.size.width * zoom + 2 * margin),
               height: max(viewport.height, drawing.size.height * zoom + 2 * margin))
    }

    /// Where the diagram's top-left corner sits in that content: centred while
    /// it is smaller than the viewport, one margin in once it is not.
    private func placement(_ zoom: CGFloat) -> CGPoint {
        CGPoint(x: max(margin, (viewport.width - drawing.size.width * zoom) / 2),
                y: max(margin, (viewport.height - drawing.size.height * zoom) / 2))
    }

    /// Scroll so the diagram point that was under the anchor at `old` is under
    /// it again at `new`.
    private func follow(from old: CGFloat, to new: CGFloat) {
        guard old > 0, viewport.width > 0, viewport.height > 0 else { return }
        let held = anchor ?? CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let before = placement(old)
        let point = CGPoint(x: (offset.x + held.x - before.x) / old,
                            y: (offset.y + held.y - before.y) / old)
        let after = placement(new), content = contentSize(new)
        let target = CGPoint(
            x: min(max(0, after.x + point.x * new - held.x), max(0, content.width - viewport.width)),
            y: min(max(0, after.y + point.y * new - held.y), max(0, content.height - viewport.height)))
        offset = target
        position.scrollTo(point: target)
        if pinchBase == nil { anchor = nil }
    }
}
