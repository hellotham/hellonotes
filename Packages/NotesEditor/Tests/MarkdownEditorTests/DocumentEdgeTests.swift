//
//  DocumentEdgeTests.swift
//  MarkdownEditorTests
//
//  What the note is *made of* at its two ends.
//
//  `.markdown-body`'s height runs from the top of the first box that paints
//  something to the bottom of the last one. The stylesheet zeroes the margins
//  at those two edges, and a margin, a blank line or an empty element beyond
//  them has nothing to be the space *between* — so it is not space at all.
//
//  The editor knew a weaker version of that: "the last **rendered** block". A
//  rendered block is not the same as a box that paints something, and the
//  difference is a whole margin. cmark emits an `<h3>` for `### ###` and a
//  `<blockquote>` for a bare `>`; both are rendered, both draw nothing, and
//  the editor reserved 24pt above them for a box the page never painted.
//
//  Every test here lays a note out for real: the mechanism is a paragraph
//  style and a line height, and the only honest question is what survives
//  layout.
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

@Suite @MainActor struct DocumentEdgeTests {

    @MainActor private final class Layout {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        private let fragments = RenderedBlockLayoutDelegate()

        init(_ text: String, width: CGFloat, base: CGFloat, caret: NSRange?) {
            let document = EditorDocument(text: text, theme: EditorTheme(fontSize: base))
            // The caret before the styling, so the reveal is part of the pass
            // rather than a second one on top of it.
            if let caret { document.selectionDidChange(caret) }
            document.styleEverythingNow()
            layoutManager.delegate = fragments
            let container = NSTextContainer(size: CGSize(width: width,
                                                         height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layoutManager.textContainer = container
            contentStorage.addTextLayoutManager(layoutManager)
            contentStorage.textStorage?.setAttributedString(document.storage)
            layoutManager.ensureLayout(for: layoutManager.documentRange)
        }

        var height: CGFloat { layoutManager.usageBoundsForTextContainer.height }
    }

    private func layout(_ text: String, width: CGFloat = 600, base: CGFloat = 16,
                        caret: NSRange? = nil) -> Layout {
        Layout(text, width: width, base: base, caret: caret)
    }

    private func height(_ text: String, caret: NSRange? = nil) -> CGFloat {
        layout(text, caret: caret).height
    }

    private func metrics(_ base: CGFloat) -> GFMBoxMetrics { GFMBoxMetrics(base: base) }

    /// A hundredth of a point. Everything here is a sum of rounded line heights
    /// and `.3em`s, so exact `==` on `CGFloat` tests the last bit of a double
    /// and nothing about the box model.
    private func same(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }

    /// Both `collapsedLine`s and a hair: what a run of source that draws
    /// nothing is allowed to cost. Zero is not available — `maximumLineHeight`
    /// of 0 means *unlimited* to TextKit, so a line asked for no height gets
    /// its natural one instead.
    private func nothing(_ lines: Int) -> CGFloat {
        CGFloat(lines) * BlockBoxes.collapsedLine
    }

    // MARK: - A box that paints nothing does not end the document

    /// `# Foo` then an empty `### ###`. The page paints the h1 and stops: an
    /// empty h3 has no content, no padding and no border, so its margins
    /// collapse through it and land outside the article's height.
    ///
    /// The editor charged the note a full 24pt for the margin above that empty
    /// box. Nothing could see it: the box itself is 0.01pt tall, every
    /// paragraph style was right, and the space is below the last thing anyone
    /// draws.
    @Test func anEmptyHeadingEndingTheNoteReservesNoMarginAboveItself() {
        for trailing in ["### ###", "###", "#####  "] {
            #expect(same(height("# Foo\n" + trailing),
                         height("# Foo") + BlockBoxes.collapsedLine))
        }
    }

    /// The same for `>` on its own, and for a quote holding nothing but source
    /// the reader never sees — cmark emits `<blockquote></blockquote>` for
    /// both, which is a box of no height and, having no content on its
    /// vertical axis, no margin either.
    @Test func anEmptyQuoteEndingTheNoteReservesNoMarginAboveItself() {
        #expect(same(height("Foo\n\n>"), height("Foo") + nothing(2)))
        #expect(same(height("[foo]\n\n> [foo]: /url"), height("[foo]") + nothing(2)))
    }

    /// The other half of the rule, and the reason it is `paints` and not "is
    /// it empty": an empty **h1 or h2** draws `padding-bottom: .3em` and a
    /// border, which is real ink. The margin above one is painted space and
    /// stays.
    @Test func anEmptyH1OrH2StillPaintsItsRule() {
        let m = metrics(16)
        #expect(same(height("Foo\n\n##"), height("Foo") + m.headingTopGap + m.headingRuleInset(2)
                                          + BlockBoxes.collapsedLine))
        #expect(same(height("Foo\n\n#"), height("Foo") + m.headingTopGap + m.headingRuleInset(1)
                                         + BlockBoxes.collapsedLine))
    }

    /// The control that rules out "an empty box is invisible everywhere". In
    /// the middle of a note the empty box's own margins are still part of the
    /// collapsed run between its neighbours — `### ###` between two paragraphs
    /// puts the heading's 24 there, not the paragraph's 16.
    @Test func anEmptyHeadingInTheMiddleStillContributesItsMargin() {
        let m = metrics(16)
        let spanned = height("Foo\n### ###\nBar") - height("Foo") - height("Bar")
        #expect(same(spanned, m.headingTopGap + BlockBoxes.collapsedLine))
    }

    // MARK: - Blank lines outside the painted content

    /// Blank lines above the first painted box and below the last are not
    /// margins: there is nothing on the other side of them for them to be the
    /// space between. They used to keep a 0.5pt hairline each, which is 2pt of
    /// page on the ordinary note that opens and closes with a blank line — and
    /// the hairline never bought what it promised, because 0.5pt of line is
    /// 0.5pt of insertion point.
    @Test func blankLinesAtTheEdgesOfTheNoteTakeNoRoom() {
        // Written without a trailing newline, because TextKit puts a *caret
        // line* after the document's last one — a place to type, which the
        // page has no equivalent of and which no paragraph style here owns.
        let bare = height("Foo")
        #expect(same(height("\n\nFoo"), bare + nothing(2)))
        #expect(same(height("Foo\n \n "), bare + nothing(2)))
        #expect(same(height("  \n\nFoo\n  "), bare + nothing(3)))
    }

    /// …and a blank line *between* two boxes is still the margin between them,
    /// undisturbed. This is the line the change must not touch.
    @Test func aBlankLineBetweenTwoBoxesIsStillTheMargin() {
        let m = metrics(16)
        #expect(same(height("Foo\n\nBar"), 2 * m.bodyLineHeight + m.blockGap))
        #expect(same(height("Foo\n\n\n\nBar"), 2 * m.bodyLineHeight + m.blockGap))
    }

    /// The caret's answer, which the hairline was pretending to be: the line
    /// the caret is actually on comes back to a full body line, so a note that
    /// opens or closes with blank lines is still one you can type on. Exactly
    /// what a reference definition does when the caret arrives.
    @Test func theBlankLineTheCaretIsOnComesBack() {
        let m = metrics(16)
        let text = "\n\nFoo"
        let closed = height(text)
        #expect(same(height(text, caret: NSRange(location: 0, length: 0)),
                     closed - BlockBoxes.collapsedLine + m.bodyLineHeight))
        // …and only that line, not the run: the second blank stays collapsed.
        #expect(same(height(text, caret: NSRange(location: 1, length: 0)),
                     closed - BlockBoxes.collapsedLine + m.bodyLineHeight))
    }

    /// Concealed source the parser swept into a block — the blank tail of an
    /// indented code block — is source, not a blank line, and takes the
    /// concealed floor rather than the blank one. It only ever shows at the end
    /// of the note, where there is no margin left for it to hold.
    @Test func theBlankTailOfACodeBlockHoldsNothingAtTheEndOfTheNote() {
        let m = metrics(16)
        let box = m.codeLineHeight + 2 * m.codePadding
        #expect(same(height("    foo"), box))
        #expect(same(height("    foo\n    \n    "), box + nothing(2)))
    }

    // MARK: - Both edges at once

    /// The whole of the rule in one note: reference definitions and blank lines
    /// above, an empty quote below, one paragraph of painted content between
    /// them. The page is 24pt tall and so is the editor.
    @Test func aNoteWhoseOnlyPaintedBoxIsOneParagraph() {
        let m = metrics(16)
        let text = "[foo]: /url1\n\n[foo]: /url2\n\n[bar][foo]\n\n>"
        #expect(height(text) < m.bodyLineHeight + 0.2)
        #expect(height(text) > m.bodyLineHeight)
    }

    // MARK: - `:last-child` counts elements, not boxes

    /// GitHub's tag filter escapes the leading `<` of `<style`, `<script`,
    /// `<title`, `<textarea` and their kin, so cmark hands the browser
    /// `&lt;style …` and the browser makes **text** of it — no element
    /// anywhere. `.markdown-body > *:last-child { margin-bottom: 0 }` counts
    /// elements, so the zeroing lands on the paragraph above, and the escaped
    /// text sits straight underneath it.
    ///
    /// The editor charged 16pt there — a margin the page had already thrown
    /// away — and every box in the note was otherwise in the right place, which
    /// is why it read for a long time as something only cmark could explain
    /// (spec #142, +16.05pt). `<style>` is the only shape of it the corpus has;
    /// the other four are here because the rule is about elements and not about
    /// that one tag.
    @Test func aTagFilteredBlockEndingTheNoteLeavesTheBoxAboveItAsLastChild() {
        let m = metrics(16)
        // An element under the paragraph: the paragraph is not `:last-child`
        // and keeps its margin. The control for every line below it.
        let withElement = height("Foo\n\n<div>x</div>")
        for filtered in ["<title>x</title>", "<style>x</style>",
                         "<script>x</script>", "<textarea>x</textarea>",
                         "<iframe>x</iframe>"] {
            #expect(same(height("Foo\n\n" + filtered) + m.blockGap - BlockBoxes.collapsedLine,
                         withElement))
        }
    }

    /// The same with no blank line to hold it, so the gap is on the
    /// paragraph's own last line rather than shared out over a run. Both
    /// arithmetics have to reach the same answer or the note is right only
    /// when it is typed one particular way.
    @Test func theSameWithNoBlankLineBetweenThem() {
        let m = metrics(16)
        #expect(same(height("Foo\n<title>x</title>") + m.blockGap,
                     height("Foo\n<div>x</div>")))
    }

    /// The control that keeps it a rule about the document's *end*: with a
    /// paragraph below it, the escaped text is no longer the last child, the
    /// `<p>` below it is — so the paragraph above keeps all 16pt of its margin.
    ///
    /// The blank run *below* the text costs a `collapsedLine` and nothing else,
    /// and that is not slack in the test: an anonymous block box has no margins
    /// of its own and `p { margin-top: 0 }`, so there is genuinely no space
    /// between the escaped text and `Bar` on the page either.
    @Test func aTagFilteredBlockInTheMiddleKeepsTheMarginAboveIt() {
        let m = metrics(16)
        let spanned = height("Foo\n\n<title>x</title>\n\nBar")
        #expect(same(spanned, height("Foo") + m.blockGap + height("<title>x</title>")
                              + nothing(1) + height("Bar")))
    }

    /// …and the blank line inside that zeroed margin is not a margin either.
    /// It used to keep the 0.5pt hairline `minimumBlankLine` gives a line that
    /// is *part of* a gap, which is exactly what this one is not.
    @Test func theBlankLineInsideAZeroedMarginCollapsesToNothing() {
        #expect(same(height("Foo\n\n<title>x</title>"),
                     height("Foo\n<title>x</title>") + BlockBoxes.collapsedLine))
    }

    /// The control for *how* that is asked. "Holds no gap" and "outside the
    /// painted content" look like the same predicate and are not: an unpainted
    /// first box still hands the run below it the margin of whatever comes
    /// next, so the run is outside the painted content and holding 24pt at the
    /// same time. Ask only "is the gap zero" and the hairline floor comes back
    /// for it — a tenth of a point per blank line, +6.52pt over the 61 here,
    /// against a page that has not moved.
    @Test func aLongBlankRunUnderAnUnpaintedFirstBoxStillHoldsOnlyItsGap() {
        let m = metrics(16)
        let run = String(repeating: "\n", count: 61)
        let one = "### ###\n\n## Heading"
        #expect(same(height("### ###" + run + "## Heading"), height(one)))
        // …and the gap it is holding really is the heading's 24, not nothing —
        // which is the whole reason the two predicates cannot be folded into
        // one. To within the hairlines the two collapsed lines cost.
        #expect(abs(height(one) - height("## Heading") - m.headingTopGap) < 0.05)
    }
}
