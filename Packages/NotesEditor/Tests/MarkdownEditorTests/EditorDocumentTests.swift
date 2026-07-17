//
//  EditorDocumentTests.swift
//  MarkdownEditorTests
//
//  End-to-end tests of the editing pipeline — everything except AppKit
//  layout/drawing: open (parse + style), keystroke (storage edit →
//  incremental reparse → restyle), caret reveal, undo, and the byte-
//  fidelity invariant (styling never mutates characters).
//

import Foundation
import Testing
@testable import MarkdownEditor
@testable import MarkdownCore

@MainActor
@Suite struct EditorDocumentTests {

    private static var isOptimizedBuild: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    /// Markdown the size of the vault's largest note (3.8 MB).
    private static func hugeDocument() -> String {
        var doc = "---\ntitle: Huge\n---\n"
        let chunk = """
        # Chapter heading

        A paragraph with **bold**, *italic*, `code`, a [[Wiki Link]] and a #tag \
        plus longer prose to make the line realistic for a book-length note.

        - item with [[Other Note|alias]]
        - [ ] a task
        > A quote with ==highlight==.

        ```python
        def f(): return 42
        ```

        """
        while doc.utf8.count < 3_800_000 { doc += chunk }
        return doc
    }

    // MARK: - Fidelity

    @Test func stylingNeverMutatesCharacters() {
        let text = """
        ---
        title: Test
        ---
        # Heading
        Para with **bold**, [[Link|alias]], `code`, $x$, %%c%%, #tag.
        > [!note] callout
        - [x] done
        | a | b |
        |---|---|
        ```swift
        let s = "**not styled**"
        ```
        """
        let document = EditorDocument(text: text)
        #expect(document.text == text)
    }

    @Test func typingUpdatesParseAndKeepsTextExact() {
        let document = EditorDocument(text: "# Title\n\nBody")
        document.storage.replaceCharacters(in: NSRange(location: 13, length: 0), with: " more")
        #expect(document.text == "# Title\n\nBody more")
        #expect(document.blocks.count == 3)
        // The parse must equal a from-scratch reparse after the edit.
        let full = BlockParser.fullParse(document.text as NSString)
        #expect(document.blocks == full.blocks)
    }

    @Test func editNotificationsFire() {
        let document = EditorDocument(text: "hello")
        var edits: [TextEdit] = []
        document.onEdit = { edits.append($0) }
        document.storage.replaceCharacters(in: NSRange(location: 5, length: 0), with: " world")
        #expect(edits.count == 1)
        #expect(edits.first?.newRange == NSRange(location: 5, length: 6))
        #expect(document.revision == 1)
    }

    @Test func headingsQuery() {
        let document = EditorDocument(text: "# One\n\ntext\n\n## Two\n\nSetext\n===")
        let headings = document.headings()
        #expect(headings.map(\.title) == ["One", "Two", "Setext"])
        #expect(headings.map(\.level) == [1, 2, 1])
    }

    @Test func revealFollowsSelection() {
        let text = "# Heading\n\npara with **bold** text"
        let document = EditorDocument(text: text)
        let ns = document.storage

        // Caret outside the paragraph: markers concealed (clear color).
        document.selectionDidChange(NSRange(location: 0, length: 0))
        let markerAt = (text as NSString).range(of: "**").location
        var attrs = ns.attributes(at: markerAt, effectiveRange: nil)
        #expect((attrs[.font] as? PlatformFont)?.pointSize == 0.1)

        // Caret inside the paragraph: markers revealed.
        document.selectionDidChange(NSRange(location: markerAt + 3, length: 0))
        attrs = ns.attributes(at: markerAt, effectiveRange: nil)
        #expect((attrs[.font] as? PlatformFont)?.pointSize != 0.1)
    }

    // MARK: - Code highlighting

    private struct MockHighlighter: CodeHighlighting {
        func highlight(_ code: String, language: String) async -> NSAttributedString? {
            guard language == "swift" else { return nil }
            let styled = NSMutableAttributedString(string: code)
            if let range = (code as NSString).range(of: "let") as NSRange?, range.location != NSNotFound {
                styled.addAttribute(.foregroundColor, value: PlatformColor.systemPink, range: range)
            }
            return styled
        }
    }

    @Test func codeBlockGetsHighlightColors() async throws {
        let text = "# Title\n\n```swift\nlet x = 1\n```\n\ntail"
        let document = EditorDocument(
            text: text,
            services: EditorServices(codeHighlighter: MockHighlighter())
        )
        // The async highlight lands after a hop; poll briefly.
        let letLocation = (text as NSString).range(of: "let").location
        var color: PlatformColor?
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            color = document.storage.attribute(.foregroundColor, at: letLocation, effectiveRange: nil) as? PlatformColor
            if color == .systemPink { break }
        }
        #expect(color == .systemPink)

        // A caret-reveal restyle wipes and must re-apply synchronously from
        // the document's color cache — no flash.
        document.selectionDidChange(NSRange(location: letLocation, length: 0))
        let after = document.storage.attribute(.foregroundColor, at: letLocation, effectiveRange: nil) as? PlatformColor
        #expect(after == .systemPink)

        // Text is untouched by highlighting.
        #expect(document.text == text)
    }

    // MARK: - Block embeds

    private struct StubBlockRenderer: BlockRenderer {
        let image: PlatformImage
        func render(_ kind: BlockEmbedKind, maxWidth: CGFloat, darkMode: Bool) async -> PlatformImage? {
            if case .math = kind { return nil }
            return image
        }
    }

    @Test func standaloneImageEmbedCollapsesAndRenders() async throws {
        let text = "# H\n\n![[pic.png]]\n\nafter"
        let img = PlatformImage(size: CGSize(width: 100, height: 40))
        let document = EditorDocument(
            text: text,
            services: EditorServices(blockRenderer: StubBlockRenderer(image: img))
        )
        // Move the caret away from the embed so it collapses.
        document.selectionDidChange(NSRange(location: 0, length: 0))

        let embedLoc = (text as NSString).range(of: "![[").location
        var collapsed = false
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            if document.storage.attribute(blockImageAttribute, at: embedLoc, effectiveRange: nil) != nil {
                collapsed = true; break
            }
        }
        #expect(collapsed)
        // Source stays in storage, byte-for-byte.
        #expect(document.text == text)

        // Caret entering the embed reveals the source (image attribute cleared).
        document.selectionDidChange(NSRange(location: embedLoc + 2, length: 0))
        #expect(document.storage.attribute(blockImageAttribute, at: embedLoc, effectiveRange: nil) == nil)
    }

    @Test func nonStandaloneImageEmbedIsNotRendered() async throws {
        // An embed with surrounding text on the same line is inline, not a block.
        let text = "see ![[pic.png]] here"
        let img = PlatformImage(size: CGSize(width: 100, height: 40))
        let document = EditorDocument(
            text: text,
            services: EditorServices(blockRenderer: StubBlockRenderer(image: img))
        )
        document.selectionDidChange(NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(120))
        let embedLoc = (text as NSString).range(of: "![[").location
        #expect(document.storage.attribute(blockImageAttribute, at: embedLoc, effectiveRange: nil) == nil)
    }

    // MARK: - Latency at the p99-note scale

    @Test func hugeNotePipelineLatency() async {
        let text = Self.hugeDocument()

        var t0 = DispatchTime.now()
        let document = await EditorDocument.make(text: text)
        let openMS = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        #expect(document.text == text)   // fidelity at scale

        // Typing immediately after open (styling pass still pending) must
        // already be responsive.
        let early = NSRange(location: document.storage.length / 3, length: 0)
        t0 = DispatchTime.now()
        document.storage.replaceCharacters(in: early, with: "x")
        let earlyMS = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        document.storage.replaceCharacters(in: NSRange(location: early.location, length: 1), with: "")

        // Steady state: everything styled (background pass completed).
        t0 = DispatchTime.now()
        document.styleEverythingNow()
        let styleAllMS = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6

        // Keystrokes in the middle of the document — the full cycle the
        // user feels: storage edit → reparse → restyle.
        let mid = document.storage.length / 2
        var worst = 0.0, total = 0.0
        var parseWorst = 0.0, restyleWorst = 0.0
        let keystrokes = 60
        for i in 0..<keystrokes {
            t0 = DispatchTime.now()
            document.storage.replaceCharacters(in: NSRange(location: mid + i, length: 0), with: "x")
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
            if ms >= worst {
                print("  keystroke \(i): total \(String(format: "%.2f", ms)) ms — parse \(String(format: "%.2f", document.lastEditMetrics.parseMS)), restyle \(String(format: "%.2f", document.lastEditMetrics.restyleMS))")
            }
            worst = max(worst, ms); total += ms
            parseWorst = max(parseWorst, document.lastEditMetrics.parseMS)
            restyleWorst = max(restyleWorst, document.lastEditMetrics.restyleMS)
        }
        print("  phase worsts — parse \(String(format: "%.2f", parseWorst)) ms, restyle \(String(format: "%.2f", restyleWorst)) ms")

        // Caret movement across blocks — reveal flip cost.
        var caretWorst = 0.0
        for i in 0..<200 {
            t0 = DispatchTime.now()
            document.selectionDidChange(NSRange(location: (mid + i * 97) % document.storage.length, length: 0))
            caretWorst = max(caretWorst, Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6)
        }

        print("""
        3.8MB pipeline — open: \(String(format: "%.0f", openMS)) ms, \
        early keystroke \(String(format: "%.2f", earlyMS)) ms, \
        style-all \(String(format: "%.0f", styleAllMS)) ms, \
        keystroke avg \(String(format: "%.2f", total / Double(keystrokes))) ms \
        worst \(String(format: "%.2f", worst)) ms, \
        caret-move worst \(String(format: "%.2f", caretWorst)) ms
        """)
        if Self.isOptimizedBuild {
            #expect(openMS < 150, "open took \(openMS) ms on 3.8 MB")
            #expect(earlyMS < 30, "keystroke during styling pass took \(earlyMS) ms")
            // Steady state on the 3.8 MB pathological note runs ~6 ms — the
            // parse tail-shift is O(blocks) there. Still sub-frame at 60 Hz.
            #expect(worst < 12, "keystroke cycle took \(worst) ms on 3.8 MB")
            // Far caret jumps pay an attribute-run seek in NSTextStorage;
            // adjacent moves (arrow keys) are far cheaper. Budget one 120 Hz
            // frame for the worst random jump.
            #expect(caretWorst < 12, "caret reveal took \(caretWorst) ms on 3.8 MB")
        }
    }
}
