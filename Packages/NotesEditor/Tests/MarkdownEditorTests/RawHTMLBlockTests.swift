//
//  RawHTMLBlockTests.swift
//  MarkdownEditorTests
//
//  CommonMark's block boundaries are not element boundaries, and every test
//  here is a shape where that difference used to show on screen.
//
//  Three answers, and which one a block gets is the whole subject:
//   * **conceal** — the tags are structure the reader never sees, and the
//     Markdown between them lays out unwrapped exactly as the page lays it out;
//   * **render the span** — the wrapper lays its own children out (a `<table>`
//     makes rows and cells), so no amount of hiding tags reproduces the page;
//   * **leave it alone** — the source is what the reader sees.
//

import Foundation
import Testing
@testable import MarkdownEditor
@testable import MarkdownCore
import GFMRender

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@Suite @MainActor struct RawHTMLBlockTests {

    /// Renders every embed to one image, so a collapse can be observed without
    /// WebKit.
    private struct StubRenderer: BlockRenderer {
        let image: PlatformImage
        func render(_ kind: BlockEmbedKind, maxWidth: CGFloat, darkMode: Bool) async -> PlatformImage? {
            image
        }
    }

    /// An image of a given size on both platforms. `NSImage(size:)` has no
    /// `UIImage` counterpart — the smallest honest way to make one there is to
    /// draw nothing into a context of that size — and the existing embed tests
    /// hide the difference behind `#if canImport(AppKit)`, which is how these
    /// compiled on the Mac and failed the iOS build outright.
    private func stub(_ width: CGFloat, _ height: CGFloat) -> PlatformImage {
        let size = CGSize(width: width, height: height)
        #if canImport(AppKit)
        return NSImage(size: size)
        #else
        return UIGraphicsImageRenderer(size: size).image { _ in }
        #endif
    }

    private func styled(_ text: String, caret: Int? = nil) -> EditorDocument {
        let document = EditorDocument(text: text, theme: EditorTheme(fontSize: 16))
        document.styleEverythingNow()
        if let caret { document.selectionDidChange(NSRange(location: caret, length: 0)) }
        return document
    }

    private func isConcealed(_ document: EditorDocument, _ needle: String) -> Bool {
        let loc = (document.storage.string as NSString).range(of: needle).location
        guard loc != NSNotFound else { return false }
        let font = document.storage.attribute(.font, at: loc, effectiveRange: nil) as? PlatformFont
        return font?.pointSize == EditorTheme.concealedSize
    }

    // MARK: - Source the tokenizer eats

    /// `<div id="foo"` never finds its `>`, so the browser consumes the rest of
    /// the block as attribute soup and paints none of it. cmark disagrees — it
    /// passes the lines through as text — and the strict tag grammar agrees
    /// with cmark, which is why two visible-looking lines stood 48pt tall
    /// against a page showing nothing at all (spec #126–#128).
    @Test func sourceTheTokenizerEatsIsConcealed() {
        let document = styled("Above.\n\n<div id=\"foo\"\n*hi*\n\nBelow.", caret: 0)
        #expect(isConcealed(document, "<div id="))
        #expect(isConcealed(document, "*hi*"))
        #expect(!isConcealed(document, "Below."))
    }

    /// …and comes back the moment the caret arrives, like every other
    /// concealment here. Hiding source with no way to reach it is not a
    /// feature, it is a note you cannot edit.
    @Test func andComesBackWhenTheCaretArrives() {
        let text = "Above.\n\n<div id=\"foo\"\n*hi*\n\nBelow."
        let inside = (text as NSString).range(of: "*hi*").location
        let document = styled(text, caret: inside)
        #expect(!isConcealed(document, "<div id="))
        #expect(!isConcealed(document, "*hi*"))
    }

    /// A `<` that no letter follows is not a tag, so nothing after it is eaten.
    @Test func ordinaryProseWithAngleBracketsSurvives() {
        let document = styled("a < b and 3 <4\n", caret: 0)
        #expect(!isConcealed(document, "a < b"))
    }

    // MARK: - Concealed source keeps no styling of its own

    /// The raw-HTML style run used to be applied *over* the concealment: the
    /// line was 0.01pt tall and its glyphs were still painted at full size, so
    /// a hidden `<div class="x">` overprinted the paragraph above it. Every
    /// height was right, which is why only a picture ever showed it.
    @Test func concealedSourceIsNotRepaintedByItsOwnStyleRun() {
        let document = styled("Above.\n\n<div class=\"x\">\n\nBelow.", caret: 0)
        let loc = (document.storage.string as NSString).range(of: "<div class").location
        let colour = document.storage.attribute(.foregroundColor, at: loc,
                                                effectiveRange: nil) as? PlatformColor
        #expect(isConcealed(document, "<div class"))
        #expect(colour == PlatformColor.clear)
    }

    // MARK: - Spans

    /// `<table>` / blank / `<tr>` / … / `</table>` is five HTML blocks with
    /// Markdown between them, and one table on the page. Rendered a block at a
    /// time it is five meaningless fragments; the span is what the page draws.
    @Test func aTableSpanCollapsesAsOnePicture() async throws {
        let text = "Above.\n\n<table>\n\n<tr>\n\n<td>\nHi\n</td>\n\n</tr>\n\n</table>\n\nBelow."
        let document = EditorDocument(
            text: text,
            services: EditorServices(blockRenderer: StubRenderer(image: stub(200, 38))))
        document.selectionDidChange(NSRange(location: 0, length: 0))

        let ns = text as NSString
        let start = ns.range(of: "<table>").location
        var collapsed = false
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            if document.storage.attribute(blockImageAttribute, at: start, effectiveRange: nil) != nil {
                collapsed = true; break
            }
        }
        #expect(collapsed, "the span never collapsed to its picture")
        // …and the whole span went under it, `</table>` included — not just the
        // block that opened it.
        #expect(isConcealed(document, "</table>"))
        #expect(isConcealed(document, "Hi"))
        #expect(!isConcealed(document, "Below."))
    }

    /// Reveal has to be **range**-based. `revealed` is a set of block indices,
    /// and a span is several blocks: opening only the caret's own left
    /// `<table>` and `</table>` concealed around the row being edited.
    @Test func theCaretAnywhereInASpanRevealsAllOfIt() async throws {
        let text = "Above.\n\n<table>\n\n<tr>\n\n<td>\nHi\n</td>\n\n</tr>\n\n</table>\n\nBelow."
        let document = EditorDocument(
            text: text,
            services: EditorServices(blockRenderer: StubRenderer(image: stub(200, 38))))
        document.selectionDidChange(NSRange(location: 0, length: 0))
        let ns = text as NSString
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            if document.storage.attribute(blockImageAttribute, at: ns.range(of: "<table>").location,
                                          effectiveRange: nil) != nil { break }
        }
        // The caret lands four blocks into the span.
        document.selectionDidChange(NSRange(location: ns.range(of: "Hi").location, length: 0))
        #expect(!isConcealed(document, "<table>"))
        #expect(!isConcealed(document, "</table>"))
        #expect(document.storage.attribute(blockImageAttribute,
                                           at: ns.range(of: "<table>").location,
                                           effectiveRange: nil) == nil)
    }

    /// A `<div>` is *structure*: its children lay out exactly as they would
    /// without it, so the concealing path already gives the page's picture —
    /// and keeps the Markdown inside editable as Markdown. Rendering that span
    /// too cost three spec examples to win three others.
    @Test func aPlainWrapperIsConcealedRatherThanRendered() async throws {
        let text = "Above.\n\n<div>\n\n*Emphasized* text.\n\n</div>\n\nBelow."
        let document = EditorDocument(
            text: text,
            services: EditorServices(blockRenderer: StubRenderer(image: stub(200, 40))))
        document.selectionDidChange(NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(200))
        let ns = text as NSString
        #expect(document.storage.attribute(blockImageAttribute, at: ns.range(of: "<div>").location,
                                           effectiveRange: nil) == nil)
        #expect(isConcealed(document, "<div>"))
        // The word, not the `*` — an emphasis marker is concealed everywhere.
        #expect(!isConcealed(document, "Emphasized"))
    }

    /// Collapsing takes the source's chrome with it. A span covers whatever
    /// Markdown sits between the tags, and an indented code block inside one
    /// kept `codeBottomPadAttribute` — a *fragment* margin, not a paragraph
    /// style, so the collapse never touched it and the picture stood 16pt off
    /// the bottom of a box nothing painted.
    @Test func collapsingASpanTakesItsChromeWithIt() async throws {
        // `Below.` is there so the caret has somewhere outside the span to be:
        // a caret inside it reveals it, which is the point of the test above.
        let text = "<table>\n\n  <tr>\n\n    <td>\n      Hi\n    </td>\n\n  </tr>\n\n</table>\n\nBelow."
        let document = EditorDocument(
            text: text,
            services: EditorServices(blockRenderer: StubRenderer(image: stub(200, 92))))
        let ns = text as NSString
        document.selectionDidChange(NSRange(location: ns.range(of: "Below.").location, length: 0))
        let start = ns.range(of: "<table>").location
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            if document.storage.attribute(blockImageAttribute, at: start, effectiveRange: nil) != nil { break }
        }
        // The indented listing's own bottom padding, gone with everything else
        // the styler hung on invisible text.
        let codeLine = document.parse.lines.lineRange(
            document.parse.lines.lineNumber(at: ns.range(of: "    </td>").location)).location
        #expect(document.storage.attribute(codeBottomPadAttribute, at: codeLine,
                                           effectiveRange: nil) == nil)
    }

    // MARK: - Does the page get an element for this block?

    /// The question `.markdown-body > *:last-child` asks. Every kind of block
    /// but raw HTML produces an element; raw HTML produces one unless GitHub's
    /// tag filter escapes the tag that opens it, in which case the browser is
    /// handed `&lt;style …` and makes text of it.
    ///
    /// Asked of the block's **first** tag: `<div><style>` opens a `<div>`, and
    /// what is nested inside it says nothing about whether an element opened.
    @Test func onlyATagFilteredHTMLBlockFailsToProduceAnElement() {
        func producesElement(_ text: String) -> Bool {
            let ns = text as NSString
            let parse = BlockParser.fullParse(ns)
            guard let block = parse.blocks.first(where: { if case .blank = $0.kind { return false }
                                                          return true }) else { return false }
            return BlockBoxes.producesElement(block, text: ns)
        }
        #expect(producesElement("Foo"))
        #expect(producesElement("# Foo"))
        #expect(producesElement("> Foo"))
        #expect(producesElement("    foo"))
        #expect(producesElement("<div>x</div>"))
        #expect(producesElement("<div><style>x</style></div>"))
        #expect(!producesElement("<style>\nx\n"))
        #expect(!producesElement("<title>x</title>"))
        #expect(!producesElement("<script>\nvar a = 1;\n"))
        #expect(!producesElement("<textarea>\nx\n"))
    }

    /// …and the walk built on it. `nextElement` steps over blank lines, over
    /// source the page has nothing for, and over blocks that reach the page as
    /// bare text — so a note ending in one of those leaves the box above it as
    /// the article's last child.
    @Test func nextElementStepsOverEverythingThePageGetsNoElementFor() {
        let text = "Foo\n\n<title>x</title>\n"
        let ns = text as NSString
        let parse = BlockParser.fullParse(ns)
        let unrendered = GFMLiveStyle.unrenderedRanges(ns)
        #expect(BlockBoxes.nextElement(after: 0, in: parse.blocks, text: ns,
                                       unrendered: unrendered) == nil)
        // The same note with a paragraph under it: now there *is* an element
        // below, so the first paragraph is not the last child.
        let withTail = "Foo\n\n<title>x</title>\n\nBar\n"
        let tailNS = withTail as NSString
        let tailParse = BlockParser.fullParse(tailNS)
        #expect(BlockBoxes.nextElement(after: 0, in: tailParse.blocks, text: tailNS,
                                       unrendered: GFMLiveStyle.unrenderedRanges(tailNS)) != nil)
    }

    // MARK: - How tall the collapsed embed is

    /// A block that ends the note is measured by where the page's **ink**
    /// stops; one in the middle is measured by its border box, because the box
    /// is what positions everything after it.
    ///
    /// Dropping the bottom sentinel is not the same thing and only looked like
    /// it: it hands the last *element* back to `:last-child`, which zeroes that
    /// element's own margin and nothing else. A `<tr>` whose cells became an
    /// indented code block leaves an empty `<table>` as the last element, so
    /// the zeroing landed on a box that draws nothing and the listing above it
    /// kept the 16pt between them — a band of blank space under the end of the
    /// note (spec #160, +16.10pt).
    ///
    /// Only the choice is pinned here. A `WKWebView` never finishes loading
    /// under `swift test`, so the numbers themselves are
    /// `scripts/render-parity.sh`'s to prove.
    @Test func anEmbedEndingTheNoteIsMeasuredToItsInkAndNotToItsBorderBox() {
        let ending = OffscreenWebHost.heightScript(keepsTrailingMargin: false)
        let middle = OffscreenWebHost.heightScript(keepsTrailingMargin: true)
        #expect(ending.contains("paintedContentBottom(b)"))
        #expect(!middle.contains("var h = paintedContentBottom(b)"))
        #expect(middle.contains("var h = b.getBoundingClientRect().height"))
        // The sentinel that keeps `:first-child`'s `margin-top: 0` off a block
        // sitting in the middle of a note is on both, and only the trailing one
        // is conditional.
        #expect(ending.contains("var top = pad(), bottom = null"))
        #expect(middle.contains("var top = pad(), bottom = pad()"))
        // …and the rule itself is the shared one, not a second copy of it.
        #expect(ending.contains(PaintedContent.bottomJS))
        #expect(PaintedContent.bottomJS.contains("function paintedContentBottom(b)"))
    }

    /// The flag that decides which of the two a block gets: an HTML span that
    /// ends the note asks for no trailing margin, one with a paragraph under it
    /// asks for its own.
    ///
    /// Read off the renderer the document actually calls, rather than by
    /// widening `blockEmbedKind` to `internal` for a test — what matters is the
    /// kind that reaches a host, and a test that can only see a private
    /// decision cannot tell whether it was ever acted on.
    @Test func onlyASpanEndingTheNoteDropsItsTrailingMargin() async throws {
        func keepsTrailingMargin(_ text: String) async throws -> Bool? {
            let recorder = KindRecorder()
            let document = EditorDocument(
                text: text,
                services: EditorServices(blockRenderer: RecordingRenderer(
                    recorder: recorder, image: stub(200, 92))))
            document.selectionDidChange(NSRange(location: 0, length: 0))
            for _ in 0..<50 {
                try await Task.sleep(for: .milliseconds(20))
                if await recorder.html != nil { break }
            }
            return await recorder.html
        }
        let span = "<table>\n\n  <tr>\n\n    <td>\n      Hi\n    </td>\n\n  </tr>\n\n</table>"
        #expect(try await keepsTrailingMargin(span) == false)
        #expect(try await keepsTrailingMargin(span + "\n\nBelow.") == true)
    }

    /// Remembers the `keepsTrailingMargin` of the first HTML embed it is asked
    /// for. An actor because `BlockRenderer.render` runs off the main one.
    private actor KindRecorder {
        var html: Bool?
        func note(_ kind: BlockEmbedKind) {
            guard case .html(_, let keeps) = kind, html == nil else { return }
            html = keeps
        }
    }

    private struct RecordingRenderer: BlockRenderer {
        let recorder: KindRecorder
        let image: PlatformImage
        func render(_ kind: BlockEmbedKind, maxWidth: CGFloat, darkMode: Bool) async -> PlatformImage? {
            await recorder.note(kind)
            return image
        }
    }
}
