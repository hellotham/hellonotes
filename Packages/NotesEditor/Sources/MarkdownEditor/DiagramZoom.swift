//
//  DiagramZoom.swift
//  MarkdownEditor
//
//  The enlarge button on a rendered diagram, and what pressing it asks for.
//
//  A ```` ```mermaid ```` fence is drawn inline at the width of the column,
//  which is the right size for reading the note and the wrong one for reading
//  a forty-node flowchart. The host can show a diagram larger; this is the
//  button that asks it to, drawn in the diagram's top-right corner — here by
//  `RenderedBlockFragment` in Edit, and by the page (`GFMPage`'s `.hn-zoom`)
//  in Preview, to the same `DiagramZoomMetrics`.
//
//  **A button, not a click on the diagram.** Clicking a rendered block puts the
//  caret in it and reveals its source, which is how every table, formula and
//  diagram in this editor is edited; a click that zoomed instead would take
//  that away from the diagrams alone. And a press on the button does *not* move
//  the caret, so the diagram stays drawn behind whatever the host shows: the
//  Mac intercepts the click before `NSTextView` sees it, and on iPad a
//  recogniser of its own takes a touch that begins on the button at
//  touch-down and shares it with nothing, which keeps UIKit's caret tap off it
//  (`MarkdownUITextView.handleDiagramZoomPress` says why nothing gentler
//  worked).
//
//  **Drawn only when offered** (`EditorServices.offersDiagramZoom`): a button
//  whose press goes nowhere is worse than no button.
//

import Foundation
import MarkdownCore
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// A request to show one diagram larger.
public nonisolated struct DiagramZoom: Sendable, Equatable {
    /// The diagram's Mermaid source — the fence's body, as the note holds it.
    public var source: String
    /// Where the diagram's fence is in the document, when the editor asks.
    /// Preview has a page rather than offsets and leaves it nil. It is what
    /// tells two identical diagrams apart.
    public var location: Int?

    public init(source: String, location: Int? = nil) {
        self.source = source
        self.location = location
    }
}

/// Custom attribute (`DiagramZoomMark`) across a collapsed diagram's source:
/// the fragment that draws the picture draws its enlarge button, and a press on
/// the button reads the diagram from here. Set by `EditorDocument.collapse`
/// only when the host offers the zoom; wiped with everything else on restyle.
nonisolated let diagramZoomAttribute = NSAttributedString.Key("hn.diagramZoom")

/// What `diagramZoomAttribute` holds: the diagram's source.
///
/// An object, not the string itself, because attribute runs whose values are
/// equal merge — and two identical diagrams written one under the other would
/// then be one run, and a press on the second button would find the first
/// diagram. An `NSObject` is equal only to itself.
nonisolated final class DiagramZoomMark: NSObject {
    let source: String
    init(source: String) { self.source = source }
}

/// Where the enlarge button sits on a diagram and what it looks like — one
/// place, used to draw it and to hit it.
nonisolated enum DiagramZoomButton {
    /// How far past its edges a touch still counts: a fingertip is not a
    /// pointer, and 24pt is below the 44pt a touch target wants.
    static let touchSlop: CGFloat = 10

    /// The SF Symbol drawn on it.
    static let symbol = "arrow.up.left.and.arrow.down.right"

    /// The button on a diagram drawn in `picture`: its top-right corner, inset.
    /// Never left of the picture, so a narrow diagram keeps it over itself.
    static func frame(in picture: CGRect) -> CGRect {
        let side = DiagramZoomMetrics.side, inset = DiagramZoomMetrics.inset
        return CGRect(x: max(picture.minX, picture.maxX - inset - side),
                      y: picture.minY + inset, width: side, height: side)
    }

    /// A card over the diagram with the glyph centred in it — the same inks
    /// the page's `.hn-zoom` uses: the page at `fillOpacity`, the rule colour,
    /// the muted text colour.
    static func draw(in rect: CGRect, context: CGContext) {
        let radius = DiagramZoomMetrics.cornerRadius
        let card = CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                          cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        context.addPath(card)
        context.setFillColor(PlatformColor.diagramZoomFill.cgColor)
        context.fillPath()
        context.addPath(card)
        context.setStrokeColor(PlatformColor.editorSeparator.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.restoreGState()

        // Rendered at twice the size it is drawn, so a Retina screen gets a
        // sharp glyph rather than a 1x bitmap stretched.
        let side = DiagramZoomMetrics.glyph
        guard let glyph = PlatformDraw.symbol(symbol, pointSize: side * 2,
                                              color: .diagramZoomGlyph),
              glyph.width > 0, glyph.height > 0 else { return }
        let aspect = CGFloat(glyph.width) / CGFloat(glyph.height)
        let size = aspect >= 1 ? CGSize(width: side, height: side / aspect)
                               : CGSize(width: side * aspect, height: side)
        PlatformDraw.image(glyph, in: CGRect(x: rect.midX - size.width / 2,
                                             y: rect.midY - size.height / 2,
                                             width: size.width, height: size.height),
                           context: context)
    }
}

extension PlatformColor {
    /// The page, `DiagramZoomMetrics.fillOpacity` opaque.
    nonisolated static var diagramZoomFill: PlatformColor {
        .gfm { palette in
            var ink = palette.canvas
            ink.alpha = Double(DiagramZoomMetrics.fillOpacity)
            return ink
        }
    }
    /// `--fgColor-muted`: the glyph is chrome, not content.
    nonisolated static var diagramZoomGlyph: PlatformColor { .gfm(\.muted) }
}

extension NSTextLayoutManager {
    /// The diagram whose enlarge button is at `point`, in text-container
    /// coordinates, or nil.
    ///
    /// The fragment under the point is rarely the one that draws: a diagram's
    /// picture is painted by the fragment holding `blockImageAttribute` — the
    /// fence's first line, or its last where the band had to be made of the
    /// line box — and it hangs below that line over the others. So the point
    /// finds the block (the mark spans all of it), the block finds its
    /// painter, and the painter says where it put the button.
    func diagramZoom(at point: CGPoint, in storage: NSTextStorage,
                     slop: CGFloat = 0) -> DiagramZoom? {
        guard let content = textContentManager,
              let under = textLayoutFragment(for: point)
                ?? textLayoutFragment(for: CGPoint(x: 0, y: point.y))
        else { return nil }
        let offset = content.offset(from: content.documentRange.location,
                                    to: under.rangeInElement.location)
        guard offset >= 0, offset < storage.length else { return nil }
        // The point first, and the run only on a diagram. This runs on every
        // click and every touch in the editor, and almost none are on a
        // diagram: asked for the longest run of an attribute that is absent,
        // `longestEffectiveRange` walks every attribute run in the note — a
        // millisecond or more a click on a long one. Present, the mark is an
        // object equal only to itself, so the walk stays inside its diagram.
        guard storage.attribute(diagramZoomAttribute, at: offset, effectiveRange: nil)
                is DiagramZoomMark else { return nil }
        var run = NSRange(location: 0, length: 0)
        guard let mark = storage.attribute(diagramZoomAttribute, at: offset,
                                           longestEffectiveRange: &run,
                                           in: NSRange(location: 0, length: storage.length))
                as? DiagramZoomMark else { return nil }
        var painterOffset: Int?
        storage.enumerateAttribute(blockImageAttribute, in: run, options: []) { value, range, stop in
            if value != nil { painterOffset = range.location; stop.pointee = true }
        }
        guard let painterOffset,
              let location = content.location(content.documentRange.location, offsetBy: painterOffset),
              let painter = textLayoutFragment(for: location) as? RenderedBlockFragment,
              let button = painter.diagramZoomButtonFrame(),
              button.insetBy(dx: -slop, dy: -slop).contains(point)
        else { return nil }
        return DiagramZoom(source: mark.source, location: run.location)
    }
}
