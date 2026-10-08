//
//  AdaptiveSplit.swift
//  HelloNotes
//
//  Two panes and a rule that drags between them: side by side when there is at
//  least as much width as height, one above the other when not — in **one**
//  container whose layout changes, so the panes are the same views either way.
//
//  Split mode was two branches of an `if` — an `HSplitView` or a `VSplitView`
//  on the Mac, an `HStack` or a `VStack` on iPad — so crossing square made both
//  panes again, the text view holding the caret among them. On an iPad in
//  portrait the keyboard is what crosses it: it takes its height from the pane,
//  the pane is wider than tall, the source's text view was made again without
//  the keyboard, the keyboard went, and the pane was taller again — so it could
//  not be typed in at all. An `AnyLayout` changes how its children are laid out
//  without changing which children they are.
//
//  The rule is the app's own, as `ResizableDivider` is, on both platforms: the
//  `HSplitView` it replaces on the Mac was AppKit's divider, which is also why
//  its swap for a `VSplitView` could not keep the panes.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct AdaptiveSplit<First: View, Second: View>: View {
    private let first: First
    private let second: Second

    /// The first pane's share of the room along the split, as dragged; `nil`
    /// until then, which is half. A share rather than points, so it means the
    /// same thing once the arrangement has changed.
    @State private var share: CGFloat?
    /// The first pane's extent when this drag began, so the gesture is absolute
    /// rather than accumulating rounding.
    @State private var startExtent: CGFloat?

    /// The floors `HSplitView` and `VSplitView` gave each pane: 180pt wide side
    /// by side, 120pt tall stacked. Clamped at use, so a pane too small for two
    /// floors splits what it has.
    static var minimumWidth: CGFloat { 180 }
    static var minimumHeight: CGFloat { 120 }
    /// Wider than the rule: a 1pt target is unhittable with a finger and mean
    /// with a pointer.
    private static var grab: CGFloat { 10 }
    /// The space a drag is measured in: the split's own, which stays where it
    /// is while the rule moves inside it. In the rule's own space — a
    /// `DragGesture`'s default — every step was measured from a rule the last
    /// step had already moved, and it followed a finger at half its speed.
    private static var space: String { "AdaptiveSplit" }

    init(@ViewBuilder first: () -> First, @ViewBuilder second: () -> Second) {
        self.first = first()
        self.second = second()
    }

    /// The arrangement for a pane of `size`, and where the first pane ends in
    /// it for a `share` of the room (`nil` is half) — the one place that
    /// arithmetic lives, for the view and its tests.
    static func arrangement(share: CGFloat?, in size: CGSize) -> (sideBySide: Bool, extent: CGFloat) {
        let sideBySide = size.width >= size.height
        let span = Span(sideBySide: sideBySide, size: size)
        return (sideBySide, span.clamp((share ?? 0.5) * span.room))
    }

    var body: some View {
        GeometryReader { proxy in
            let (sideBySide, extent) = Self.arrangement(share: share, in: proxy.size)
            let span = Span(sideBySide: sideBySide, size: proxy.size)
            let layout = sideBySide
                ? AnyLayout(HStackLayout(spacing: 0))
                : AnyLayout(VStackLayout(spacing: 0))
            layout {
                first
                    .frame(width: sideBySide ? extent : nil, height: sideBySide ? nil : extent)
                rule(span, extent: extent)
                    // Above the second pane, so the half of the grab area that
                    // lies over it is the rule's.
                    .zIndex(1)
                second
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .coordinateSpace(.named(Self.space))
    }

    /// The room along the split and what the first pane may have of it.
    private struct Span {
        let sideBySide: Bool
        /// Everything but the rule.
        let room: CGFloat
        let range: ClosedRange<CGFloat>

        init(sideBySide: Bool, size: CGSize) {
            self.sideBySide = sideBySide
            room = max((sideBySide ? size.width : size.height) - 1, 0)
            let floor = min(sideBySide ? AdaptiveSplit.minimumWidth : AdaptiveSplit.minimumHeight, room / 2)
            range = floor...max(room - floor, floor)
        }

        func clamp(_ extent: CGFloat) -> CGFloat { min(max(extent, range.lowerBound), range.upperBound) }
        func share(of extent: CGFloat) -> CGFloat { room > 0 ? clamp(extent) / room : 0.5 }
    }

    /// The rule, and the grab area over it that drags — one view in either
    /// arrangement, so it keeps its identity too.
    private func rule(_ span: Span, extent: CGFloat) -> some View {
        ChromeDivider(span.sideBySide ? .vertical : .horizontal)
            .overlay {
                Color.clear
                    .frame(width: span.sideBySide ? Self.grab : nil,
                           height: span.sideBySide ? nil : Self.grab)
                    .contentShape(.rect)
                    .gesture(drag(span, from: extent))
                    .splitCursor(sideBySide: span.sideBySide)
                    .accessibilityElement()
                    .accessibilityLabel("Split")
                    .accessibilityValue("\(Int(extent)) points")
                    .accessibilityAdjustableAction { direction in
                        let step: CGFloat = 20
                        share = span.share(of: extent + (direction == .increment ? step : -step))
                    }
            }
    }

    private func drag(_ span: Span, from extent: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let start = startExtent ?? extent
                if startExtent == nil { startExtent = start }
                let moved = span.sideBySide ? value.translation.width : value.translation.height
                share = span.share(of: start + moved)
            }
            .onEnded { _ in startExtent = nil }
    }
}

private extension View {
    /// The pointer says which way the rule drags, where there is a pointer to
    /// say it to — `ResizableDivider`'s cursor, turned on its side when the
    /// panes are stacked. On touch the grab area is the whole affordance.
    func splitCursor(sideBySide: Bool) -> some View {
        #if canImport(AppKit)
        return onHover { inside in
            if inside {
                (sideBySide ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else {
                NSCursor.pop()
            }
        }
        #else
        return self
        #endif
    }
}
