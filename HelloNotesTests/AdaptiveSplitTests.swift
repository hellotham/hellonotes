//
//  AdaptiveSplitTests.swift
//  HelloNotesTests
//
//  What Split mode's panes keep from the `HSplitView` and `VSplitView` they
//  were on the Mac (docs/implemented.md §51.29): a rule that drags, and a floor
//  under each pane — 180pt wide side by side, 120pt tall stacked. The
//  arrangement is the pane's shape: side by side at square and wider.
//

import Foundation
import SwiftUI
import Testing
@testable import HelloNotes
#if canImport(AppKit)
import AppKit
#endif

@Suite(.serialized) @MainActor
struct AdaptiveSplitTests {

    private typealias Split = AdaptiveSplit<Color, Color>

    // MARK: - The arithmetic

    @Test func sideBySideFromSquareStackedBelowIt() {
        #expect(Split.arrangement(share: nil, in: CGSize(width: 500, height: 500)).sideBySide)
        #expect(Split.arrangement(share: nil, in: CGSize(width: 900, height: 600)).sideBySide)
        #expect(!Split.arrangement(share: nil, in: CGSize(width: 600, height: 900)).sideBySide)
    }

    /// Half until dragged, then the share dragged to, never below a pane's
    /// floor — along whichever axis the split runs. The rule's point is not
    /// either pane's.
    @Test func eachPaneKeepsTheFloorItsSplitViewGaveIt() {
        let wide = CGSize(width: 1000, height: 600), tall = CGSize(width: 600, height: 1000)
        #expect(Split.arrangement(share: nil, in: wide).extent == 499.5)
        #expect(Split.arrangement(share: 0.01, in: wide).extent == 180)
        #expect(Split.arrangement(share: 0.99, in: wide).extent == 819)   // 999 of room, less a 180 floor
        #expect(Split.arrangement(share: nil, in: tall).extent == 499.5)
        #expect(Split.arrangement(share: 0.01, in: tall).extent == 120)
        #expect(Split.arrangement(share: 0.99, in: tall).extent == 879)   // less a 120 floor
        // Too small for two floors: the room is shared rather than overdrawn.
        #expect(Split.arrangement(share: 0.9, in: CGSize(width: 301, height: 200)).extent == 150)
    }

    #if canImport(AppKit)
    // MARK: - The rule drags

    /// Dragged with the mouse, the rule moves the first pane's edge by as much
    /// as the mouse moved, and stops at each pane's floor — what the
    /// `HSplitView`'s divider did. Driven by real mouse events through the
    /// window (`MouseDrag`, in RuleDragTests.swift), so the gesture's wiring is
    /// what is tested, not the arithmetic.
    @Test func theRuleDragsAndStopsAtEachPanesFloor() async throws {
        let size = CGSize(width: 1000, height: 600)
        let split = AdaptiveSplit {
            DragMarkerView()
        } second: {
            Color.clear
        }
        let window = MouseDrag.host(split, size: size)
        defer { MouseDrag.close(window) }
        await MouseDrag.pump(0.3)
        let start = try firstPaneWidth(in: window)
        #expect(abs(start - 499.5) < 1, "the panes did not start half and half: \(start)")

        await drag(in: window, fromX: start + 0.5, by: 200)
        let dragged = try firstPaneWidth(in: window)
        #expect(abs(dragged - (start + 200)) < 2, "dragging the rule 200pt moved the edge to \(dragged)")

        await drag(in: window, fromX: dragged + 0.5, by: -2000)
        #expect(abs(try firstPaneWidth(in: window) - 180) < 1, "the first pane went below its floor")

        await drag(in: window, fromX: 180.5, by: 2000)
        #expect(abs(try firstPaneWidth(in: window) - 819) < 1, "the second pane went below its floor")
    }

    private func firstPaneWidth(in window: NSWindow) throws -> CGFloat {
        try MouseDrag.markerFrame(in: window).width
    }

    /// Across the middle of the window, then time for the panes to settle.
    private func drag(in window: NSWindow, fromX x: CGFloat, by dx: CGFloat) async {
        let middle = (window.contentView?.bounds.height ?? 0) / 2
        await MouseDrag.drag(in: window, from: CGPoint(x: x, y: middle), by: CGSize(width: dx, height: 0))
        await MouseDrag.pump(0.2)
    }
    #endif
}
