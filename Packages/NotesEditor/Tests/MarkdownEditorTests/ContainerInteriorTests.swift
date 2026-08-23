//
//  ContainerInteriorTests.swift
//  MarkdownEditorTests
//
//  A `<li>` and a `<blockquote>` hold *blocks*, and GitHub styles them as such.
//  The editor's block list is flat, so each interior construct is its own rule
//  in `StyleApplier` — and each of these tests is a construct that used to be
//  styled as one more line of the container's prose.
//

import Foundation
import Testing
@testable import MarkdownEditor
@testable import MarkdownCore

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@Suite @MainActor struct ContainerInteriorTests {

    /// Line height of the line containing `needle`, with nothing revealed.
    private func lineHeight(_ text: String, at needle: String) -> CGFloat {
        let document = EditorDocument(text: text, theme: EditorTheme(fontSize: 16))
        document.styleEverythingNow()
        let loc = (text as NSString).range(of: needle).location
        guard loc != NSNotFound else { return -1 }
        let style = document.storage.attribute(.paragraphStyle, at: loc,
                                               effectiveRange: nil) as? NSParagraphStyle
        return style?.maximumLineHeight ?? -1
    }

    /// The vertical space the **box** gives the line containing `needle`: its
    /// line height, plus whatever is reserved below the line box for
    /// `pre { padding-bottom }`.
    ///
    /// One number in CSS and two in TextKit, and which of the two holds the
    /// padding is not something a test should pin down — but it is also not
    /// arbitrary. Bottom padding cannot live in a line height: the spare
    /// height of a pinned line goes *above* the glyphs, so a line grown to
    /// hold it puts the space on the wrong side and the listing sits hard
    /// against the bottom of its box. (The repair that used to be here — a
    /// negative `.baselineOffset` to "lift the glyphs off it" — moves the
    /// reported baseline and not the ink, so the two cancelled exactly and
    /// every height measurement stayed green.) It is reserved outside the line
    /// box instead: `codeBottomPadAttribute`, which the fragment turns into
    /// `bottomMargin` and paints over. The sum is what the page draws, and the
    /// sum is what these tests are about.
    private func boxHeight(_ text: String, at needle: String) -> CGFloat {
        let document = EditorDocument(text: text, theme: EditorTheme(fontSize: 16))
        document.styleEverythingNow()
        let loc = (text as NSString).range(of: needle).location
        guard loc != NSNotFound else { return -1 }
        let style = document.storage.attribute(.paragraphStyle, at: loc,
                                               effectiveRange: nil) as? NSParagraphStyle
        // Read at the line's start, which is where the fragment reads it.
        let lineStart = document.parse.lines.lineRange(
            document.parse.lines.lineNumber(at: loc)).location
        let pad = document.storage.attribute(codeBottomPadAttribute, at: lineStart,
                                             effectiveRange: nil) as? CGFloat ?? 0
        return (style?.maximumLineHeight ?? -1) + pad
    }

    /// Is the text at `needle` concealed — the collapsed font the unrendered
    /// path uses? Asked here rather than of the line height, because a
    /// concealed *paragraph* shares the block margin out across its own line
    /// and the blank lines around it (5.33pt each at base 16), so no single
    /// line of it measures zero even though the block contributes nothing.
    private func isConcealed(_ text: String, at needle: String) -> Bool {
        let document = EditorDocument(text: text, theme: EditorTheme(fontSize: 16))
        document.styleEverythingNow()
        let loc = (text as NSString).range(of: needle).location
        guard loc != NSNotFound else { return false }
        let font = document.storage.attribute(.font, at: loc, effectiveRange: nil) as? PlatformFont
        return font?.pointSize == EditorTheme.concealedSize
    }

    /// The gap below the line containing `needle`, with nothing revealed.
    private func trailingGap(_ text: String, at needle: String) -> CGFloat {
        let document = EditorDocument(text: text, theme: EditorTheme(fontSize: 16))
        document.styleEverythingNow()
        let loc = (text as NSString).range(of: needle).location
        guard loc != NSNotFound else { return -1 }
        let style = document.storage.attribute(.paragraphStyle, at: loc,
                                               effectiveRange: nil) as? NSParagraphStyle
        return style?.paragraphSpacing ?? -1
    }

    private var metrics: GFMBoxMetrics { GFMBoxMetrics(base: 16) }

    /// The space reserved *above* the fragment holding `needle`, which is where
    /// a margin that has nothing to collapse into ends up.
    private func openingMargin(_ text: String, at needle: String) -> CGFloat {
        let document = EditorDocument(text: text, theme: EditorTheme(fontSize: 16))
        document.styleEverythingNow()
        let loc = (text as NSString).range(of: needle).location
        guard loc != NSNotFound else { return -1 }
        return document.storage.attribute(openingMarginAttribute, at: loc,
                                          effectiveRange: nil) as? CGFloat ?? 0
    }

    /// The source offset the item's bullet is drawn at, or -1 for none.
    private func bulletOffset(_ text: String) -> Int {
        let document = EditorDocument(text: text, theme: EditorTheme(fontSize: 16))
        document.styleEverythingNow()
        var found = -1
        document.storage.enumerateAttribute(listBulletAttribute,
                                            in: NSRange(location: 0, length: document.storage.length),
                                            options: []) { value, range, stop in
            if value != nil { found = range.location; stop.pointee = true }
        }
        return found
    }

    // MARK: - Inside a blockquote

    @Test func anATXHeadingInAQuoteGetsTheHeadingsLineHeight() {
        #expect(lineHeight("> # Foo\n> bar", at: "# Foo") == metrics.headingLineHeight(1))
        // …and an ordinary quoted line does not.
        #expect(lineHeight("> # Foo\n> bar", at: "bar") == metrics.bodyLineHeight)
    }

    @Test func indentedCodeInAQuoteGetsTheCodeBox() {
        let h = boxHeight(">     foo\n\nafter", at: "foo")
        // The code line plus the box's padding, top and bottom.
        #expect(h == metrics.codeLineHeight + 2 * metrics.codePadding)
    }

    // MARK: - A fenced code block inside a blockquote
    //
    // `applyQuoteBars` reads a quote one line at a time, and a fence is the
    // plain case of a construct a single line cannot describe: `> aaa` is prose
    // or a line of a listing depending only on what came before it. Until the
    // interior pass there was no "before", so it was always prose.

    /// The delimiters are the box's 16pt padding and the lines between are the
    /// listing — exactly the trade the top level makes.
    @Test func aFencedBlockInAQuoteGetsTheCodeBox() {
        let text = "x\n\n> ```\n> aaa\n> ```\n\ny"
        #expect(lineHeight(text, at: "```\n> aaa") == metrics.codePadding)
        #expect(lineHeight(text, at: "aaa") == metrics.codeLineHeight)
        #expect(lineHeight(text, at: "```\n\ny") == metrics.codePadding)
        // 16 + 20 + 16 — the `<pre>` WebKit lays out for the same three lines.
        #expect(lineHeight(text, at: "```\n> aaa") + lineHeight(text, at: "aaa")
                + lineHeight(text, at: "```\n\ny")
                == 2 * metrics.codePadding + metrics.codeLineHeight)
    }

    /// A fence that never closes ends with the quote, as one at the top level
    /// ends with the note. Its bottom padding has no delimiter to sit on, so
    /// the listing's last line holds it.
    @Test func anUnclosedFenceInAQuotePutsItsBottomPaddingOnTheListing() {
        let text = "> ```\n> aaa\n\nbbb"
        #expect(lineHeight(text, at: "```") == metrics.codePadding)
        #expect(boxHeight(text, at: "aaa") == metrics.codeLineHeight + metrics.codePadding)
    }

    /// …and one with no listing at all holds both paddings itself: an empty
    /// `<pre>`, which GitHub draws at 32pt and the editor drew at 24 — one
    /// quoted line of prose showing its ``` .
    @Test func anEmptyFenceInAQuoteIsAnEmptyPre() {
        #expect(lineHeight("> ```\n\nafter", at: "```") == 2 * metrics.codePadding)
    }

    /// The same block at the top level. `applyFenceBand` gave the one line the
    /// box's *top* padding and `padCodeLine` wanted a second line for the
    /// bottom, so a note ending in a bare ``` — every fence, for the moment
    /// between typing it and typing the line under it — stood 16pt short.
    @Test func anEmptyFenceAtTheTopLevelIsAnEmptyPre() {
        #expect(lineHeight("```", at: "```") == 2 * metrics.codePadding)
        // A closed one is unaffected: two delimiters, one padding each.
        #expect(lineHeight("```\n```", at: "```") == metrics.codePadding)
    }

    /// Inside the listing a `#` is a character of the program. Asked line by
    /// line it was an `<h1>`, 40pt tall and set in the heading font.
    @Test func markdownInsideAQuotedListingIsNotMarkdown() {
        let text = "> ```\n> # x\n> - y\n> ```\n\nafter"
        #expect(lineHeight(text, at: "# x") == metrics.codeLineHeight)
        #expect(lineHeight(text, at: "- y") == metrics.codeLineHeight)
        #expect(!isConcealed(text, at: "# x"))
        #expect(!isConcealed(text, at: "- y"))
    }

    /// A blank quote line inside the listing is a blank line of the program,
    /// not the 16pt margin between two of the quote's paragraphs.
    @Test func aBlankQuoteLineInsideAListingIsCode() {
        let text = "> ```\n> a\n>\n> b\n> ```\n\nafter"
        #expect(lineHeight(text, at: "b") == metrics.codeLineHeight)
        let document = EditorDocument(text: text, theme: EditorTheme(fontSize: 16))
        document.styleEverythingNow()
        let blank = (text as NSString).range(of: "\n>\n").location + 1
        let style = document.storage.attribute(.paragraphStyle, at: blank,
                                               effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.maximumLineHeight == metrics.codeLineHeight)
    }

    /// Only a *bare* run closes a fence — an info string makes it an opening
    /// one, so `> ```swift` in the middle of a listing is a line of it.
    @Test func onlyABareFenceClosesAQuotedListing() {
        let text = "> ```\n> ```swift\n> ```\n\nafter"
        #expect(lineHeight(text, at: "```swift") == metrics.codeLineHeight)
        #expect(lineHeight(text, at: "```\n\nafter") == metrics.codePadding)
    }

    /// `pre { padding: 16px }` on the left as well as the top. The code band is
    /// painted from `headIndent`, so a box that did not declare its own padding
    /// there was drawn straight through the quote's bar. It used to be added
    /// with `+=` a dozen lines above the assignment that overwrote it.
    @Test func aQuotedCodeBoxClearsTheQuotesBar() {
        for text in ["> ```\n> aaa\n> ```\n\nafter", ">     aaa\n\nafter"] {
            let document = EditorDocument(text: text, theme: EditorTheme(fontSize: 16))
            document.styleEverythingNow()
            let loc = (text as NSString).range(of: "aaa").location
            let style = document.storage.attribute(.paragraphStyle, at: loc,
                                                   effectiveRange: nil) as? NSParagraphStyle
            #expect(style?.headIndent == metrics.quoteIndent + metrics.codePadding)
        }
    }

    // MARK: - A list item inside a blockquote

    /// Four columns past the *item's own content* is a code block; four past
    /// the quote's bars is not. `> > 1.  one` opens its item at column four, so
    /// its continuation `>>     two` is the item's paragraph — and reading it
    /// against the quote instead drew a 52pt code box over a line of prose.
    @Test func anItemsOwnIndentIsNotAnIndentedCodeBlock() {
        let text = "x\n\n> > 1.  one\n>>\n>>     two\n\nafter"
        #expect(lineHeight(text, at: "two") == metrics.bodyLineHeight)
        // …and the blank `>>` between them does not end the item: a blank line
        // inside a list makes it loose, it does not close it.
        #expect(lineHeight(text, at: "one") == metrics.bodyLineHeight)
    }

    /// A loose `<li>` wraps its text in a `<p>`, and that paragraph's
    /// `margin-top` escapes the `<li>`, the `<ul>` and the `<blockquote>` alike
    /// — none of them has an edge to stop it, and `blockquote > :first-child`
    /// zeroes the *list's* margin, not the paragraph's. With anything above the
    /// quote it collapses into that block's own margin and nothing shows; with
    /// the quote at the top of the note the page starts 16pt lower, and the
    /// editor did not.
    /// Reserved as the fragment's **top margin**, not as line height. A line
    /// height is per *wrapped visual line*, and this styling knows nothing
    /// about the pane's width, so an opening item long enough to wrap paid the
    /// margin once per line — 16pt of invented space, visible only once a
    /// document is laid out narrow enough to wrap. See `openingMarginAttribute`.
    @Test func aLooseListOpeningTheNoteInsideAQuoteReservesItsTopMargin() {
        // Probed at the **line's** first character, which is where a fragment
        // starts and therefore where `topMargin` reads it — the `>` here, not
        // the item's marker two columns along.
        #expect(openingMargin("> - one\n>\n>   two", at: "> - one") == metrics.blockGap)
        // …and it is *not* in the line height, which is what made it wrong.
        #expect(lineHeight("> - one\n>\n>   two", at: "- one") == metrics.bodyLineHeight)
        // Tight: no `<p>`, no margin.
        #expect(openingMargin("> - one\n> - two", at: "> - one") == 0)
        // A sibling item across a blank line is the same loose list.
        #expect(openingMargin("> - one\n>\n> - two", at: "> - one") == metrics.blockGap)
        // A line shallower than the item ends the list, and a list that ended
        // before the blank line is still tight.
        #expect(openingMargin(">>- one\n>>\n  >  > two", at: ">>- one") == 0)
        // Not at the top of the note there is nothing to reserve: the margin
        // above collapses into the gap below whatever precedes the quote.
        #expect(openingMargin("x\n\n> - one\n>\n>   two", at: "> - one") == 0)
        // A quote that opens with prose keeps nothing either — that `<p>` *is*
        // `blockquote > :first-child`, whose margin the stylesheet zeroes.
        #expect(openingMargin("> foo\n>\n> bar", at: "> foo") == 0)
    }

    /// The same margin, reserved for a **list item** that opens the note.
    @Test func aLooseListOpeningTheNoteReservesItsTopMarginOutsideTheLineBox() {
        #expect(openingMargin("- one\n\n  two", at: "- one") == metrics.blockGap)
        #expect(lineHeight("- one\n\n  two", at: "- one") == metrics.bodyLineHeight)
        // Tight, and not at the top: nothing either way.
        #expect(openingMargin("- one\n- two", at: "- one") == 0)
        #expect(openingMargin("x\n\n- one\n\n  two", at: "- one") == 0)
    }

    /// With no item open the old ruler is still the right one.
    @Test func fourColumnsWithNoItemOpenIsStillCode() {
        #expect(boxHeight(">     foo\n\nafter", at: "foo")
                == metrics.codeLineHeight + 2 * metrics.codePadding)
        // And eight columns inside an item at column two is code again.
        #expect(boxHeight("> - one\n>       foo\n\nafter", at: "foo")
                == metrics.codeLineHeight + 2 * metrics.codePadding)
    }

    /// The stack is a stack: a nested item's content column is measured from
    /// the quote's content, marker indent included, so it must not be added to
    /// the enclosing item's — which would put the code column one deeper for
    /// every level of nesting.
    @Test func aNestedQuotedItemsCodeColumnIsAbsolute() {
        // Outer item content at column 2, inner at column 4, so eight columns
        // is a code block inside the inner one.
        let text = "x\n\n> - a\n>   - b\n>         code\n\nafter"
        #expect(boxHeight(text, at: "code")
                == metrics.codeLineHeight + 2 * metrics.codePadding)
        // …and seven is still the inner item's own paragraph.
        let prose = "x\n\n> - a\n>   - b\n>       still b\n\nafter"
        #expect(lineHeight(prose, at: "still b") == metrics.bodyLineHeight)
    }

    /// A line written shallower than the open item closes it, so what follows
    /// is measured against the quote again.
    @Test func aShallowerLineClosesTheQuotedItem() {
        let text = "> - one\n> two\n>     foo\n\nafter"
        #expect(boxHeight(text, at: "foo")
                == metrics.codeLineHeight + 2 * metrics.codePadding)
    }

    /// The listing inside a marker-line fence takes the code box, and the
    /// delimiters become its 16pt padding — as they do at the top level. The
    /// one difference: the item's marker is laid into the first line box of
    /// its first child block, and the marker is set at the *item's* line
    /// height, so that one line is as tall as a line of prose.
    @Test func aFenceOnTheMarkerLineGetsTheCodeBox() {
        let text = "x\n\n1. ```\n   foo\n   ```\n\ny"
        #expect(lineHeight(text, at: "foo") == metrics.bodyLineHeight)
        #expect(lineHeight(text, at: "1. ```") == metrics.codePadding)
    }

    /// …and a second listing line, with no marker beside it, is an ordinary
    /// line of code again. Growing the whole block would have been 4pt per
    /// line rather than 4pt per item.
    @Test func onlyTheMarkersOwnLineTakesTheItemsLineHeight() {
        let text = "x\n\n1. ```\n   foo\n   bar\n   ```\n\ny"
        #expect(lineHeight(text, at: "foo") == metrics.bodyLineHeight)
        #expect(lineHeight(text, at: "bar") == metrics.codeLineHeight)
    }

    /// A code block that is *not* the item's first child has no marker in it,
    /// so it keeps the code line height throughout — the marker is up in the
    /// paragraph above, where a line of prose is already that tall.
    @Test func aCodeBlockBelowTheItemsTextKeepsTheCodeLineHeight() {
        let text = "x\n\n- foo\n\n  ```\n  bar\n  ```\n\ny"
        #expect(lineHeight(text, at: "bar") == metrics.codeLineHeight)
    }

    /// Indented code opening an item takes the same marker line, and its first
    /// line is still carrying the box's top padding as well.
    @Test func indentedCodeOpeningAnItemTakesTheItemsLineHeight() {
        let text = "x\n\n1.     indented code\n\ny"
        #expect(boxHeight(text, at: "indented code")
                == metrics.bodyLineHeight + 2 * metrics.codePadding)
    }

    // MARK: - A fence written inside a list item

    /// The delimiter line *is* the code box's 16pt padding, so it has to be
    /// empty. Nothing concealed it inside a list item, so the ``` — and far
    /// more visibly its info string — was drawn as the listing's first line.
    /// `1. Install:` over an indented ```bash block put the word "bash" inside
    /// the code box, and every height measurement agreed.
    @Test func aFencesInfoStringInsideAnItemIsConcealed() {
        let text = "1. Install:\n\n   ```bash\n   x\n   ```\n"
        let document = EditorDocument(text: text, theme: EditorTheme(fontSize: 16))
        document.styleEverythingNow()
        let info = (text as NSString).range(of: "bash")
        let colour = document.storage.attribute(.foregroundColor, at: info.location,
                                                effectiveRange: nil) as? PlatformColor
        #expect(colour == PlatformColor.clear)
        // …and the line it sits on still holds the box's padding.
        #expect(lineHeight(text, at: "```bash") == metrics.codePadding)
        // The listing itself is untouched.
        let x = (text as NSString).range(of: "\n   x").location + 4
        let xColour = document.storage.attribute(.foregroundColor, at: x,
                                                 effectiveRange: nil) as? PlatformColor
        #expect(xColour != PlatformColor.clear)
    }

    /// The marker is not part of the fence: `1. ``` ` still shows its number.
    @Test func aFenceOnTheMarkerLineDoesNotConcealTheMarker() {
        let text = "1. ```\n   x\n   ```\n"
        let document = EditorDocument(text: text, theme: EditorTheme(fontSize: 16))
        document.styleEverythingNow()
        let marker = (text as NSString).range(of: "1.")
        let colour = document.storage.attribute(.foregroundColor, at: marker.location,
                                                effectiveRange: nil) as? PlatformColor
        #expect(colour != PlatformColor.clear)
    }

    // MARK: - Where the bullet is drawn

    /// `<li>` puts its marker in the first line box of its first child, and an
    /// empty marker line has no line box — it is collapsed to a hundredth of a
    /// point. Drawn there the bullet was invisible, so the item rendered with
    /// no bullet at all.
    @Test func anEmptyMarkerLineCarriesItsBulletToTheContent() {
        let text = "x\n\n-\n  foo\n\ny"
        #expect(bulletOffset(text) == (text as NSString).range(of: "  foo").location)
    }

    /// Same rule, different reason the marker line has no line box: an opening
    /// fence is the code box's top padding, and the page draws the marker
    /// beside the first line of the listing.
    @Test func aMarkerLineFenceCarriesItsBulletToTheListing() {
        let text = "x\n\n- ```\n  foo\n  ```\n\ny"
        #expect(bulletOffset(text) == (text as NSString).range(of: "  foo").location)
    }

    /// An ordinary item keeps its bullet on its own line. The carry runs after
    /// `StyleSpec`'s marker run, which is late enough to undo a correct
    /// placement as well as a wrong one.
    @Test func anOrdinaryItemKeepsItsBulletOnTheMarkerLine() {
        let text = "x\n\n- foo\n  bar\n\ny"
        #expect(bulletOffset(text) == (text as NSString).range(of: "- foo").location)
    }

    // MARK: - An unbalanced HTML block

    /// `</div>` draws nothing and `*foo*` is text the reader sees, so the page
    /// shows one line where the editor showed two. The collapse used to be
    /// all-or-nothing per block, and refused the whole block because one line
    /// carried content — leaving the tag visible in every such example.
    @Test func onlyTheTagLinesOfAnUnbalancedHTMLBlockCollapse() {
        let text = "x\n\n</div>\n*foo*\n\ny"
        #expect(lineHeight(text, at: "</div>") < 1)
        #expect(lineHeight(text, at: "*foo*") == metrics.bodyLineHeight)
    }

    /// Two tags on one line is not HTML block condition 7 — that wants a single
    /// tag alone — so cmark leaves `<a><bab><c2c>` as a *paragraph* of raw
    /// inline HTML, and the browser paints an empty `<p>` of zero height. The
    /// block branch above never saw these because there was no html block.
    @Test func aParagraphOfNothingButWrapperTagsCollapses() {
        #expect(isConcealed("x\n\n<a><bab><c2c>\n\ny", at: "<a>"))
        #expect(isConcealed("x\n\n<a/><b2/>\n\ny", at: "<a/>"))
        #expect(isConcealed("x\n\n</a></foo >\n\ny", at: "</a>"))
    }

    /// And a tag is not required to fit on a line. The predicate used to be
    /// asked one line at a time, so neither half of `<a href="foo⏎bar">`
    /// parsed and the editor kept 48pt of source under a page drawing nothing —
    /// twice the divergence the single-line case had. Spec #634/#635/#662/#663.
    @Test func aWrapperTagWrittenAcrossALineEndingCollapsesToo() {
        #expect(isConcealed("x\n\n<a href=\"foo  \nbar\">\n\ny", at: "<a href"))
        #expect(isConcealed("x\n\n<a  /><b2\ndata=\"foo\" >\n\ny", at: "<a  />"))
        // The control the loose reading would fail: `bim!bop` is not an
        // attribute name, so this is two lines of literal text on the page.
        #expect(!isConcealed("x\n\n<foo bar=baz\nbim!bop />\n\ny", at: "<foo"))
        // And text on the second line still keeps both lines.
        #expect(!isConcealed("x\n\n<a href=\"y\">\nvisible\n\ny", at: "<a href"))
    }

    /// The same shape, and every one of them text the page prints: an autolink,
    /// a literal `<>`, malformed tags, and the two elements GitHub's tag filter
    /// escapes. They all pass a "is it `<…>` runs?" test, which is why the
    /// paragraph rule asks the spec's tag grammar instead.
    @Test func aParagraphOfAngleBracketsTheReaderSeesKeepsItsLine() {
        for line in ["<http://foo.bar.baz>", "<foo@bar.example.com>", "<33> <__>",
                     "<a h*#ref=\"hi\">", "</a href=\"foo\">",
                     "<strong> <title> <style> <em>"] {
            let text = "x\n\n\(line)\n\ny"
            // The line height, not the concealment of the first character: an
            // autolink's own `<` *is* concealed and should be, because the page
            // prints the URL without its brackets. What must not happen is the
            // whole line folding away.
            #expect(lineHeight(text, at: line) == metrics.bodyLineHeight,
                    "\(line) was hidden, and the reader can see it")
        }
    }

    /// A blank line with nothing rendered after it inside the block is holding
    /// a margin above content the reader never sees — `- b` / blank /
    /// `[ref]: /url` is one visible line, and the item stood a whole block
    /// margin taller than the page.
    @Test func aBlankAboveOnlyUnrenderedContentCollapses() {
        let text = "x\n\n- a\n- b\n\n  [ref]: /url\n- d\n\ny"
        #expect(lineHeight(text, at: "[ref]") < 1)
        #expect(lineHeight(text, at: "- d") == metrics.bodyLineHeight)
    }

    /// A quote *inside* an item sits flush against the item's text: GitHub
    /// gives `blockquote` `margin-top: 0`, and a tight item's own text is not a
    /// `<p>`, so nothing separates them. The editor was putting a full block
    /// margin there — the item had not ended, but its bottom margin applied.
    @Test func aQuoteInsideAnItemHasNoGapAboveIt() {
        let text = "x\n\n* a\n  > b\n* c\n\ny"
        #expect(trailingGap(text, at: "* a") == 0)
        // …but an item that really has ended still carries its margin: `-` /
        // blank / `  foo` is an empty item and a *separate* paragraph.
        #expect(trailingGap("x\n\n-\n\n  foo\n\ny", at: "  foo") == 0)
    }

    // MARK: - Inside a list item

    @Test func anATXHeadingInAListItemGetsTheHeadingsLineHeight() {
        // With a block above, the heading's top margin lives in the gap
        // between them and the line box holds nothing but the line.
        #expect(lineHeight("x\n\n- # Foo\n\nafter", at: "# Foo") == metrics.headingLineHeight(1))
        #expect(lineHeight("x\n\n- ### Foo\n\nafter", at: "### Foo") == metrics.headingLineHeight(3))
    }

    /// Opening the document there is no gap above to collapse into, and
    /// TextKit drops `paragraphSpacingBefore` on the first paragraph outright,
    /// so the margin goes on the **fragment**, which counts it once however
    /// many visual lines the heading wraps to.
    ///
    /// This test used to assert the opposite — that the margin was folded into
    /// the *line height* — and it passed for as long as that was true. A line
    /// height applies to every wrapped line, and `StyleApplier` styles without
    /// knowing the pane's width, so the wrong mechanism measured exact at any
    /// pane the heading fits on and cost a whole `headingTopGap` per line it
    /// wrapped to: `- # <a heading that wraps>` came out +24.01pt at an 800pt
    /// pane, +48.01 at 560 and +72.01 at 420. Hence the second expectation,
    /// which is the load-bearing one: the line height is the heading's, with
    /// the margin nowhere in it.
    @Test func aHeadingOpeningTheDocumentInAnItemReservesItsTopMarginOnTheFragment() {
        #expect(openingMargin("- # Foo\n\nafter", at: "- # Foo") == metrics.headingTopGap)
        #expect(lineHeight("- # Foo\n\nafter", at: "# Foo") == metrics.headingLineHeight(1))
        // Every level carries the same `margin-top`, not h1's alone.
        #expect(openingMargin("- ### Foo\n\nafter", at: "- ### Foo") == metrics.headingTopGap)
        #expect(lineHeight("- ### Foo\n\nafter", at: "### Foo") == metrics.headingLineHeight(3))
        // With a block above, the margin has one to collapse into and the
        // fragment reserves nothing.
        #expect(openingMargin("x\n\n- # Foo\n\nafter", at: "- # Foo") == 0)
    }

    /// A heading has two spellings, and the item's exported top margin only
    /// knew one: `- Bar` over `  ---` already *drew* as an h2 — the text line
    /// carries the h2 line height — while the gap above it was a plain item's.
    /// Nothing about the item looks wrong until a second one sits above it.
    @Test func anItemOpeningWithASetextHeadingExportsItsTopMargin() {
        #expect(trailingGap("x\n\n- a\n- Bar\n  ---\n  baz\n\ny", at: "- a")
                == metrics.headingTopGap)
        #expect(trailingGap("x\n\n- a\n- Bar\n  ===\n  baz\n\ny", at: "- a")
                == metrics.headingTopGap)
        // The ATX spelling of the same shape, which was always right.
        #expect(trailingGap("x\n\n- a\n- ## Bar\n\ny", at: "- a") == metrics.headingTopGap)
        // A sibling that opens no heading keeps the list's own small gap, and
        // `-` alone over `---` is an empty item and a thematic break, not an
        // underline of anything.
        #expect(trailingGap("x\n\n- a\n- Bar\n\ny", at: "- a") < metrics.headingTopGap)
        #expect(trailingGap("x\n\n- a\n-\n  ---\n\ny", at: "- a") < metrics.headingTopGap)
    }

    /// The heading's bottom margin **collapses** with the gap the list already
    /// carries rather than adding to it. Summing the two put a whole extra
    /// block margin under every such item.
    ///
    /// Only the margin is here now. The rule's padding and border used to be
    /// added to this same `paragraphSpacing` — they *always* add, being inside
    /// the element — and that is exactly why they had to leave: TextKit drops
    /// a trailing `paragraphSpacing` at the end of the note, so the padding
    /// went with the margin and a note ending in an h1 clipped its own rule.
    /// The fragment reserves it instead; `HeadingRuleBandTests` measures it
    /// where it now lives, and checks it is not counted in both places.
    @Test func aHeadingEndingAnItemCollapsesItsBottomMargin() {
        // A blank line below is already standing for the margin, and the
        // rule's inset is no longer parked here — so there is nothing left.
        #expect(trailingGap("x\n\n- # Foo\n\nafter", at: "# Foo") == 0)
        // A sibling item directly below: nothing else is holding the margin,
        // so the heading's own applies — the margin, and only the margin.
        #expect(trailingGap("x\n\n- # Foo\n- plain", at: "# Foo") == metrics.blockGap)
        // h3 has no rule, so it never contributed a box — only the margin, and
        // it is unchanged.
        #expect(trailingGap("x\n\n- ### Foo\n- plain", at: "### Foo") == metrics.blockGap)
    }

    /// Four items stepped one space at a time are *siblings*, not a staircase
    /// of nested lists: CommonMark nests by the parent's **content column**,
    /// which ` - bar` never reaches. Deciding it by `listDepth`'s indent/2
    /// guess invented a level for every second item, so four items carried two
    /// `li + li` margins instead of three — and on alternate rows.
    @Test func itemsSteppedOneSpaceApartAreSiblings() {
        let text = "x\n\n- foo\n - bar\n  - baz\n   - boo\n\ny"
        for item in ["- foo", " - bar", "  - baz"] {
            #expect(trailingGap(text, at: item) == metrics.listItemGap)
        }
    }

    @Test func indentedCodeInAListItemGetsTheCodeBox() {
        let h = boxHeight("- foo\n\n      bar\n\nafter", at: "bar")
        #expect(h == metrics.codeLineHeight + 2 * metrics.codePadding)
    }

    @Test func aThematicBreakInAListItemBecomesTheRule() {
        #expect(lineHeight("- Foo\n- * * *\n\nafter", at: "* * *") == metrics.ruleThickness)
    }

    /// A blank line inside a loose item is the margin between its paragraphs,
    /// not a line of text.
    @Test func aBlankLineInsideAnItemIsTheParagraphMargin() {
        let text = "- one\n\n  two\n\nafter"
        let document = EditorDocument(text: text, theme: EditorTheme(fontSize: 16))
        document.styleEverythingNow()
        let blank = (text as NSString).range(of: "\n\n  two").location + 1
        let style = document.storage.attribute(.paragraphStyle, at: blank,
                                               effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.maximumLineHeight == metrics.blockGap)
    }

    /// A list ends where nothing continues it, which is decided by the parent's
    /// *content column* — `   - bar` under `10) foo` falls three spaces short
    /// of the four the `10) ` marker takes, so it starts a new list rather than
    /// nesting, and the item above it takes the list's bottom margin.
    @Test func aShallowerMarkerStartsANewListRatherThanNesting() {
        let text = "10) foo\n   - bar\n\nafter"
        let blocks = BlockParser.fullParse(text as NSString).blocks
        let items = blocks.enumerated().filter { if case .listItem = $0.element.kind { return true }; return false }
        #expect(items.count == 2)
        guard let firstItem = items.first else { return }
        let box = BlockBoxes.box(at: firstItem.offset, in: blocks, text: text as NSString)
        // The first item closes its list, so it carries the list's own margin.
        if case .listItem(_, let lastInList) = box { #expect(lastInList) }
        else { Issue.record("expected a list-item box") }
    }

    /// …and a properly nested one still nests.
    @Test func aMarkerAtTheContentColumnStillNests() {
        let text = "- foo\n  - bar\n\nafter"
        let blocks = BlockParser.fullParse(text as NSString).blocks
        let items = blocks.enumerated().filter { if case .listItem = $0.element.kind { return true }; return false }
        guard let firstItem = items.first else { return }
        let box = BlockBoxes.box(at: firstItem.offset, in: blocks, text: text as NSString)
        if case .listItem(_, let lastInList) = box { #expect(!lastInList) }
        else { Issue.record("expected a list-item box") }
    }

    /// A list inside a quote is a list: its marker is concealed and drawn as a
    /// bullet, and its text is indented by the list's own padding. `> - item`
    /// used to show the raw dash, four points from a height measurement that
    /// said everything was fine.
    @Test func aListInsideAQuoteGetsABulletAndAnIndent() {
        let text = "> - one\n> - two\n\nafter"
        let document = EditorDocument(text: text, theme: EditorTheme(fontSize: 16))
        document.styleEverythingNow()
        let dash = (text as NSString).range(of: "- one").location

        // The marker is concealed and carries the bullet.
        let font = document.storage.attribute(.font, at: dash, effectiveRange: nil) as? PlatformFont
        #expect((font?.pointSize ?? 99) == EditorTheme.concealedSize)
        #expect(document.storage.attribute(listBulletAttribute, at: dash, effectiveRange: nil) != nil)

        // …and the line is indented by the quote's inset plus the list's.
        let style = document.storage.attribute(.paragraphStyle, at: dash,
                                               effectiveRange: nil) as? NSParagraphStyle
        #expect((style?.headIndent ?? 0) >= metrics.listIndent)
    }

    /// An ordered list keeps its number visible, as it does outside a quote.
    @Test func anOrderedListInsideAQuoteKeepsItsNumber() {
        let text = "> 1. one\n> 2. two\n\nafter"
        let document = EditorDocument(text: text, theme: EditorTheme(fontSize: 16))
        document.styleEverythingNow()
        let number = (text as NSString).range(of: "1. one").location
        let font = document.storage.attribute(.font, at: number, effectiveRange: nil) as? PlatformFont
        #expect((font?.pointSize ?? 0) > 10)     // not concealed
    }

    /// The `>` stays concealed inside a quoted code block. Setting the code
    /// font over the whole line brought it back as a monospaced `>` sitting in
    /// the listing — markup the reader never sees.
    @Test func theQuoteMarkerStaysHiddenInsideQuotedCode() {
        let text = ">     quoted code\n\nafter"
        let document = EditorDocument(text: text, theme: EditorTheme(fontSize: 16))
        document.styleEverythingNow()
        let marker = (text as NSString).range(of: ">").location
        let font = document.storage.attribute(.font, at: marker, effectiveRange: nil) as? PlatformFont
        #expect((font?.pointSize ?? 99) == EditorTheme.concealedSize)
        // …and the code itself is set in the code font.
        let code = (text as NSString).range(of: "quoted code").location
        let codeFont = document.storage.attribute(.font, at: code, effectiveRange: nil) as? PlatformFont
        #expect(codeFont?.fontName.contains("Mono") == true)
    }

    /// Ordinary prose in a container is untouched by any of it.
    @Test func plainContainerLinesKeepTheBodyBox() {
        #expect(lineHeight("- just text\n\nafter", at: "just text") == metrics.bodyLineHeight)
        #expect(lineHeight("> just text\n\nafter", at: "just text") == metrics.bodyLineHeight)
    }

    // MARK: - A `<li>` whose first child is a block

    /// `<li>` puts its marker in the first line box of its first child, and
    /// that line is then as tall as a line of the *item's* prose, not a line
    /// of code. Which line that is was keyed on the item's first source line —
    /// wrong whenever the marker line carries nothing and collapses away, so
    /// `-` over an indented fence measured a line of code where the page had
    /// drawn a line of prose.
    @Test func aCodeBlockUnderACollapsedMarkerLineCarriesTheMarker() {
        #expect(lineHeight("-\n  ```\n  bar\n  ```", at: "bar")
                == max(metrics.codeLineHeight, metrics.bodyLineHeight))
        #expect(boxHeight("-\n      baz", at: "baz")
                == max(metrics.codeLineHeight, metrics.bodyLineHeight) + 2 * metrics.codePadding)
        // With text on the marker line the marker stays up there, and the code
        // box below is uniform.
        #expect(lineHeight("- x\n  ```\n  bar\n  ```", at: "bar") == metrics.codeLineHeight)
        #expect(boxHeight("- x\n      baz", at: "baz")
                == metrics.codeLineHeight + 2 * metrics.codePadding)
    }

    /// A code block that *ends* an item exports its own `margin-bottom`. The
    /// stylesheet zeroes that margin only on `.markdown-body > *:last-child`,
    /// so a `<pre>` inside an `<li>` keeps its 16 and — with no padding or
    /// border on the `<li>` or the `<ul>` — collapses straight out to meet the
    /// next item's `li + li` 4.
    @Test func aCodeBlockClosingAnItemExportsItsBottomMargin() {
        #expect(trailingGap("- a\n- ```\n  bar\n  ```\n- c", at: "  ```") == metrics.blockGap)
        #expect(trailingGap("- a\n-\n      baz\n- c", at: "      baz") == metrics.blockGap)
        // An item of prose keeps the small gap, which is what makes the rule
        // above invisible until a code block is the last thing in the item.
        #expect(trailingGap("- a\n- b\n- c", at: "- b") == metrics.listItemGap)
    }

    /// A **loose** item's own text is a `<p>`, and that paragraph's margin-top
    /// collapses out through the `<li>` and the `<ul>`. Anywhere else it meets
    /// the margin below whatever precedes the list and disappears into it —
    /// which is why this is invisible until the list opens the note, where
    /// there is nothing above for it to collapse into and the page simply
    /// starts 16pt lower.
    ///
    /// Asserted on `openingMarginAttribute`, which is where the space lives:
    /// it was originally folded into the first line's *height*, and moved to
    /// `RenderedBlockFragment.topMargin` so that it is counted once per
    /// fragment rather than once per wrapped visual line. This test kept
    /// asserting the old mechanism and went on passing until a full run caught
    /// it — a test that names a mechanism outlives the mechanism.
    @Test func aLooseListOpeningTheDocumentReservesItsParagraphsTopMargin() {
        #expect(openingMargin("- a\n\n- b", at: "- a") == metrics.blockGap)
        #expect(lineHeight("- a\n\n- b", at: "- a") == metrics.bodyLineHeight)
        // A paragraph above it: the margin collapses into that paragraph's own.
        #expect(openingMargin("x\n\n- a\n\n- b", at: "- a") == 0)
        #expect(lineHeight("x\n\n- a\n\n- b", at: "- a") == metrics.bodyLineHeight)
        // A tight list has no `<p>` to have a margin.
        #expect(openingMargin("- a\n- b", at: "- a") == 0)
        #expect(lineHeight("- a\n- b", at: "- a") == metrics.bodyLineHeight)
    }

    /// A concealed list item is still an empty `<li>` — cmark emits one, of no
    /// height and drawing nothing — and `li + li` still gives the item after it
    /// its margin. Stepped over as if it were nothing at all (which is right
    /// for a reference definition, where cmark emits no element) the space
    /// across it was 4pt short, once per such item.
    @Test func aConcealedItemStillGivesTheNextItemItsMargin() {
        // Nothing above: the whole 4pt has to live on the concealed line.
        #expect(lineHeight("- <div>\n- foo", at: "- <div>") == metrics.listItemGap)

        // With a paragraph above, the region is 16 down to the list plus 4
        // between its items — not one collapsed 16.
        let text = "x\n\n- <div>\n- foo"
        let document = EditorDocument(text: text, theme: EditorTheme(fontSize: 16))
        document.styleEverythingNow()
        func height(at offset: Int) -> CGFloat {
            let style = document.storage.attribute(.paragraphStyle, at: offset,
                                                   effectiveRange: nil) as? NSParagraphStyle
            return style?.maximumLineHeight ?? -1
        }
        let blank = (text as NSString).range(of: "\n\n").location + 1
        let concealed = (text as NSString).range(of: "- <div>").location
        #expect(height(at: blank) + height(at: concealed)
                == metrics.blockGap + metrics.listItemGap)
    }
}
