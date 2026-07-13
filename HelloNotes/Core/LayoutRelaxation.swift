//
//  LayoutRelaxation.swift
//  HelloNotes
//
//  Created by Chris Tham on 13/7/2026.
//

import Foundation
import CoreGraphics

/// A deterministic collision-avoidance pass for laid-out nodes: treats each
/// node as an axis-aligned rectangle (its visual footprint — chip, or orb plus
/// label) and iteratively pushes overlapping pairs apart along the axis that
/// needs the smaller correction. Used by the graph and mind-map layouts after
/// their structural pass, so nodes never sit on top of each other.
/// `nonisolated` — pure geometry, callable from any actor.
nonisolated enum LayoutRelaxation {

    /// Separate overlapping rectangles centred on `centers`.
    ///
    /// - Parameters:
    ///   - centers: Node centres, updated in place. Order defines the (stable)
    ///     pair-visit order, so results are deterministic.
    ///   - sizes: The visual footprint of each node.
    ///   - padding: Minimum breathing room to keep between footprints.
    ///   - fixed: Indices that must not move (e.g. the mind map's root); when
    ///     a pair contains a fixed node, the other node takes the full push.
    ///   - iterations: Upper bound on relaxation sweeps (stops early once
    ///     nothing overlaps).
    static func separate(
        centers: inout [CGPoint],
        sizes: [CGSize],
        padding: CGFloat = 6,
        fixed: Set<Int> = [],
        iterations: Int = 80
    ) {
        guard centers.count == sizes.count, centers.count > 1 else { return }

        for _ in 0..<iterations {
            var anyMoved = false

            for i in 0..<centers.count {
                for j in (i + 1)..<centers.count {
                    let iFixed = fixed.contains(i)
                    let jFixed = fixed.contains(j)
                    if iFixed && jFixed { continue }

                    // Overlap of the padded footprints along each axis.
                    let halfW = (sizes[i].width + sizes[j].width) / 2 + padding
                    let halfH = (sizes[i].height + sizes[j].height) / 2 + padding
                    let dx = centers[j].x - centers[i].x
                    let dy = centers[j].y - centers[i].y
                    let overlapX = halfW - abs(dx)
                    let overlapY = halfH - abs(dy)
                    guard overlapX > 0, overlapY > 0 else { continue }
                    anyMoved = true

                    // Shares of the push: a fixed node passes its share on.
                    let shareI: CGFloat = iFixed ? 0 : (jFixed ? 1 : 0.5)
                    let shareJ: CGFloat = jFixed ? 0 : (iFixed ? 1 : 0.5)

                    // Push along the axis needing the smaller correction.
                    if overlapX < overlapY {
                        let dir: CGFloat = dx >= 0 ? 1 : -1
                        centers[i].x -= overlapX * shareI * dir
                        centers[j].x += overlapX * shareJ * dir
                    } else {
                        let dir: CGFloat = dy >= 0 ? 1 : -1
                        centers[i].y -= overlapY * shareI * dir
                        centers[j].y += overlapY * shareJ * dir
                    }
                }
            }

            if !anyMoved { break }
        }
    }

    /// Shift `centers` so every footprint (plus `margin`) has positive
    /// coordinates, and return the world size that contains them all.
    static func rebase(
        centers: inout [CGPoint],
        sizes: [CGSize],
        margin: CGFloat
    ) -> CGSize {
        guard !centers.isEmpty, centers.count == sizes.count else { return .zero }

        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for (center, size) in zip(centers, sizes) {
            minX = min(minX, center.x - size.width / 2)
            minY = min(minY, center.y - size.height / 2)
            maxX = max(maxX, center.x + size.width / 2)
            maxY = max(maxY, center.y + size.height / 2)
        }

        let dx = margin - minX
        let dy = margin - minY
        for i in centers.indices {
            centers[i].x += dx
            centers[i].y += dy
        }
        return CGSize(width: maxX - minX + margin * 2,
                      height: maxY - minY + margin * 2)
    }

    /// A rough footprint for a single-line text chip/label without touching
    /// the text system: average glyph width scales with the font size
    /// (slightly generous, so under-estimates don't reintroduce overlaps).
    static func estimatedTextWidth(_ text: String, fontSize: CGFloat, maxWidth: CGFloat) -> CGFloat {
        min(CGFloat(text.count) * fontSize * 0.66, maxWidth)
    }
}
