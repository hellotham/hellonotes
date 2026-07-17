//
//  EditorFidelitySnapshotTests.swift
//  HelloNotesTests
//
//  Renders the *real* live editor (MarkdownTextView + TextKit 2 custom
//  fragments + the production code-highlight and table/math renderers) to a
//  PNG, entirely offscreen inside the app process — no Screen Recording
//  permission required. This is the visual-fidelity check: the emitted PNGs
//  show exactly what the editor draws, so editor↔Preview parity can be
//  inspected by eye and archived as an artifact.
//

#if os(macOS)
import XCTest
import AppKit
import MarkdownEditor
@testable import HelloNotes

@MainActor
final class EditorFidelitySnapshotTests: XCTestCase {

    /// A compact document exercising every construct whose live↔Preview
    /// fidelity was in question: headings (ATX + setext, borders), inline
    /// emphasis, emphasis *inside* a list item / nested item / blockquote,
    /// a fenced code block (syntax colours), and a GFM table (zebra rows).
    private static let sample = """
    # Heading one
    ## Heading two

    Normal, **bold**, *italic*, `inline code`, ~~strike~~, [link](https://x.com).

    - list item with **bold** and `code`
      - nested item with *italic* and a [link](https://y.com)
    1. ordered **one**
    2. ordered *two*

    > blockquote with **bold**, *italic* and `code`
    > > nested quote with **strong**

    ```swift
    struct Point { let x: Int; let y: Int }
    func add(_ a: Int, _ b: Int) -> Int { return a + b }  // sum
    ```

    | Feature | Editor | Preview |
    |:--------|:------:|--------:|
    | Bold    | yes    | yes     |
    | Tables  | zebra  | zebra   |
    | Code    | github | github  |

    """

    /// Synchronous (main-thread) so `RunLoop.current` IS the main run loop —
    /// the async block-embed / syntax-highlight Tasks post their results back
    /// onto the main actor, so we must pump the main run loop to see them.
    private func renderEditor(dark: Bool) throws -> NSImage {
        let services = EditorServices(
            wikiLinkExists: { _ in false },
            codeHighlighter: CodeHighlighterAdapter(darkMode: dark),
            blockRenderer: BlockRenderAdapter(
                resolve: { _ in nil },
                renderTable: { source, maxWidth, isDark in
                    await MainActor.run {
                        TableImageRenderer.image(source: source, maxWidth: maxWidth, fontSize: 15, isDark: isDark)
                    }
                }
            )
        )
        let document = EditorDocument(
            text: Self.sample,
            theme: EditorTheme(fontSize: 15),
            services: services
        )

        let (scrollView, textView) = MarkdownTextView.scrollableEditor(document: document)
        // Tall enough that the ENTIRE sample is inside the scroll viewport —
        // TextKit 2 lays out and draws lazily per-viewport, so anything below
        // the fold would never trigger its async embed (table image) / syntax
        // highlight and would snapshot as raw source. One full-height viewport
        // avoids that.
        let width: CGFloat = 680, height: CGFloat = 1200
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        scrollView.frame = frame

        // A real (offscreen) window so the view has a live graphics context and
        // the right appearance; never ordered on screen.
        let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView?.addSubview(scrollView)
        // The editor draws no background of its own (the host provides it); for
        // the snapshot, paint the GitHub canvas so dark-mode's light text is
        // legible and the cached rep is opaque.
        let canvas = dark ? NSColor(srgbRed: 0x0d/255, green: 0x11/255, blue: 0x17/255, alpha: 1) : .white
        textView.drawsBackground = true
        textView.backgroundColor = canvas
        window.layoutIfNeeded()

        // Drive appearance-dependent rendering directly — the offscreen view's
        // effectiveAppearance doesn't reliably propagate before the async table
        // embed renders, which would otherwise render it in the wrong appearance.
        document.isDarkAppearance = dark
        document.renderMaxWidth = width - 40

        // Style every block, force full-document layout (so the highlighter and
        // table renderer are kicked off for every block, not just the initial
        // viewport), then pump the run loop so those async renders post back and
        // invalidate layout. Re-force layout each cycle to pick up the results.
        // Caret at end of document → every embed/heading block is caret-away,
        // so tables collapse to their image and inline markers conceal.
        let docLen = textView.textStorage?.length ?? 0
        textView.setSelectedRange(NSRange(location: docLen, length: 0))
        document.styleEverythingNow()
        func forceLayout() {
            if let tlm = textView.textLayoutManager {
                tlm.ensureLayout(for: tlm.documentRange)
            }
            textView.layoutSubtreeIfNeeded()
        }
        forceLayout()
        let deadline = Date().addingTimeInterval(6.0)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.15))
            forceLayout()
        }
        textView.display()

        // Assert the async embeds actually composed into the live editor (not
        // just render in isolation): the table source collapsed to its image,
        // and the code block carries GitHub's keyword colour.
        let s = Self.sample as NSString
        let store = try XCTUnwrap(textView.textStorage)
        let tableFont = store.attribute(.font, at: s.range(of: "| Feature").location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(tableFont?.pointSize ?? -1, 0.1, accuracy: 0.001,
                       "table source should collapse (be replaced by the rendered grid image)")
        let kw = try XCTUnwrap((store.attribute(.foregroundColor, at: s.range(of: "struct Point").location,
                                                effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB),
                               "code keyword should be coloured")
        let wantKw = dark ? (r: 1.0, g: 0.48, b: 0.45) : (r: 0.84, g: 0.23, b: 0.29)
        XCTAssertEqual(kw.redComponent,   wantKw.r, accuracy: 0.03, "\(dark ? "dark" : "light") keyword red (GitHub palette)")
        XCTAssertEqual(kw.greenComponent, wantKw.g, accuracy: 0.03, "\(dark ? "dark" : "light") keyword green")
        XCTAssertEqual(kw.blueComponent,  wantKw.b, accuracy: 0.03, "\(dark ? "dark" : "light") keyword blue")

        // Snapshot the text view's full drawn content (opaque canvas baked in).
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        guard let rep = textView.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw XCTSkip("no bitmap rep")
        }
        textView.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)

        window.contentView = nil
        return image
    }

    private func writePNG(_ image: NSImage, _ name: String, dir: String) throws {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("could not encode \(name)"); return
        }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
        try png.write(to: url)
        print("SNAPSHOT wrote \(url.path) (\(png.count) bytes)")
    }

    private var snapshotDir: String {
        ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] ?? NSTemporaryDirectory()
    }

    /// Direct render of the GFM table (the exact image the editor embeds in
    /// place of the table source) — proves the zebra striping / GitHub palette.
    func testTableImageRendersZebraGrid() throws {
        let source = """
        | Feature | Editor | Preview |
        |:--------|:------:|--------:|
        | Bold    | yes    | yes     |
        | Tables  | zebra  | zebra   |
        | Code    | github | github  |
        """
        for dark in [false, true] {
            let image = try XCTUnwrap(
                TableImageRenderer.image(source: source, maxWidth: 600, fontSize: 15, isDark: dark),
                "table image should render")
            XCTAssertGreaterThan(image.size.width, 100)
            XCTAssertGreaterThan(image.size.height, 80)
            try writePNG(image, "table-\(dark ? "dark" : "light").png", dir: snapshotDir)
        }
    }

    /// The code highlighter must colour Swift keywords with GitHub's exact
    /// palette (keyword #d73a49 light / #ff7b72 dark) — the same colours the
    /// Preview's highlight.js GitHub theme uses. Also emits a rendered PNG.
    func testCodeHighlightUsesGitHubPalette() async throws {
        let code = "struct Point { let x: Int }\nfunc add(_ a: Int) -> Int { return a }"
        for (dark, wantKeyword) in [(false, NSColor(srgbRed: 0xd7/255, green: 0x3a/255, blue: 0x49/255, alpha: 1)),
                                    (true,  NSColor(srgbRed: 0xff/255, green: 0x7b/255, blue: 0x72/255, alpha: 1))] {
            let adapter = CodeHighlighterAdapter(darkMode: dark)
            let highlighted = await adapter.highlight(code, language: "swift")
            let styled = try XCTUnwrap(highlighted, "swift code should highlight")
            // Find the colour applied to the "struct" keyword (offset 0).
            var kwColor: NSColor?
            styled.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: 6)) { v, _, _ in
                if let c = v as? NSColor { kwColor = c }
            }
            let got = try XCTUnwrap(kwColor, "keyword should be coloured").usingColorSpace(.sRGB)!
            let want = wantKeyword.usingColorSpace(.sRGB)!
            XCTAssertEqual(got.redComponent,   want.redComponent,   accuracy: 0.02, "\(dark ? "dark" : "light") keyword red")
            XCTAssertEqual(got.greenComponent, want.greenComponent, accuracy: 0.02, "\(dark ? "dark" : "light") keyword green")
            XCTAssertEqual(got.blueComponent,  want.blueComponent,  accuracy: 0.02, "\(dark ? "dark" : "light") keyword blue")

            // Render the highlighted code to a PNG for visual confirmation.
            let inset: CGFloat = 12
            let size = styled.size()
            let image = NSImage(size: NSSize(width: size.width + inset * 2, height: size.height + inset * 2))
            image.lockFocus()
            (dark ? NSColor(srgbRed: 0x0d/255, green: 0x11/255, blue: 0x17/255, alpha: 1)
                  : NSColor.white).setFill()
            NSRect(origin: .zero, size: image.size).fill()
            styled.draw(at: NSPoint(x: inset, y: inset))
            image.unlockFocus()
            try writePNG(image, "code-\(dark ? "dark" : "light").png", dir: snapshotDir)
        }
    }

    /// Whole-editor render smoke test — exercises the full TextKit 2 draw path
    /// (custom fragments: heading rules, list bullets, blockquote bars) and
    /// emits a PNG for inspection. NOTE: the async block embeds (table image,
    /// syntax colours) don't compose reliably in this headless viewport, and
    /// the dark render lacks the host background; the table/code fidelity is
    /// proven directly by `testTableImageRendersZebraGrid` /
    /// `testCodeHighlightUsesGitHubPalette` instead. The *light* composite is
    /// the one to eye for heading/inline/list/blockquote fidelity.
    func testRenderEditorLightAndDark() throws {
        for dark in [false, true] {
            let image = try renderEditor(dark: dark)
            XCTAssertGreaterThan(image.size.width, 100)
            XCTAssertGreaterThan(image.size.height, 100)
            try writePNG(image, "editor-\(dark ? "dark" : "light").png", dir: snapshotDir)
        }
    }
}

#endif
