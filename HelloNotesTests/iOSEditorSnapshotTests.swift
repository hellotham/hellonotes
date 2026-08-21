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
import SwiftUI
import MarkdownEditor
@testable import HelloNotes

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

    /// A document exercising the app-side services: a fenced code block
    /// (syntax colours), a GFM table, block `$$…$$` + inline `$…$` math.
    private static let servicesSample = """
    # Services

    ```swift
    func greet(_ name: String) -> String {
        return "Hello, \\(name)!"
    }
    ```

    | Name | Role | Count |
    |:-----|:----:|------:|
    | Ada  | Lead |    12 |
    | Alan | Eng  |     7 |

    Inline math $E = mc^2$ mid-sentence.

    $$
    \\int_0^\\infty e^{-x}\\,dx = 1
    $$

    """

    func testRenderServices() async throws {
        let renderer = BlockRenderAdapter(
            resolve: { _ in nil },
            renderMermaid: { source, isDark in
                MermaidDiagramRenderer.standaloneImage(source: source, isDark: isDark)
            },
            renderMath: { source, isDark in
                await MainActor.run { NoteTranscluder.blockLatexImage(source: source, isDark: isDark) }
            },
            renderTransclusion: { _, _ in nil },
            renderTable: { source, maxWidth, isDark in
                await MainActor.run { TableImageRenderer.image(source: source, maxWidth: maxWidth, isDark: isDark) }
            },
            renderInlineMath: { latex, fontSize, isDark in
                await MainActor.run {
                    let color: PlatformColor = isDark ? PlatformColor(white: 0.9, alpha: 1) : PlatformColor(white: 0.1, alpha: 1)
                    return MathImageRenderer.image(latex: latex, fontSize: fontSize, color: color)
                }
            }
        )
        let services = EditorServices(
            wikiLinkExists: { _ in false },
            codeHighlighter: CodeHighlighterAdapter(darkMode: false),
            blockRenderer: renderer
        )
        let doc = await EditorDocument.make(
            text: Self.servicesSample,
            theme: EditorTheme(fontSize: 17),
            services: services
        )
        let tv = MarkdownUITextView.make(document: doc)
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 620)
        tv.frame = bounds
        tv.isScrollEnabled = false

        let window = UIWindow(frame: bounds)
        window.backgroundColor = .systemBackground
        window.addSubview(tv)
        window.makeKeyAndVisible()

        doc.styleEverythingNow()
        tv.setNeedsLayout()
        tv.layoutIfNeeded()
        // Give the async block-embed renders (table, math, code colours) time to
        // land and restyle before the capture.
        RunLoop.current.run(until: Date().addingTimeInterval(3.0))
        tv.setNeedsLayout()
        tv.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        let image = UIGraphicsImageRenderer(bounds: bounds).image { ctx in
            tv.layer.render(in: ctx.cgContext)
        }
        let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: dir).appendingPathComponent("ios-editor-services.png")
        try image.pngData()?.write(to: url)
        print("SNAPSHOT wrote \(url.path)")
        XCTAssertGreaterThan(image.size.width, 100)
    }

    /// The two settings that used to be Mac-only in practice — and, in the same
    /// capture, proof that a note opened the way a note is actually opened
    /// still draws its chrome.
    ///
    /// The wrap guide had no UIKit implementation at all: it was painted by
    /// `MarkdownTextView.draw`, and UIKit does not call a `UITextView`
    /// subclass's `draw(_:)` over its own text. The accent was worse, because
    /// nothing was missing — `EditorTheme` has taken a cross-platform
    /// `accent: PlatformColor?` since it was written and iOS passed `nil`, so
    /// the chosen accent coloured the Mac's editor and not the iPad's.
    ///
    /// **No `styleEverythingNow()`, deliberately.** Every other snapshot here
    /// calls it, which is exactly why none of them could have caught what
    /// `makeUIView` used to do: style whole documents up to 200KB synchronously
    /// on the main thread at open, because `layoutSubviews` had no
    /// `ensureVisibleRangeStyled` call. That pass is gone; this asserts that
    /// laying the view out is enough on its own — bullets, checkboxes, the
    /// callout band and the heading rules are all overlay-drawn from the
    /// styling pass, so if the viewport were not styled this capture would come
    /// back as plain text.
    func testRenderWrapGuideAndAccent() throws {
        let accent = PlatformColor(red: 0.42, green: 0.31, blue: 0.78, alpha: 1)
        let doc = EditorDocument(text: Self.sample,
                                 theme: EditorTheme(fontSize: 17, accent: accent))
        let tv = MarkdownUITextView.make(document: doc)
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 780)
        tv.frame = bounds
        tv.isScrollEnabled = false
        tv.wrapGuideColumns = 32

        let window = UIWindow(frame: bounds)
        window.backgroundColor = .systemBackground
        window.addSubview(tv)
        window.makeKeyAndVisible()

        tv.setNeedsLayout()
        tv.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        tv.setNeedsLayout()
        tv.layoutIfNeeded()

        // Styled by layout alone: the first heading is bold, which only the
        // styling pass makes it.
        // Read through the view's own storage — the document's is internal to
        // the package, and this is the reference UIKit actually draws from.
        let heading = (tv.textStorage.string as NSString).range(of: "Heading one")
        let font = tv.textStorage.attribute(.font, at: heading.location,
                                            effectiveRange: nil) as? UIFont
        let traits: UIFontDescriptor.SymbolicTraits = font?.fontDescriptor.symbolicTraits ?? []
        XCTAssertTrue(traits.contains(.traitBold),
                      "the viewport is styled without a whole-document pass")

        // The guide has somewhere to be, inside the text area rather than
        // hugging the bezel — the case `wrapGuideX` returns nil for.
        let x = try XCTUnwrap(tv.wrapGuideX)
        XCTAssertGreaterThan(x, tv.textContainerInset.left)
        XCTAssertLessThan(x, bounds.width - 1)

        let image = UIGraphicsImageRenderer(bounds: bounds).image { ctx in
            tv.layer.render(in: ctx.cgContext)
        }
        let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: dir).appendingPathComponent("ios-editor-wrapguide-accent.png")
        try image.pngData()?.write(to: url)
        print("SNAPSHOT wrote \(url.path)")
        XCTAssertGreaterThan(image.size.width, 100)
    }

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
