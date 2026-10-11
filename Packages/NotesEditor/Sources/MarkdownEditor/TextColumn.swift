//
//  TextColumn.swift
//  MarkdownEditor
//
//  Where the text sits across a pane, worked out by the view that scrolls it.
//
//  A pane's text column — a proportion of the pane, capped by a reading
//  measure — used to be a frame the shell put around the editor: the scroll
//  view was the column's width and sat where the column did. So the scroller
//  sat at the column's edge, not the window's, and a wheel over the margin
//  beside the column scrolled nothing. With the default settings the frame was
//  32pt narrower than the pane, all of it on the right (the shell took a 16pt
//  inset off each side that the text view already adds itself), and that is
//  where the scroller was — the build 28 report.
//
//  So the column is a rule, not a frame. Every view that scrolls text fills
//  its pane and asks the rule where the text goes, at its own width, whenever
//  that width changes: the editor through its text container's inset, the
//  preview through its page's margins, the Markdown pane likewise. The shell
//  publishes the rule (`EnvironmentValues.textColumn`); nothing re-derives it.
//

import SwiftUI

nonisolated public struct TextColumn: Sendable, Equatable {
    /// The column's width as a proportion of the pane, 0…1.
    public var proportion: CGFloat
    /// The widest the column may be, in points — a reading measure — or `nil`
    /// for none.
    public var measure: CGFloat?
    /// Never narrower than this, unless the pane is.
    public var floor: CGFloat

    public init(proportion: CGFloat = 1, measure: CGFloat? = nil, floor: CGFloat = 0) {
        self.proportion = proportion
        self.measure = measure
        self.floor = floor
    }

    /// The whole pane: the text runs edge to edge, inside the view's own inset.
    public static let full = TextColumn()

    /// The column in a pane `width` wide: its distance from the pane's leading
    /// edge and its width.
    ///
    /// The proportion, never below the floor nor wider than the pane, and then
    /// the measure. **Centred only when the measure is what bit**: a column
    /// narrowed by its proportion alone stays at the leading edge — the pane is
    /// the workspace — while one held to a measure sits in the middle of it.
    public func resolve(in width: CGFloat) -> (leading: CGFloat, width: CGFloat, centred: Bool) {
        let available = max(1, width)
        let proportional = min(available, max(floor, available * proportion))
        guard let measure else { return (0, proportional, false) }
        let measured = min(proportional, measure)
        let centred = measured < proportional - 0.5
        return (centred ? ((available - measured) / 2).rounded(.down) : 0, measured, centred)
    }

    /// What lies either side of the column in a pane `width` wide — the room a
    /// view adds to its own text inset, leading and trailing.
    public func margins(in width: CGFloat) -> (leading: CGFloat, trailing: CGFloat) {
        let column = resolve(in: width)
        return (column.leading, max(0, width - column.leading - column.width))
    }
}

private nonisolated struct TextColumnKey: EnvironmentKey {
    static let defaultValue = TextColumn.full
}

public extension EnvironmentValues {
    /// The pane's text column, which every view that scrolls text lays its
    /// text out in. `.full` unless the shell says otherwise.
    nonisolated var textColumn: TextColumn {
        get { self[TextColumnKey.self] }
        set { self[TextColumnKey.self] = newValue }
    }
}

/// Lays its content out in the text column — for chrome that is part of the
/// page, such as the inline title, which has no scroll view of its own to put
/// a margin in. The same rule at the same width as the text below it, so the
/// two start at the same x whatever the setting.
public struct TextColumnLayout: Layout {
    public var column: TextColumn

    public init(_ column: TextColumn) { self.column = column }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = proposal.width ?? child.sizeThatFits(.unspecified).width
        let inner = column.resolve(in: width).width
        let size = child.sizeThatFits(ProposedViewSize(width: inner, height: proposal.height))
        return CGSize(width: width, height: size.height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let resolved = column.resolve(in: bounds.width)
        child.place(at: CGPoint(x: bounds.minX + resolved.leading, y: bounds.minY), anchor: .topLeading,
                    proposal: ProposedViewSize(width: resolved.width, height: bounds.height))
    }
}
