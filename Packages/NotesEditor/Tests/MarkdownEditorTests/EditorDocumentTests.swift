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
#if canImport(AppKit)
import AppKit
#endif
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

    /// A callout header's `> [!type]` prefix collapses to the concealed font
    /// (so the title starts at the block indent, aligned with the body) when
    /// the caret is elsewhere, and reveals when the caret is inside.
    @Test func calloutHeaderPrefixConceals() {
        let text = "# Callouts\n\n> [!note] A note callout\n> Body line one.\n\nEnd.\n"
        let document = EditorDocument(text: text)
        document.selectionDidChange(NSRange(location: 0, length: 0)) // caret away
        let ns = document.storage
        let s = text as NSString
        let prefixLoc = s.range(of: "> [!note] ").location

        // Whole `> [!note] ` prefix is concealed → near-zero rendered width.
        for off in 0..<10 {
            let f = ns.attribute(.font, at: prefixLoc + off, effectiveRange: nil) as? PlatformFont
            #expect(f?.pointSize == 0.1, "prefix char \(off) not concealed")
        }
        let prefixWidth = ns.attributedSubstring(from: NSRange(location: prefixLoc, length: 10)).size().width
        #expect(prefixWidth < 2, "concealed prefix should collapse, got \(prefixWidth)")

        // Caret inside the header reveals the prefix.
        document.selectionDidChange(NSRange(location: prefixLoc + 3, length: 0))
        let revealed = ns.attribute(.font, at: prefixLoc, effectiveRange: nil) as? PlatformFont
        #expect(revealed?.pointSize != 0.1)
    }

    #if canImport(AppKit)
    /// Reproduce the LIVE TextKit 2 layout (not NSAttributedString.size) and
    /// assert the header title lands at the same x as the body — i.e. the
    /// concealed prefix truly collapses under real layout.
    @Test func calloutTitleAlignsWithBodyUnderTextKit2() {
        let text = "# Callouts\n\n> [!note] A note callout\n> Body line one.\n\nEnd.\n"
        let document = EditorDocument(text: text)
        document.selectionDidChange(NSRange(location: 0, length: 0))
        let s = text as NSString

        // Reproduce the live view's binding order: set the default font
        // BEFORE attaching the styled storage, so it can't clobber the
        // per-run concealed fonts.
        let tv = NSTextView(usingTextLayoutManager: true)
        tv.font = document.theme.body
        (tv.textLayoutManager?.textContentManager as? NSTextContentStorage)?.textStorage = document.storage
        let layout = tv.textLayoutManager!
        let content = layout.textContentManager as! NSTextContentStorage
        layout.textContainer?.lineFragmentPadding = 5
        layout.textContainer?.size = CGSize(width: 600, height: 1e6)
        layout.ensureLayout(for: layout.documentRange)

        func x(ofCharAt loc: Int) -> CGFloat {
            guard let pos = content.location(content.documentRange.location, offsetBy: loc),
                  let frag = layout.textLayoutFragment(for: pos) else { return -1 }
            for line in frag.textLineFragments {
                let r = line.characterRange
                let start = content.offset(from: content.documentRange.location, to: frag.rangeInElement.location) + r.location
                if loc >= start && loc < start + r.length {
                    let cg = line.locationForCharacter(at: loc - start)
                    return frag.layoutFragmentFrame.origin.x + line.typographicBounds.origin.x + cg.x
                }
            }
            return frag.layoutFragmentFrame.origin.x
        }

        let titleX = x(ofCharAt: s.range(of: "A note callout").location)
        let bodyX = x(ofCharAt: s.range(of: "Body line one").location)
        print("TextKit2 titleX=\(titleX) bodyX=\(bodyX)")
        #expect(abs(titleX - bodyX) < 4, "title x \(titleX) should align with body x \(bodyX)")
    }
    #endif

    #if canImport(AppKit)
    /// Front matter folds (raw YAML concealed to near-zero height) when the
    /// caret is elsewhere, and reveals for direct editing when the caret is
    /// inside. Source stays byte-pure throughout.
    @Test func frontMatterFoldsWhenCaretAway() {
        let text = "---\ntitle: Hello\ntags: a, b\ndraft: true\n---\n\n# Body\n\ntext"
        let document = EditorDocument(text: text)
        let ns = document.storage
        let yamlLoc = (text as NSString).range(of: "title:").location

        // Caret in the body → front matter folded (concealed).
        document.selectionDidChange(NSRange(location: (text as NSString).range(of: "text").location, length: 0))
        #expect((ns.attribute(.font, at: yamlLoc, effectiveRange: nil) as? PlatformFont)?.pointSize == 0.1)
        #expect(ns.attribute(.foregroundColor, at: yamlLoc, effectiveRange: nil) as? PlatformColor == .clear)

        // Caret inside front matter → revealed (real font, not concealed).
        document.selectionDidChange(NSRange(location: yamlLoc, length: 0))
        #expect((ns.attribute(.font, at: yamlLoc, effectiveRange: nil) as? PlatformFont)?.pointSize != 0.1)
        #expect(document.text == text)
    }
    #endif

    #if canImport(AppKit)
    /// Toggling a callout's fold conceals/reveals its body, marks the header
    /// with the fold state, keeps the source byte-pure, and survives an edit
    /// above it (offset remap).
    @Test func calloutFoldTogglesBody() {
        let text = "# H\n\n> [!note] Title\n> Body one.\n> Body two.\n\nEnd."
        let document = EditorDocument(text: text)
        document.selectionDidChange(NSRange(location: (text as NSString).range(of: "End.").location, length: 0))
        let ns = document.storage
        let headerLoc = (text as NSString).range(of: "> [!note] Title").location
        let bodyLoc = (text as NSString).range(of: "Body one").location

        // Expanded by default: body visible, chevron shows "not folded".
        #expect((ns.attribute(.font, at: bodyLoc, effectiveRange: nil) as? PlatformFont)?.pointSize != 0.1)
        #expect(ns.attribute(calloutFoldAttribute, at: headerLoc, effectiveRange: nil) as? Bool == false)

        // Fold → body concealed.
        _ = document.toggleCalloutFold(atHeaderOffset: headerLoc)
        #expect(ns.attribute(calloutFoldAttribute, at: headerLoc, effectiveRange: nil) as? Bool == true)
        #expect((ns.attribute(.font, at: bodyLoc, effectiveRange: nil) as? PlatformFont)?.pointSize == 0.1)
        #expect(document.text == text)   // byte-pure

        // An edit *above* the callout keeps the fold (offset remaps).
        document.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "X")
        let newBodyLoc = (document.text as NSString).range(of: "Body one").location
        #expect((ns.attribute(.font, at: newBodyLoc, effectiveRange: nil) as? PlatformFont)?.pointSize == 0.1)

        // Unfold → body visible again.
        let newHeaderLoc = (document.text as NSString).range(of: "> [!note] Title").location
        _ = document.toggleCalloutFold(atHeaderOffset: newHeaderLoc)
        #expect((ns.attribute(.font, at: newBodyLoc, effectiveRange: nil) as? PlatformFont)?.pointSize != 0.1)
    }
    #endif

    #if canImport(AppKit)
    @Test func setextHeadingRendersLarge() {
        let text = "###### H6 heading\n\nSetext H1\n=========\n\nSetext H2\n---------\n\nBody text here."
        let document = EditorDocument(text: text)
        document.selectionDidChange(NSRange(location: (text as NSString).range(of: "Body").location, length: 0))
        let ns = document.storage
        let s = text as NSString
        for (label, needle) in [("h1", "Setext H1"), ("h2", "Setext H2")] {
            let loc = s.range(of: needle).location
            let f = ns.attribute(.font, at: loc, effectiveRange: nil) as? PlatformFont
            print("setext \(label) font=\(f?.pointSize ?? -1)")
        }
        let bodyFont = ns.attribute(.font, at: s.range(of: "Body").location, effectiveRange: nil) as? PlatformFont
        let h1Font = ns.attribute(.font, at: s.range(of: "Setext H1").location, effectiveRange: nil) as? PlatformFont
        print("body=\(bodyFont?.pointSize ?? -1)")
        #expect((h1Font?.pointSize ?? 0) > (bodyFont?.pointSize ?? 0), "setext H1 should be larger than body")

        // Now measure the REAL TextKit 2 laid-out line height (live-fidelity),
        // reproducing the view's bind order.
        let tv = NSTextView(usingTextLayoutManager: true)
        tv.font = document.theme.body
        (tv.textLayoutManager?.textContentManager as? NSTextContentStorage)?.textStorage = document.storage
        let layout = tv.textLayoutManager!
        layout.textContainer?.size = CGSize(width: 600, height: 1e6)
        layout.ensureLayout(for: layout.documentRange)
        func lineHeight(atCharAt loc: Int) -> CGFloat {
            let cm = layout.textContentManager!
            guard let pos = cm.location(cm.documentRange.location, offsetBy: loc),
                  let frag = layout.textLayoutFragment(for: pos) else { return -1 }
            return frag.textLineFragments.first?.typographicBounds.height ?? -1
        }
        let h1H = lineHeight(atCharAt: s.range(of: "Setext H1").location)
        let atxH = lineHeight(atCharAt: s.range(of: "H6 heading").location)
        let bodyH = lineHeight(atCharAt: s.range(of: "Body").location)
        print("laidout heights — setextH1=\(h1H) atxH6=\(atxH) body=\(bodyH)")
    }
    #endif

    #if canImport(AppKit)
    @Test func checkedTaskHasNoStrikethrough() {
        let text = "- [ ] Unchecked task\n- [x] Checked task\n- [x] ~~real strike~~ here"
        let document = EditorDocument(text: text)
        document.selectionDidChange(NSRange(location: 0, length: 0))
        let ns = document.storage
        let s = text as NSString
        let checkedLoc = s.range(of: "Checked task").location
        let strike = ns.attribute(.strikethroughStyle, at: checkedLoc, effectiveRange: nil)
        print("checked-task strikethrough attr = \(String(describing: strike))")
        #expect(strike == nil, "checked task text must not be struck through (GitHub parity)")
    }
    #endif

    #if canImport(AppKit)
    @Test func unorderedListDrawsBullets() {
        let text = "- First\n- Second\n  - Nested\n1. One\n- [ ] Task\n\nBody paragraph."
        let document = EditorDocument(text: text)
        document.selectionDidChange(NSRange(location: (text as NSString).range(of: "Body").location, length: 0))
        let ns = document.storage
        let s = text as NSString

        // Unordered `-` → concealed (clear) + bullet attribute (depth 0).
        let firstDash = s.range(of: "- First").location
        #expect(ns.attribute(.foregroundColor, at: firstDash, effectiveRange: nil) as? PlatformColor == .clear)
        #expect(ns.attribute(listBulletAttribute, at: firstDash, effectiveRange: nil) as? Int == 0)

        // Nested `-` → depth 1.
        let nestedDash = s.range(of: "- Nested").location
        #expect(ns.attribute(listBulletAttribute, at: nestedDash, effectiveRange: nil) as? Int == 1)

        // Ordered `1.` keeps its number (no bullet attribute).
        let one = s.range(of: "1. One").location
        #expect(ns.attribute(listBulletAttribute, at: one, effectiveRange: nil) == nil)

        // Task `-` → concealed, no bullet (checkbox is the visual).
        let taskDash = s.range(of: "- [ ] Task").location
        #expect(ns.attribute(listBulletAttribute, at: taskDash, effectiveRange: nil) == nil)
        #expect((ns.attribute(.font, at: taskDash, effectiveRange: nil) as? PlatformFont)?.pointSize == 0.1)

        // Source stays byte-pure.
        #expect(document.text == text)
    }

    @Test func plainBlockquoteGetsBarAndConcealsMarker() {
        let text = "> A quote line.\n> continues.\n\nBody."
        let document = EditorDocument(text: text)
        document.selectionDidChange(NSRange(location: (text as NSString).range(of: "Body").location, length: 0))
        let ns = document.storage
        let s = text as NSString
        let quoteStart = s.range(of: "> A quote").location

        // Neutral bar tint + depth (1) set on the block; `>` concealed.
        #expect(ns.attribute(calloutTintAttribute, at: quoteStart, effectiveRange: nil) != nil)
        #expect(ns.attribute(blockquotePlainAttribute, at: quoteStart, effectiveRange: nil) as? Int == 1)
        #expect((ns.attribute(.font, at: quoteStart, effectiveRange: nil) as? PlatformFont)?.pointSize == 0.1)
        #expect(document.text == text)
    }
    #endif

    #if canImport(AppKit)
    @Test func gfmLiveStyleRunsFromCmark() {
        let text = "# Heading\n\nA **bold**, *it*, `code`, [link](https://x.com).\n" as NSString
        let runs = GFMLiveStyle.runs(text)
        func run(_ role: String, contains needle: String) -> Bool {
            runs.contains { r in
                let s = text.substring(with: r.range)
                return "\(r.role)".hasPrefix(role) && s == needle
            }
        }
        // Heading: `# ` concealed marker, "Heading" is heading text.
        #expect(run("headingText", contains: "Heading"))
        #expect(runs.contains { text.substring(with: $0.range) == "# " && "\($0.role)" == "marker" && $0.concealment == .whenInactive })
        // Emphasis delimiters + content.
        #expect(run("strong", contains: "bold"))
        #expect(run("emphasis", contains: "it"))
        #expect(run("inlineCode", contains: "code"))
        // Link label coloured, `[` and `](url)` concealed.
        #expect(run("linkText", contains: "link"))
        #expect(runs.contains { text.substring(with: $0.range) == "[" && "\($0.role)" == "marker" })
        #expect(runs.contains { text.substring(with: $0.range).hasPrefix("](") && "\($0.role)" == "marker" })
    }
    #endif

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
