//
//  ResizableDivider.swift
//  HelloNotes
//
//  Created by Chris Tham on 18/9/2026.
//
//  A divider you can drag, so a panel is the width you want it.
//
//  `shell-chrome.md` D7 has said "an `HStack` sibling of the editor inside the
//  detail column, **with a draggable splitter**" since the inspector was
//  designed. The HStack was there; the splitter never was, so every panel in
//  this app was whatever number the shell had written down — 280pt of inspector
//  beside a graph that wanted 760.
//
//  The width belongs to the person, so it is stored (`@AppStorage`) and clamped
//  at *use*: dragging a panel wide and then narrowing the window does not lose
//  the width you chose, it only stops the editor being squeezed below its floor.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Which side of the divider the panel being resized is on.
enum ResizeEdge {
    /// The panel is to the *right* of the divider — the inspector. Dragging
    /// left widens it.
    case trailing
    /// The panel is to the *left* — the band's container pane. Dragging right
    /// widens it.
    case leading
}

struct ResizableDivider: View {
    /// The panel's width, in points. Stored by the caller.
    @Binding var width: Double
    /// What the width may be here: the panel's floor, up to whatever leaves the
    /// editor its own.
    let range: ClosedRange<CGFloat>
    var edge: ResizeEdge = .trailing

    /// The width when this drag began, so the gesture is absolute rather than
    /// accumulating rounding.
    @State private var startWidth: CGFloat?

    /// Wider than the line: a 1pt target is unhittable with a finger and mean
    /// with a pointer.
    private static let grabWidth: CGFloat = 10

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: Self.grabWidth)
                    .contentShape(.rect)
                    .gesture(drag)
                    .resizeCursor()
                    .accessibilityElement()
                    .accessibilityLabel("Panel width")
                    .accessibilityValue("\(Int(width)) points")
                    .accessibilityAdjustableAction { direction in
                        let step: CGFloat = 20
                        let next = CGFloat(width) + (direction == .increment ? step : -step)
                        width = Double(min(max(next, range.lowerBound), range.upperBound))
                    }
            }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = startWidth ?? CGFloat(width)
                if startWidth == nil { startWidth = start }
                let delta = edge == .trailing ? -value.translation.width : value.translation.width
                width = Double(min(max(start + delta, range.lowerBound), range.upperBound))
            }
            .onEnded { _ in startWidth = nil }
    }
}

private extension View {
    /// The pointer says "you can drag this" where there is a pointer to say it
    /// to. On touch the 10pt target is the whole affordance.
    func resizeCursor() -> some View {
        #if canImport(AppKit)
        return onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        #else
        return self
        #endif
    }
}
