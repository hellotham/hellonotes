//
//  DiagramZoomMetrics.swift
//  MarkdownCore
//
//  The enlarge button on a rendered diagram, measured once for the two
//  renderers that draw it: the editor's layout fragment (`DiagramZoomButton`)
//  and Preview's page (`GFMPage`'s `.hn-zoom`). Here, beside the box model,
//  for the box model's reason — a number written into one side is a number the
//  other side does not know about.
//

import CoreGraphics

public enum DiagramZoomMetrics {
    /// The button's side, in points.
    public static let side: CGFloat = 24
    /// From the diagram's top-right corner to the button's.
    public static let inset: CGFloat = 6
    /// The card's corner radius.
    public static let cornerRadius: CGFloat = 5
    /// The glyph's box, centred in the card.
    public static let glyph: CGFloat = 12
    /// How opaque the card is over the diagram: enough that the glyph reads
    /// over a line or a label passing under it.
    public static let fillOpacity: CGFloat = 0.9
}
