//
//  RuleDragTests.swift
//  HelloNotesTests
//
//  Every rule that drags follows the pointer (docs/implemented.md §51.29): the
//  columns' `ResizableDivider` and History's stacked split, as Split mode's
//  `AdaptiveSplit` does. Each measured its drag in the rule's own coordinates —
//  a `DragGesture`'s default — and each rule moves with the drag, so every step
//  was measured from where the step before had already put it: on screen they
//  followed a finger or a pointer at half its speed.
//
//  Driven by real mouse events through a window with the run loop turned
//  between them, so the layout moves while the drag goes on, as it does on
//  screen. Sent back to back, nothing moved until the button was up, and the
//  half-speed rule passed.
//

import Foundation
import SwiftUI
import Testing
@testable import HelloNotes
#if canImport(AppKit)
import AppKit

@Suite(.serialized) @MainActor
struct RuleDragTests {

    /// The right panel's divider: dragged 200pt towards the editor, the panel
    /// is 200pt wider.
    @Test func thePanelsDividerFollowsThePointer() async throws {
        let size = CGSize(width: 1000, height: 600)
        let window = MouseDrag.host(Column(edge: .trailing), size: size)
        defer { MouseDrag.close(window) }
        await MouseDrag.pump(0.3)
        let start = try MouseDrag.markerFrame(in: window).width
        #expect(abs(start - 300) < 1, "the panel did not start at its width: \(start)")

        await MouseDrag.drag(in: window, from: CGPoint(x: size.width - start - 0.5, y: size.height / 2),
                             by: CGSize(width: -200, height: 0))
        await MouseDrag.pump(0.2)
        let dragged = try MouseDrag.markerFrame(in: window).width
        #expect(abs(dragged - (start + 200)) < 2, "dragging the divider 200pt made the panel \(dragged)")
    }

    /// The sidebar's divider, and the band's and History's: the column is on
    /// the other side, so dragging 200pt away from it makes it 200pt wider.
    @Test func theSidebarsDividerFollowsThePointer() async throws {
        let size = CGSize(width: 1000, height: 600)
        let window = MouseDrag.host(Column(edge: .leading), size: size)
        defer { MouseDrag.close(window) }
        await MouseDrag.pump(0.3)
        let start = try MouseDrag.markerFrame(in: window).width
        #expect(abs(start - 300) < 1, "the column did not start at its width: \(start)")

        await MouseDrag.drag(in: window, from: CGPoint(x: start + 0.5, y: size.height / 2),
                             by: CGSize(width: 200, height: 0))
        await MouseDrag.pump(0.2)
        let dragged = try MouseDrag.markerFrame(in: window).width
        #expect(abs(dragged - (start + 200)) < 2, "dragging the divider 200pt made the column \(dragged)")
    }

    /// History's split when it is too narrow for two columns: the rule lies
    /// flat, and dragging it 200pt down makes the list 200pt taller.
    @Test func theStackedSplitsRuleFollowsThePointer() async throws {
        let size = CGSize(width: 600, height: 1000)
        let split = StackedSplit {
            DragMarkerView()
        } bottom: {
            Color.clear
        }
        let window = MouseDrag.host(split, size: size)
        defer { MouseDrag.close(window) }
        await MouseDrag.pump(0.3)
        let start = try MouseDrag.markerFrame(in: window).height
        #expect(abs(start - 499.5) < 1, "the panes did not start half and half: \(start)")

        await MouseDrag.drag(in: window, from: CGPoint(x: size.width / 2, y: start + 0.5),
                             by: CGSize(width: 0, height: 200))
        await MouseDrag.pump(0.2)
        let dragged = try MouseDrag.markerFrame(in: window).height
        #expect(abs(dragged - (start + 200)) < 2, "dragging the rule 200pt made the top pane \(dragged)")
    }

    /// A column beside a divider, as the shell lays one out: the column is
    /// after the divider for the right panel (`.trailing`) and before it for
    /// the sidebar (`.leading`).
    private struct Column: View {
        let edge: ResizeEdge
        @State private var width: Double = 300

        var body: some View {
            HStack(spacing: 0) {
                switch edge {
                case .trailing:
                    Color.clear
                    ResizableDivider(width: $width, range: 100...700, edge: .trailing)
                    DragMarkerView().frame(width: width)
                case .leading:
                    DragMarkerView().frame(width: width)
                    ResizableDivider(width: $width, range: 100...700, edge: .leading)
                    Color.clear
                }
            }
        }
    }
}

/// A view hosted where the mouse can drag through it, and the drag.
@MainActor
enum MouseDrag {
    /// Hosted in a borderless window ordered in far off any screen: SwiftUI's
    /// gestures take no events in a window that is not ordered in, and a
    /// borderless one is not pulled back onto a screen — so nothing appears
    /// on the display.
    static func host<Content: View>(_ content: Content, size: CGSize) -> NSWindow {
        let hosting = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        return window
    }

    static func close(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    /// A left-button drag through the window, as the mouse makes one: down,
    /// ten moves, up. `point` is from the window's top-left corner.
    ///
    /// The run loop turns between the events, as a real mouse's arrive between
    /// frames, so the layout moves while the drag goes on. Sent back to back,
    /// nothing moved until the button was up — and a rule that measured the
    /// drag in its own coordinates, which move with it, passed while it
    /// followed a real finger at half speed on an iPad.
    static func drag(in window: NSWindow, from point: CGPoint, by delta: CGSize) async {
        let height = window.contentView?.bounds.height ?? 0
        func event(_ type: NSEvent.EventType, _ fraction: CGFloat) -> NSEvent {
            let location = CGPoint(x: point.x + delta.width * fraction,
                                   y: height - (point.y + delta.height * fraction))
            return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        window.sendEvent(event(.leftMouseDown, 0))
        await pump(0.03)
        for step in 1...10 {
            window.sendEvent(event(.leftMouseDragged, CGFloat(step) / 10))
            await pump(0.03)
        }
        window.sendEvent(event(.leftMouseUp, 1))
    }

    static func pump(_ seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
            try? await Task.sleep(for: .milliseconds(1))
        } while Date() < deadline
    }

    /// Where the marked pane is, in the window's coordinates.
    static func markerFrame(in window: NSWindow) throws -> CGRect {
        func search(_ view: NSView) -> DragMarker? {
            if let marker = view as? DragMarker { return marker }
            for sub in view.subviews { if let found = search(sub) { return found } }
            return nil
        }
        let marker = try #require(window.contentView.flatMap(search), "the marked pane is not in the window")
        return marker.convert(marker.bounds, to: nil)
    }
}

/// The pane a test measures, marked so it can be found.
final class DragMarker: NSView {}

struct DragMarkerView: NSViewRepresentable {
    func makeNSView(context: Context) -> DragMarker { DragMarker() }
    func updateNSView(_ nsView: DragMarker, context: Context) {}
}
#endif
