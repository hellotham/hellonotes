//
//  GraphLayout.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import Foundation

/// A deterministic force-directed layout (Fruchterman–Reingold) for the note
/// graph. Deterministic — nodes start on a circle (no randomness) — so the same
/// vault always lays out the same way. O(n² · iterations); fine for the target
/// vault sizes, capped for larger ones by the caller.
nonisolated enum GraphLayout {
    static func positions(
        count: Int,
        edges: [(Int, Int)],
        size: CGSize,
        iterations: Int = 250
    ) -> [CGPoint] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [CGPoint(x: size.width / 2, y: size.height / 2)] }

        let area = Double(size.width) * Double(size.height)
        let k = (area / Double(count)).squareRoot()      // ideal edge length

        // Deterministic initial placement on a circle.
        var pos = (0..<count).map { i -> (x: Double, y: Double) in
            let angle = 2 * Double.pi * Double(i) / Double(count)
            return (Double(size.width) / 2 + cos(angle) * Double(size.width) / 3,
                    Double(size.height) / 2 + sin(angle) * Double(size.height) / 3)
        }

        var temperature = Double(size.width) / 10
        let inset = 24.0

        for _ in 0..<iterations {
            var disp = Array(repeating: (x: 0.0, y: 0.0), count: count)

            // Repulsion between every pair.
            for i in 0..<count {
                for j in (i + 1)..<count {
                    let dx = pos[i].x - pos[j].x
                    let dy = pos[i].y - pos[j].y
                    let dist = max((dx * dx + dy * dy).squareRoot(), 0.01)
                    let force = k * k / dist
                    let ux = dx / dist, uy = dy / dist
                    disp[i].x += ux * force; disp[i].y += uy * force
                    disp[j].x -= ux * force; disp[j].y -= uy * force
                }
            }

            // Attraction along edges.
            for (a, b) in edges where a < count && b < count {
                let dx = pos[a].x - pos[b].x
                let dy = pos[a].y - pos[b].y
                let dist = max((dx * dx + dy * dy).squareRoot(), 0.01)
                let force = dist * dist / k
                let ux = dx / dist, uy = dy / dist
                disp[a].x -= ux * force; disp[a].y -= uy * force
                disp[b].x += ux * force; disp[b].y += uy * force
            }

            // Apply, capped by temperature and clamped into bounds.
            for i in 0..<count {
                let d = max((disp[i].x * disp[i].x + disp[i].y * disp[i].y).squareRoot(), 0.01)
                let capped = min(d, temperature)
                pos[i].x = min(max(pos[i].x + disp[i].x / d * capped, inset), Double(size.width) - inset)
                pos[i].y = min(max(pos[i].y + disp[i].y / d * capped, inset), Double(size.height) - inset)
            }
            temperature = max(temperature * 0.95, 1)
        }

        return pos.map { CGPoint(x: $0.x, y: $0.y) }
    }
}
