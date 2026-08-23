//
//  DocumentShapeTests.swift
//  MarkdownEditorTests
//
//  The defects a *document* has and a construct does not.
//
//  Every one of these was found by `RenderParity --docs`, which lays whole
//  notes out in both engines, and none of them could have been found by the
//  672-example specification corpus: each needs two constructs standing next to
//  each other, and several need a pane narrow enough for something to wrap.
//  The corpus was green to a hundredth of a point throughout.
//

import Testing
import Foundation
import MarkdownCore
@testable import MarkdownEditor

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@Suite @MainActor struct DocumentShapeTests {

    private var metrics: GFMBoxMetrics { GFMBoxMetrics(base: 16) }

    private func styled(_ text: String) -> EditorDocument {
        let document = EditorDocument(text: text, theme: EditorTheme(fontSize: 16))
        document.styleEverythingNow()
        return document
    }

    private func style(_ text: String, at needle: String) -> NSParagraphStyle? {
        let document = styled(text)
        let loc = (text as NSString).range(of: needle).location
        guard loc != NSNotFound else { return nil }
        return document.storage.attribute(.paragraphStyle, at: loc,
                                          effectiveRange: nil) as? NSParagraphStyle
    }

    private func font(_ text: String, at needle: String) -> PlatformFont? {
        let document = styled(text)
        let loc = (text as NSString).range(of: needle).location
        guard loc != NSNotFound else { return nil }
        return document.storage.attribute(.font, at: loc, effectiveRange: nil) as? PlatformFont
    }

    // MARK: - Front matter

    /// Preview strips front matter before cmark sees a byte of it, so the page
    /// has no element for it at all. The editor's fold cleared the glyphs and
    /// left their line boxes standing: a note opening with nine lines of
    /// properties stood 240pt taller than its own preview, and what the reader
    /// saw was a blank band where the title should have been.
    @Test func frontMatterIsSourceTheReaderNeverSees() {
        let text = "---\ntitle: T\nstatus: draft\n---\n\n# Heading\n\nBody."
        for line in ["---\ntitle", "title: T", "status: draft"] {
            #expect(style(text, at: line)?.maximumLineHeight == BlockBoxes.collapsedLine)
        }
        // …and the heading below it is the document's **first** box, so
        // `.markdown-body > *:first-child` takes its top margin away.
        #expect(style(text, at: "# Heading")?.maximumLineHeight
                == metrics.headingLineHeight(1))
        #expect(font(text, at: "title: T")?.pointSize == EditorTheme.concealedSize)
    }

    // MARK: - Code that is too wide for its column

    /// GitHub gives `pre` `overflow: auto` and lets a long line run off the side
    /// of a fixed column. TextKit has no equivalent — a text view's container
    /// tracks the pane — so the editor wraps and always has, and the same note
    /// was two documents: every code line over about eighty characters one line
    /// tall in Preview and two in Edit.
    ///
    /// `pre > code` has to be named as well as `pre`: `white-space` inherits,
    /// but github-markdown-css declares `white-space: pre` on the `<code>`
    /// itself, and an inherited value never beats a declared one.
    @Test func thePageWrapsALongCodeLineRatherThanScrollingIt() {
        let css = metrics.css
        #expect(css.contains("white-space: pre-wrap"))
        #expect(css.contains("overflow-wrap: break-word"))
        #expect(css.contains(".markdown-body pre, .markdown-body pre > code"))
    }

    // MARK: - Raw HTML that lays out its own children

    /// A closed `<details>` does not merely lay its children out differently —
    /// it does not draw them at all. Concealing the tags and styling the
    /// Markdown between them showed the reader a paragraph the page hides.
    @Test func detailsLaysOutItsOwnChildren() {
        #expect(HTMLBlockShape.laysOutItsChildren.contains("details"))
        // `summary` is not listed: it only ever appears *inside* a `details`,
        // and a span is decided by its outermost tag.
        #expect(!HTMLBlockShape.laysOutItsChildren.contains("summary"))
    }

    /// A block's assets resolve under the note's own folder, and never above
    /// it. `..` and a leading `/` are dropped rather than honoured — one would
    /// read its way out of the folder and the other would send the request to
    /// the filesystem root.
    @Test func aBlockAssetResolvesUnderTheNotesFolder() {
        let root = URL(fileURLWithPath: "/vault/notes", isDirectory: true)
        #expect(BlockAssetScheme.resolve("/pic.png", under: root).path == "/vault/notes/pic.png")
        #expect(BlockAssetScheme.resolve("a/b.png", under: root).path == "/vault/notes/a/b.png")
        #expect(BlockAssetScheme.resolve("../../etc/passwd", under: root).path
                == "/vault/notes/etc/passwd")
        #expect(BlockAssetScheme.resolve("my%20pic.png", under: root).path
                == "/vault/notes/my pic.png")
    }

    // MARK: - A table under a list item's text

    /// GFM confirms a table only on its delimiter row, so the header is the
    /// line above and the item has to be closed *before* it. Without the split
    /// the editor drew four lines of `| a | b |` where the page drew a grid —
    /// 3pt on a two-row table and 29 on a four-row one, and a table under a
    /// numbered step is how every set of instructions is written.
    @Test func aTableUnderAnItemsTextIsABlockOfItsOwn() {
        let text = "1. Above:\n\n   | a | b |\n   | --- | --- |\n   | 1 | 2 |\n" as NSString
        let kinds = BlockParser.fullParse(text).blocks.map(\.kind)
        #expect(kinds.contains { if case .table = $0 { return true }; return false })
        #expect(kinds.contains { if case .listItem = $0 { return true }; return false })
    }

    /// …and pipes inside a fence written under the item's text are a program.
    /// The fence walk is not optional: `| a | b |` over `| --- |` inside a
    /// listing would otherwise have a grid drawn over two lines of somebody's
    /// code.
    @Test func pipesInsideANestedFenceAreNotATable() {
        let text = "1. Above:\n\n   ```\n   | a | b |\n   | --- | --- |\n   ```\n" as NSString
        let kinds = BlockParser.fullParse(text).blocks.map(\.kind)
        #expect(!kinds.contains { if case .table = $0 { return true }; return false })
    }

    // MARK: - A list inside a blockquote

    /// A blockquote's interior had no list box model at all: the gutter pass
    /// gave a gap for a deeper nested quote and for a heading and nothing else,
    /// so `> - one` / `> - two` stood 4pt short of `li + li` and every extra
    /// item cost another 4.
    @Test func aQuotedListGetsItsItemMargins() {
        #expect(style("> - one\n> - two", at: "> - one")?.paragraphSpacing
                == metrics.listItemGap)
        // A loose one takes the `<p>`'s 16 instead, and the blank quote line
        // between the items is what holds it.
        #expect(style("> - one\n>\n> - two", at: ">\n")?.maximumLineHeight == metrics.blockGap)
        // A list next to something that is not its own sibling — after a
        // paragraph, or written with another marker — is two boxes.
        #expect(style("> Intro:\n> - one", at: "> Intro:")?.paragraphSpacing == metrics.blockGap)
        #expect(style("> - one\n> * two", at: "> - one")?.paragraphSpacing == metrics.blockGap)
        // A line with no `>` is a lazy continuation and opens nothing at all
        // (GFM spec #216 is `> foo` / `    - bar`).
        #expect(style("> foo\n    - bar", at: "> foo")?.paragraphSpacing == 0)
    }

    /// `.markdown-body ol ul { margin-bottom: 0 }` is written with a
    /// **descendant** combinator, so a `<ul>` in a `<blockquote>` in an `<li>`
    /// matches it exactly as a directly nested one does. The page really does
    /// draw no gap where such a list ends, and the editor drew 16.
    @Test func aQuotedListInsideAnItemHasNoMarginWhereItEnds() {
        let inItem = "1. Step:\n\n   > - one\n   > - two\n   >\n   > Trailer.\n"
        #expect(style(inItem, at: "   >\n")?.maximumLineHeight == BlockBoxes.collapsedLine)
        // At the document level nothing zeroes it, and the run holds the 16.
        let topLevel = "> - one\n> - two\n>\n> Trailer.\n"
        #expect(style(topLevel, at: ">\n")?.maximumLineHeight == metrics.blockGap)
    }

    /// The gap a blank quote line holds is the **collapsed margin between the
    /// two boxes it separates**, not a constant. A heading's `margin-top` is
    /// 24, so every `>` / `> ## Head` stood 8pt short — in a quote only,
    /// because at the top level `BlockBoxes.gapBetween` asks properly.
    @Test func aBlankQuoteLineHoldsTheCollapsedMarginAndNotAConstant() {
        #expect(style("> Para.\n>\n> ## Head", at: ">\n")?.maximumLineHeight
                == metrics.headingTopGap)
        #expect(style("> Para.\n>\n> More.", at: ">\n")?.maximumLineHeight == metrics.blockGap)
    }

    // MARK: - Source the page has no element for

    /// A reference definition is not a block-level element — cmark consumes it
    /// and emits nothing — so `- b` / blank / `  [ref]: /url` is an item holding
    /// **one** block and GitHub draws a tight `<li>`. Counted loose, the item's
    /// text was wrapped in a `<p>`'s 16pt margin against a page that had drawn
    /// none.
    @Test func aReferenceDefinitionDoesNotLoosenTheItemThatHoldsIt() {
        let text = "- b\n\n  [ref]: /url\n" as NSString
        let blocks = BlockParser.fullParse(text).blocks
        let unrendered = [(text as String).range(of: "[ref]: /url").map {
            NSRange($0, in: text as String)
        }].compactMap { $0 }
        let item = blocks.firstIndex { if case .listItem = $0.kind { return true }; return false }
        #expect(item != nil)
        #expect(!BlockBoxes.listIsLoose(around: item ?? 0, in: blocks, text: text,
                                        unrendered: unrendered))
        // …and with a second *rendered* block below the gap it really is loose.
        let loose = "- b\n\n  [ref]: /url\n\n  more\n" as NSString
        let looseBlocks = BlockParser.fullParse(loose).blocks
        let looseRange = [(loose as String).range(of: "[ref]: /url").map {
            NSRange($0, in: loose as String)
        }].compactMap { $0 }
        let looseItem = looseBlocks.firstIndex {
            if case .listItem = $0.kind { return true }; return false
        }
        #expect(BlockBoxes.listIsLoose(around: looseItem ?? 0, in: looseBlocks, text: loose,
                                       unrendered: looseRange))
    }

    // MARK: - Code inside a list item

    /// The box starts where the `<li>`'s content starts. `applyNestedCode`
    /// builds a **fresh** paragraph style, so nothing of the item's own is
    /// inherited: the `<pre>` inside a numbered step was laid out at the
    /// document's left margin, 32pt left of the page's and 32pt wider. No
    /// height can see that — a wider box is the same height until something in
    /// it wraps.
    @Test func aCodeBoxInsideAnItemStartsUnderTheItemsText() {
        let text = "1. Step:\n\n   ```\n   let x = 1\n   ```\n"
        #expect(style(text, at: "let x = 1")?.headIndent
                == metrics.listIndent + metrics.codePadding)
        // …and the padding rows are part of the same box, so they start where
        // the box starts. Left at zero, `drawCodeBand` cut a notch out of the
        // panel's left side exactly the width of the list's indent.
        #expect(style(text, at: "   ```\n")?.headIndent
                == metrics.listIndent + metrics.codePadding)
    }

    /// cmark strips the item's own columns before the `<pre>` ever sees the
    /// line, so they are markup and not program. Drawn, they made the listing
    /// crooked *and* the editor's code column that much narrower — a 61-column
    /// line was two lines in Edit and one in Preview at a 640pt pane.
    ///
    /// Concealed **after** the cmark overlay, because
    /// `GFMLiveStyle.emitCodeBlock` paints a run across the whole body of the
    /// block, indent included, and it runs later: doing it in `applyNestedCode`
    /// was undone a few lines afterwards, silently and completely.
    @Test func aListingInsideAnItemHidesTheItemsOwnIndent() {
        let text = "1. Step:\n\n   ```\n   let x = 1\n   ```\n"
        let document = styled(text)
        let indent = (text as NSString).range(of: "   let").location
        #expect((document.storage.attribute(.font, at: indent, effectiveRange: nil)
                 as? PlatformFont)?.pointSize == EditorTheme.concealedSize)
        // The program's own indentation past those columns is the program's.
        let deeper = "1. Step:\n\n   ```\n       deep\n   ```\n"
        let inner = styled(deeper)
        let past = (deeper as NSString).range(of: "    deep").location
        #expect((inner.storage.attribute(.font, at: past, effectiveRange: nil)
                 as? PlatformFont)?.pointSize != EditorTheme.concealedSize)
    }

    /// A listing is not prose. Every line of a list item used to become a
    /// content span, so the inline pass ran over the program: a URL came out an
    /// underlined link, `**bold**` lost its asterisks, a backticked word grew
    /// an inline-code pill — against a Preview showing all three literally. No
    /// height could see it; the pictures showed it at a glance.
    @Test func aListingInsideAnItemIsNotStyledAsProse() {
        let text = "1. Step:\n\n   ```\n   see **bold** here\n   ```\n" as NSString
        let parse = BlockParser.fullParse(text)
        let item = parse.blocks.first { if case .listItem = $0.kind { return true }; return false }
        #expect(item != nil)
        let spans = StyleSpec.contentSpans(for: item!, text: text, lines: parse.lines)
        let listing = text.range(of: "see **bold** here")
        #expect(!spans.contains { NSIntersectionRange($0, listing).length > 0 })
        // The item's own text is still prose.
        let title = text.range(of: "Step:")
        #expect(spans.contains { NSIntersectionRange($0, title).length > 0 })
    }
}
