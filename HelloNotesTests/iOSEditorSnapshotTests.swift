//
//  iOSEditorSnapshotTests.swift
//  HelloNotesTests
//
//  Renders the iOS live editor (MarkdownUITextView) offscreen to a PNG so the
//  cross-platform port can be verified visually on the simulator without the
//  file picker. Exercises inline styling, concealment, list bullets, callouts,
//  heading rules and task checkboxes.
//

#if os(iOS)
import XCTest
import UIKit
import MarkdownEditor

@MainActor
final class iOSEditorSnapshotTests: XCTestCase {
    private static let sample = """
    # Heading one
    ## Heading two

    Normal, **bold**, *italic*, `inline code`, ~~strike~~, [link](https://x.com).

    - bullet with **bold** and `code`
      - nested item with *italic*
    1. ordered **one**
    2. ordered *two*

    - [ ] a todo item
    - [x] a done item

    > [!note] A note callout
    > callout body line

    > a blockquote with **bold**

    """

    func testRenderLiveEditor() throws {
        let doc = EditorDocument(text: Self.sample, theme: EditorTheme(fontSize: 17))
        let tv = MarkdownUITextView.make(document: doc)
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 780)
        tv.frame = bounds
        tv.isScrollEnabled = false   // render the whole content

        let window = UIWindow(frame: bounds)
        window.backgroundColor = .systemBackground
        window.addSubview(tv)
        window.makeKeyAndVisible()

        doc.styleEverythingNow()
        // Let TextKit 2 lay out and the chrome overlay draw on the run loop
        // (layoutSubviews → refreshChrome → the overlay's setNeedsDisplay).
        tv.setNeedsLayout()
        tv.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(2.0))

        // Render the already-drawn layer tree (text + overlay). drawHierarchy
        // re-enters TextKit during capture; layer.render just composites layers.
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        let image = renderer.image { ctx in
            tv.layer.render(in: ctx.cgContext)
        }

        // Write the PNG for visual inspection (the styling/concealment/chrome are
        // verified by eye — the shared parser/style-spec are unit-tested already).
        let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: dir).appendingPathComponent("ios-editor.png")
        try image.pngData()?.write(to: url)
        print("SNAPSHOT wrote \(url.path)")
        XCTAssertGreaterThan(image.size.width, 100)
    }
}
#endif
