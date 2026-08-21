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
#elseif canImport(UIKit)
import UIKit
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

    /// Code and maths must be exempt from spell checking. Beyond the noise,
    /// a collapsed block's misspelling underline is drawn by the spell checker
    /// and not scaled by the 0.1pt concealment font, so it survived as a red
    /// dash above every rendered formula.
    @Test func sourceOnlyRangesAreExemptFromSpellChecking() {
        let text = """
        Prose with a delibrate typo.

        $$
        \\int_0^\\infty e^{-x^2}\\,dx
        $$

        ```swift
        let x = 1
        ```

            indented code

        More prose.
        """
        let document = EditorDocument(text: text)
        let ns = text as NSString
        func at(_ needle: String) -> NSRange { ns.range(of: needle) }

        #expect(document.isSourceOnly(at("\\int_0")))
        #expect(document.isSourceOnly(at("let x = 1")))
        #expect(document.isSourceOnly(at("indented code")))
        #expect(!document.isSourceOnly(at("delibrate")))
        #expect(!document.isSourceOnly(at("More prose")))
    }

    /// The VoiceOver headings rotor's walk. Both platform views used to carry
    /// their own copy of this and neither honoured the rotor's search field.
    @Test func rotorHeadingWalksAndHonoursTheSearchField() {
        let text = "# Alpha\n\nbody\n\n## Beta\n\nmore\n\n### Gamma\n"
        let document = EditorDocument(text: text)
        let ns = text as NSString
        let alpha = ns.range(of: "# Alpha").location
        let gamma = ns.range(of: "### Gamma").location

        // No current item: start from whichever end the direction implies.
        #expect(document.rotorHeading(after: nil, forward: true)?.title == "Alpha")
        #expect(document.rotorHeading(after: nil, forward: false)?.title == "Gamma")

        // Stepping, and stopping at the ends rather than wrapping.
        #expect(document.rotorHeading(after: alpha, forward: true)?.title == "Beta")
        #expect(document.rotorHeading(after: gamma, forward: false)?.title == "Beta")
        #expect(document.rotorHeading(after: gamma, forward: true) == nil)
        #expect(document.rotorHeading(after: alpha, forward: false) == nil)

        // The search field narrows the walk, case-insensitively.
        #expect(document.rotorHeading(after: nil, forward: true, matching: "gam")?.title == "Gamma")
        #expect(document.rotorHeading(after: alpha, forward: true, matching: "alp") == nil)
        #expect(document.rotorHeading(after: nil, forward: true, matching: "zzz") == nil)
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

    /// The cmark-gfm overlay must reach inline constructs *inside* list items and
    /// blockquotes — not just top-level paragraphs — so the live editor matches
    /// the Preview there. Proven end-to-end through a real EditorDocument: the
    /// `**bold**` word inside a nested list item and inside a blockquote gets a
    /// bold font, and its `**` delimiters conceal.
    @Test func cmarkOverlayStylesListAndBlockquoteInline() {
        let text = "- item with **bold** word\n  - nested **strong** item\n\n> quote with **bold** word\n\nBody."
        let document = EditorDocument(text: text)
        document.selectionDidChange(NSRange(location: (text as NSString).range(of: "Body").location, length: 0))
        let ns = document.storage
        let s = text as NSString

        func isBold(at loc: Int) -> Bool {
            guard let f = ns.attribute(.font, at: loc, effectiveRange: nil) as? PlatformFont else { return false }
            return f.fontDescriptor.symbolicTraits.contains(.bold)
        }
        func isConcealed(at loc: Int) -> Bool {
            (ns.attribute(.font, at: loc, effectiveRange: nil) as? PlatformFont)?.pointSize == 0.1
                || ns.attribute(.foregroundColor, at: loc, effectiveRange: nil) as? PlatformColor == .clear
        }

        // Top-level list item: "bold" bold, surrounding "**" concealed.
        let listBold = s.range(of: "bold** word").location
        #expect(isBold(at: listBold), "bold text in a list item should be bold")
        #expect(isConcealed(at: listBold - 2), "the `**` before bold in a list item should conceal")

        // Nested list item (this is the block that previously misrendered as
        // indented code when parsed in isolation): "strong" bold.
        let nestedBold = s.range(of: "strong** item").location
        #expect(isBold(at: nestedBold), "bold text in a nested list item should be bold")

        // Blockquote: "bold" bold too.
        let quoteBold = s.range(of: "bold** word", options: .backwards).location
        #expect(isBold(at: quoteBold), "bold text in a blockquote should be bold")

        // Nested item must NOT be monospaced (the isolation-bug regression).
        let nestedFont = ns.attribute(.font, at: nestedBold, effectiveRange: nil) as? PlatformFont
        #expect(nestedFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) != true,
                "nested list item must not render as monospaced code")

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

    #if canImport(AppKit)
    /// The live editor's GFM styling comes from cmark-gfm, so it must handle the
    /// CommonMark emphasis edge cases the simplified parser can get wrong.
    @Test func gfmLiveStyleEmphasisConformance() {
        func content(_ md: String, role: String) -> [String] {
            let ns = md as NSString
            return GFMLiveStyle.runs(ns).compactMap { r in
                "\(r.role)" == role ? ns.substring(with: r.range) : nil
            }
        }
        // Nested strong-in-emph and emph-in-strong.
        #expect(content("*foo**bar**baz*", role: "strong") == ["bar"])
        #expect(content("**foo*bar*baz**", role: "emphasis") == ["bar"])
        // Intraword emphasis with `*` works; with `_` it does not (CommonMark).
        #expect(content("foo*bar*baz", role: "emphasis") == ["bar"])
        #expect(content("foo_bar_baz", role: "emphasis") == [])
        // A space after the opener means it is NOT emphasis.
        #expect(content("a * foo bar*", role: "emphasis") == [])
        // `***x***` is strong+emph (both cover the inner `x`; cmark reports the
        // two levels with overlapping ranges, so the inner delimiter isn't
        // perfectly split — the important thing is it renders bold+italic).
        #expect(content("***x***", role: "strong").first?.contains("x") == true)
        #expect(content("***x***", role: "emphasis").first?.contains("x") == true)
        // Strikethrough and code coexist.
        #expect(content("~~a~~ and `b`", role: "strikethrough") == ["a"])
        #expect(content("~~a~~ and `b`", role: "inlineCode") == ["b"])
    }
    #endif

    // MARK: - Code highlighting

    private struct MockHighlighter: CodeHighlighting {
        func highlight(_ code: String, language: String) async -> [CodeColorRun] {
            guard language == "swift" else { return [] }
            let range = (code as NSString).range(of: "let")
            guard range.location != NSNotFound else { return [] }
            return [CodeColorRun(range: range, color: .systemPink)]
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
    // Block embeds render to a PlatformImage and collapse the source, and
    // that whole path is `#if canImport(AppKit)` in EditorDocument — the iOS
    // view still shows the Markdown source (docs/unimplemented.md §6). The
    // tests follow the feature.
    #if canImport(AppKit)

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

    // MARK: - Multi-line block embeds
    //
    // `StubBlockRenderer` above declines `.math`, so every embed test before
    // these used a *single-line* `![[pic.png]]` paragraph — which is exactly
    // why two multi-line collapse bugs shipped. A `$$…$$` block is three
    // newline-delimited paragraphs, and both defects only appear past one.

    private struct EveryKindRenderer: BlockRenderer {
        let image: PlatformImage
        func render(_ kind: BlockEmbedKind, maxWidth: CGFloat, darkMode: Bool) async -> PlatformImage? { image }
    }

    /// Collapse a `$$…$$` block and hand back the document plus its range.
    private func collapsedMathDocument(
        imageHeight: CGFloat
    ) async throws -> (document: EditorDocument, block: NSRange) {
        let text = "Intro:\n\n$$\n\\int_0^1 x\\,dx = \\frac{1}{2}\n$$\n\nAfter."
        let img = PlatformImage(size: CGSize(width: 300, height: imageHeight))
        let document = EditorDocument(
            text: text,
            services: EditorServices(blockRenderer: EveryKindRenderer(image: img))
        )
        document.selectionDidChange(NSRange(location: 0, length: 0))

        let start = (text as NSString).range(of: "$$").location
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            if document.storage.attribute(blockImageAttribute, at: start, effectiveRange: nil) != nil { break }
        }
        #expect(document.storage.attribute(blockImageAttribute, at: start, effectiveRange: nil) != nil)
        #expect(document.text == text)   // byte fidelity survives the collapse

        let block = try #require(document.blocks.first {
            if case .mathBlock = $0.kind { return true }
            return false
        }).range
        return (document, block)
    }

    /// `paragraphSpacing` applies at the end of *every* paragraph, so setting
    /// it across a multi-line block reserved the image band once per line —
    /// three bands for a one-line formula, ~90pt of dead space beneath it.
    @Test func multiLineBlockEmbedReservesItsImageBandExactlyOnce() async throws {
        let imageHeight: CGFloat = 44
        let (document, block) = try await collapsedMathDocument(imageHeight: imageHeight)

        // Assert the *paragraph* semantics, not the attribute-run count: a
        // single run spanning the whole block still reserves one band per
        // newline it covers, which is the bug. The band-bearing range must
        // therefore be one paragraph — no interior newline.
        var banded: [(NSRange, CGFloat)] = []
        document.storage.enumerateAttribute(.paragraphStyle, in: block, options: []) { value, range, _ in
            if let spacing = (value as? NSParagraphStyle)?.paragraphSpacing, spacing > 0 {
                banded.append((range, spacing))
            }
        }
        #expect(banded.count == 1)
        let (range, spacing) = try #require(banded.first)
        #expect(spacing == imageHeight + 2 * RenderedBlockFragment.imageGap)

        let ns = document.storage.string as NSString
        var interior = range
        if interior.length > 0, ns.character(at: interior.location + interior.length - 1) == 0x0A {
            interior.length -= 1        // a trailing newline terminates this paragraph
        }
        let newline = ns.rangeOfCharacter(from: CharacterSet.newlines, options: [], range: interior)
        #expect(newline.location == NSNotFound,
                "the image band spans \(banded[0].0) — it is reserved once per newline inside it")
    }

    /// The block's trailing newline used to fall outside the concealed range,
    /// so it kept the 15pt body font and laid out as a full-height empty line
    /// directly under the rendered formula.
    @Test func multiLineBlockEmbedConcealsItsTrailingNewline() async throws {
        let (document, block) = try await collapsedMathDocument(imageHeight: 44)

        var visible: [String] = []
        let ns = document.storage.string as NSString
        document.storage.enumerateAttributes(in: block, options: []) { attrs, range, _ in
            let size = (attrs[.font] as? PlatformFont)?.pointSize ?? 0
            var alpha: CGFloat = 0
            #if canImport(AppKit)
            alpha = (attrs[.foregroundColor] as? PlatformColor)?
                .usingColorSpace(.deviceRGB)?.alphaComponent ?? 0
            #endif
            if size > 1, alpha > 0.01 {
                visible.append(ns.substring(with: range).replacingOccurrences(of: "\n", with: "\\n"))
            }
        }
        #expect(visible.isEmpty, "unconcealed characters in a collapsed block: \(visible)")
    }

    /// Deliberately slower than the block render, so its colors land *after*
    /// the collapse. The repaint is a race between two async services; left to
    /// chance the highlight usually wins and the bug hides.
    private struct SlowEverythingHighlighter: CodeHighlighting {
        func highlight(_ code: String, language: String) async -> [CodeColorRun] {
            try? await Task.sleep(for: .milliseconds(150))
            return [CodeColorRun(range: NSRange(location: 0, length: (code as NSString).length), color: .systemPink)]
        }
    }

    /// A Mermaid fence is both a highlightable code block and a rendered
    /// embed. Highlighting runs async, so its colors landed *after* the
    /// collapse and repainted the concealed 0.1pt source — coloured specks
    /// scattered under the diagram.
    @Test func collapsedMermaidSourceIsNotRepaintedByTheHighlighter() async throws {
        let text = "Chart:\n\n```mermaid\ngraph LR\n  A --> B\n```\n\nAfter."
        let img = PlatformImage(size: CGSize(width: 300, height: 60))
        let document = EditorDocument(
            text: text,
            services: EditorServices(
                codeHighlighter: SlowEverythingHighlighter(),
                blockRenderer: EveryKindRenderer(image: img)
            )
        )
        document.selectionDidChange(NSRange(location: 0, length: 0))

        let start = (text as NSString).range(of: "```mermaid").location
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            if document.storage.attribute(blockImageAttribute, at: start, effectiveRange: nil) != nil { break }
        }
        // Let the (deliberately slow) highlight land on top of the collapse.
        try await Task.sleep(for: .milliseconds(400))

        let block = try #require(document.blocks.first {
            if case .fencedCode = $0.kind { return true }
            return false
        }).range
        var pink = 0
        document.storage.enumerateAttribute(.foregroundColor, in: block, options: []) { value, range, _ in
            if let color = value as? PlatformColor, color == .systemPink { pink += range.length }
        }
        #expect(pink == 0, "highlighter repainted \(pink) concealed characters")
    }
    #endif

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
            // This single keystroke races the multi-second background styling
            // pass on a 3.8 MB note — the worst possible moment. It measures
            // ~28–30 ms, so budget a little headroom to keep the boundary from
            // flaking; steady-state keystrokes (below) stay well under a frame.
            #expect(earlyMS < 36, "keystroke during styling pass took \(earlyMS) ms")
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
