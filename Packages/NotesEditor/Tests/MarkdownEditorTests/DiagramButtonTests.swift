//
//  DiagramButtonTests.swift
//  MarkdownEditorTests
//
//  The diagram button as a view — what a host lays on the Markdown source,
//  where a diagram has no picture to draw the button on. It has to be the
//  button the editor draws, a button to accessibility, and on iPad a press
//  that UIKit's caret tap cannot take first.
//

import CoreGraphics
import Foundation
import Testing
@testable import MarkdownCore
@testable import MarkdownEditor

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@MainActor
@Suite struct DiagramButtonTests {

    #if canImport(AppKit)

    @Test func itIsAButtonNamedByItsHostAndAPressRunsItsAction() {
        let button = DiagramButtonView(label: "View diagram")
        var pressed = 0
        button.onPress = { pressed += 1 }
        #expect(button.frame.size == CGSize(width: DiagramZoomMetrics.side, height: DiagramZoomMetrics.side))
        #expect(button.accessibilityRole() == .button)
        #expect(button.accessibilityLabel() == "View diagram")
        #expect(button.toolTip == "View diagram")
        #expect(button.accessibilityPerformPress())
        #expect(pressed == 1)
    }

    /// The same pixels the editor draws in a diagram's corner: the view is
    /// drawn, and so is `DiagramZoomButton` into a bitmap of the same size, and
    /// the two are compared. The control is an empty view, which must differ.
    @Test func itDrawsWhatTheEditorDrawsInADiagramsCorner() throws {
        let side = Int(DiagramZoomMetrics.side) * 2
        func bitmap(_ draw: (CGContext) -> Void) throws -> [UInt8] {
            let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                                 bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: 0, y: CGFloat(side))
            context.scaleBy(x: 2, y: -2)
            draw(context)
            let data = try #require(context.data)
            return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: side * side * 4))
        }
        func view(_ view: NSView) throws -> [UInt8] {
            try bitmap { context in
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                view.draw(view.bounds)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        let editor = try bitmap { DiagramZoomButton.draw(in: CGRect(x: 0, y: 0, width: DiagramZoomMetrics.side,
                                                                    height: DiagramZoomMetrics.side), context: $0) }
        let button = try view(DiagramButtonView(label: "View diagram"))
        #expect(editor.contains { $0 != 0 }, "the editor's button drew nothing — this test is not comparing anything")
        #expect(button == editor, "the view does not draw the editor's button")
        #expect(try view(NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))) != editor,
                "the control: an empty view should not match")
    }

    #else

    @Test func itIsAButtonNamedByItsHostAndActivatingItPressesIt() {
        let button = DiagramButtonView(label: "View diagram")
        var pressed = 0
        button.onPress = { pressed += 1 }
        #expect(button.isAccessibilityElement && button.accessibilityTraits.contains(.button))
        #expect(button.accessibilityLabel == "View diagram")
        #expect(!button.isUserInteractionEnabled, "a control of its own would lose the tap to UIKit's caret tap")
        #expect(button.accessibilityActivate())
        #expect(pressed == 1)
    }

    /// Claimed at touch-down, pressed on release over the same button — and
    /// nothing else: a touch elsewhere is not claimed, a drag off before release
    /// presses nothing, and a hidden button takes no touches.
    @Test func aTouchOnAButtonIsTakenAtTouchDownAndPressesItOnRelease() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let button = DiagramButtonView(label: "View diagram")
        button.frame = CGRect(x: 300, y: 100, width: DiagramZoomMetrics.side, height: DiagramZoomMetrics.side)
        host.addSubview(button)
        var pressed = 0
        button.onPress = { pressed += 1 }
        let press = DiagramButtonPress(on: host) { [button] }
        let on = CGPoint(x: 312, y: 112), off = CGPoint(x: 50, y: 50)

        #expect(press.recognizer.view === host && press.recognizer.minimumPressDuration == 0)
        #expect(press.recognizer.delegate === press, "the host is UIKit's delegate for its own recognisers")
        #expect(!press.takes(touchAt: off), "a touch off every button is not the press's")

        #expect(press.takes(touchAt: on))
        press.handle(PlacedPress(at: on, state: .ended))
        #expect(pressed == 1)

        #expect(press.takes(touchAt: on))
        press.handle(PlacedPress(at: off, state: .ended))
        #expect(pressed == 1, "dragged off before release, and pressed anyway")
        #expect(press.pending == nil)

        button.isHidden = true
        #expect(!press.takes(touchAt: on), "a hidden button took a touch")
    }

    /// A press that says it is wherever, and in whatever state, the test puts it.
    private final class PlacedPress: UILongPressGestureRecognizer {
        let point: CGPoint
        let placedState: UIGestureRecognizer.State
        init(at point: CGPoint, state: UIGestureRecognizer.State) {
            self.point = point
            self.placedState = state
            super.init(target: nil, action: nil)
        }
        override func location(in view: UIView?) -> CGPoint { point }
        override var state: UIGestureRecognizer.State {
            get { placedState }
            set {}
        }
    }

    #endif
}
