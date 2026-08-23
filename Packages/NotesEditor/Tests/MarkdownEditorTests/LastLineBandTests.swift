//
//  LastLineBandTests.swift
//  MarkdownEditorTests
//
//  The space a block keeps below its own last line — the band TextKit's
//  paragraph model has no obvious place for, and which the end of the note is
//  where you find out about.
//
//  GitHub gives such a heading two different things under its last line:
//  `padding-bottom: .3em` and the 1px border, both *inside* the element, and
//  `margin-bottom: 16px` outside it. TextKit's `paragraphSpacing` is the
//  margin, and TextKit drops it on the document's last paragraph — right for a
//  margin, since GitHub zeroes `:last-child`'s too, and wrong for padding,
//  which CSS never drops. The padding lives in `NSTextLayoutFragment`'s
//  `bottomMargin` instead: inside the fragment, i.e. inside the box, and
//  counted once per *paragraph* however many visual lines it wraps to.
//
//  These tests lay a note out for real rather than reading a paragraph style,
//  because the whole point of the mechanism is what survives layout.
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

@Suite @MainActor struct LastLineBandTests {

    /// One laid-out note, offscreen: the styled storage in a text container of
    /// the given width, with the editor's own fragment subclass vended.
    @MainActor private final class Layout {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        private let fragments = RenderedBlockLayoutDelegate()

        init(_ text: String, width: CGFloat, base: CGFloat) {
            let document = EditorDocument(text: text, theme: EditorTheme(fontSize: base))
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

        /// The fragment holding the character at `offset`.
        func fragment(at offset: Int) -> NSTextLayoutFragment? {
            guard let start = contentStorage.location(contentStorage.documentRange.location,
                                                      offsetBy: offset) else { return nil }
            return layoutManager.textLayoutFragment(for: start)
        }
    }

    private func layout(_ text: String, width: CGFloat = 600, base: CGFloat = 16) -> Layout {
        Layout(text, width: width, base: base)
    }

    /// The whole band between the bottom of the last *visual* line of the
    /// fragment holding `needle` and the bottom of the fragment itself.
    ///
    /// That is `paragraphSpacing` plus `bottomMargin` — both are in the
    /// fragment's frame — except at the end of the note, where TextKit drops
    /// the first and keeps the second. Measuring the sum rather than either
    /// one is the point: it is the gap the page draws, and which of the two
    /// halves it came out of is an implementation detail right up until the
    /// document runs out.
    private func spaceBelowLastLine(_ text: String, at needle: String,
                                    width: CGFloat = 600, base: CGFloat = 16) -> CGFloat {
        let offset = (text as NSString).range(of: needle).location
        guard offset != NSNotFound else { return -1 }
        let l = layout(text, width: width, base: base)
        guard let fragment = l.fragment(at: offset),
              let last = fragment.textLineFragments.last else { return -1 }
        return fragment.layoutFragmentFrame.height - last.typographicBounds.maxY
    }

    private func lineCount(_ text: String, at needle: String,
                           width: CGFloat, base: CGFloat = 16) -> Int {
        let offset = (text as NSString).range(of: needle).location
        guard offset != NSNotFound else { return -1 }
        return layout(text, width: width, base: base)
            .fragment(at: offset)?.textLineFragments.count ?? -1
    }

    private func metrics(_ base: CGFloat) -> GFMBoxMetrics { GFMBoxMetrics(base: base) }

    /// Points agree to a hundredth. Everything here is a sum of `.3em`s and
    /// rounded line heights, so exact `==` on `CGFloat` fails on the last bit
    /// of a double and says nothing about the box model.
    private func same(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }

    // MARK: - The band itself

    /// The whole bug, in one note: `# Foo` and nothing else. Its height is the
    /// heading's line box plus the rule's inset — and it was just the line box,
    /// so the note was ~11pt short of its Preview and the rule was drawn below
    /// the bottom of the used bounds, i.e. off the end of the note.
    ///
    /// (No top margin: GitHub zeroes `margin-top` on the article's first
    /// child, and so does the editor.)
    @Test func aNoteThatIsNothingButAHeadingKeepsTheSpaceForItsRule() {
        let m = metrics(16)
        #expect(same(layout("# Foo").height, m.headingLineHeight(1) + m.headingRuleInset(1)))
        #expect(same(layout("## Foo").height, m.headingLineHeight(2) + m.headingRuleInset(2)))
        // h3 has no rule, so it has no padding either — the line box is all.
        #expect(same(layout("### Foo").height, m.headingLineHeight(3)))
    }

    /// The band is padding, so it does not care that the paragraph is the last
    /// one. `paragraphSpacing` — the margin — does, and is dropped there.
    @Test func theRuleInsetIsTheSameAtTheEndOfTheNoteAsInTheMiddle() {
        let m = metrics(16)
        #expect(same(spaceBelowLastLine("Intro\n\n# Foo", at: "# Foo"), m.headingRuleInset(1)))
        #expect(same(spaceBelowLastLine("Intro\n\n# Foo\n\nbar", at: "# Foo"), m.headingRuleInset(1)))
        #expect(same(spaceBelowLastLine("Intro\n\n## Foo", at: "## Foo"), m.headingRuleInset(2)))
        #expect(spaceBelowLastLine("Intro\n\n### Foo", at: "### Foo") == 0)
    }

    /// The property that rules out the obvious alternative. Folding the inset
    /// into `minimumLineHeight` was tried and reverted because a line height
    /// applies to every *wrapped* visual line: a heading that wrapped to twenty
    /// gained the inset twenty times, and `StyleApplier` cannot see the pane's
    /// width to know. `bottomMargin` is per fragment — per paragraph — so the
    /// wrap count is none of its business.
    @Test func theInsetIsReservedOncePerHeadingHoweverItWraps() {
        let m = metrics(16)
        let long = "Intro\n\n# " + String(repeating: "wrap ", count: 40)
        #expect(lineCount(long, at: "wrap", width: 160) > lineCount(long, at: "wrap", width: 900))
        #expect(lineCount(long, at: "wrap", width: 900) > 1)
        for width in [160, 320, 640, 900] as [CGFloat] {
            #expect(same(spaceBelowLastLine(long, at: "wrap", width: width), m.headingRuleInset(1)))
        }
    }

    /// Every number re-derives from the base size, at the five the parity gate
    /// sweeps. A fixed inset would pass at 16 and nowhere else.
    @Test func theBandScalesWithTheTextSize() {
        for base in [12, 16, 20, 24, 28] as [CGFloat] {
            let m = metrics(base)
            #expect(same(spaceBelowLastLine("Intro\n\n# Foo", at: "# Foo", base: base),
                         m.headingRuleInset(1)))
            #expect(same(layout("# Foo", base: base).height,
                         m.headingLineHeight(1) + m.headingRuleInset(1)))
        }
    }

    /// The user-visible half: the rule is drawn at the last line's bottom plus
    /// `padding-bottom`, and the note has to be tall enough to hold it. It was
    /// not, at the end of a note — the pixels went below `usageBounds` and the
    /// heading appeared to have no rule at all.
    @Test func aNoteEndingInAHeadingIsTallEnoughToDrawItsRule() {
        for (text, needle, level) in [("Intro\n\n# Foo", "# Foo", 1),
                                      ("Intro\n\n## Foo", "## Foo", 2)] {
            let m = metrics(16)
            let l = layout(text)
            guard let fragment = l.fragment(at: (text as NSString).range(of: needle).location),
                  let line = fragment.textLineFragments.last else { Issue.record("no fragment"); return }
            // Exactly the y `RenderedBlockFragment.drawHeadingRule` uses.
            let ruleBottom = fragment.layoutFragmentFrame.minY + line.typographicBounds.maxY
                + m.headingSize(level) * GFMBoxMetrics.headingRulePadRatio + m.hairline
            #expect(ruleBottom <= l.height + 0.01)
        }
    }

    // MARK: - Not counted twice

    /// Both spellings of an `<h2>` are the same element and must measure the
    /// same. The setext underline is a second source line holding the heading's
    /// *margin*; if it were still holding the rule's padding as well — as it
    /// was before the padding moved into the fragment — this note would stand
    /// an inset taller than its ATX twin.
    @Test func bothSpellingsOfAnH2MeasureTheSame() {
        #expect(same(layout("x\n\n## Foo\n\nbar").height, layout("x\n\nFoo\n---\n\nbar").height))
        // …and ending the note too, which is where they used to differ. The
        // underline is a second source line, concealed rather than deleted,
        // and at the end of the note it has no margin left to hold; it used to
        // keep the floor a *blank* line keeps, so the setext spelling stood
        // half a point taller than its ATX twin for no reason the page has.
        // Concealed source with nothing to hold takes `collapsedLine`.
        #expect(same(layout("Foo\n---").height,
                     layout("## Foo").height + BlockBoxes.collapsedLine))
    }

    /// A heading alone in a list item is the same `<h2>` with the `<li>`'s and
    /// `<ul>`'s margins collapsing straight out around it — neither has padding
    /// or a border to stop them — so the note measures what the bare heading
    /// does. `StyleApplier` used to add the rule's inset to the item's exported
    /// trailing gap *as well*, which this catches: it would stand 8.2pt taller.
    @Test func aHeadingInsideAListItemCountsItsRuleOnce() {
        #expect(same(layout("x\n\n- ## Foo\n\nbar").height, layout("x\n\n## Foo\n\nbar").height))
        #expect(same(spaceBelowLastLine("x\n\n- ## Foo", at: "## Foo"), metrics(16).headingRuleInset(2)))
    }

    /// A heading inside a **blockquote** is the same `<h1>` and keeps the same
    /// band, wherever in the quote it sits.
    ///
    /// The quote pass used to fold the inset into the gap between the quote's
    /// own interior lines, which is not where the space goes — it is padding,
    /// inside the heading — and it only did it when another non-blank quote
    /// line followed. So a heading that *ended* a quote, or one with a `>`
    /// blank line under it, reserved nothing at all and the note stood an inset
    /// short of its Preview while the rule itself was never drawn. Both
    /// spellings of "the heading is last" are here, because they failed for two
    /// different reasons.
    @Test func aHeadingInsideABlockquoteKeepsItsRulesPadding() {
        let m = metrics(16)
        #expect(same(spaceBelowLastLine("Intro\n\n> # Foo", at: "# Foo"), m.headingRuleInset(1)))
        #expect(same(spaceBelowLastLine("Intro\n\n> # Foo\n\nbar", at: "# Foo"),
                     m.headingRuleInset(1)))
        #expect(same(spaceBelowLastLine("Intro\n\n> ## Foo\n>\n> bar", at: "## Foo"),
                     m.headingRuleInset(2)))
        // …and the gap to the next box inside the quote is the block margin
        // and only that: the inset used to be added on top of it, so a quoted
        // heading with prose under it counted the same space twice.
        #expect(same(spaceBelowLastLine("Intro\n\n> ## Foo\n> bar", at: "## Foo"),
                     m.headingRuleInset(2) + m.blockGap))
        // h3 has no rule inside a quote either, for the same reason it has
        // none anywhere: the border is an h1/h2 declaration.
        #expect(spaceBelowLastLine("Intro\n\n> ### Foo", at: "### Foo") == 0)
    }

    /// And the mark the rule is drawn from is really there — on the line's
    /// first character, which inside a quote is the `>` and not the `#`. The
    /// fragment reads it at its own start, so a mark on the heading's text
    /// would reserve the space and draw nothing.
    @Test func aQuotedHeadingMarksItsRuleWhereTheFragmentLooks() {
        let text = "Intro\n\n> ## Foo"
        let document = EditorDocument(text: text, theme: EditorTheme(fontSize: 16))
        document.styleEverythingNow()
        let marker = (text as NSString).range(of: "> ## Foo").location
        #expect(document.storage.attribute(headingRuleAttribute, at: marker,
                                           effectiveRange: nil) as? Int == 2)
    }

    // MARK: - A rule at the end of the note

    /// `<hr>` is the one element whose bottom margin the end of the note does
    /// not take away. `hr::before` / `hr::after` are `display: table` — a
    /// clearfix — so the rule's margins never collapse out to the article's
    /// `:last-child`, which is what the stylesheet zeroes. Inside a list item
    /// that `:last-child` is the `<ul>` and not the rule, so the page keeps
    /// 24pt below it; the editor dropped it with every other last paragraph's,
    /// and the note ended 24pt above its own bottom.
    @Test func aRuleEndingAListKeepsItsBottomMargin() {
        let m = metrics(16)
        #expect(same(spaceBelowLastLine("- Foo\n- * * *", at: "* * *"), m.ruleGap))
        // Not at the top level: there the `<hr>` *is* the `:last-child` whose
        // own margin-bottom is being zeroed, so there is nothing to keep.
        #expect(spaceBelowLastLine("Foo\n\n* * *", at: "* * *") == 0)
        // And it is the *same* 24 with an item still to come, where the
        // ordinary `paragraphSpacing` is holding it — not 24 twice, which is
        // what copying rather than moving it would have given.
        #expect(same(spaceBelowLastLine("- Foo\n- * * *\n- Bar", at: "* * *"), m.ruleGap))
    }

    /// The whole note, added up by hand: one item's line, `li + li`, and the
    /// rule with a 24pt margin on each side. It measured 24 short.
    @Test func aNoteEndingInARuleAddsUpToWhatThePageDraws() {
        let m = metrics(16)
        #expect(same(layout("- Foo\n- * * *").height,
                     m.bodyLineHeight + m.listItemGap + m.ruleGap + m.ruleThickness + m.ruleGap))
    }

    /// Two rules with nothing between them: 4pt of rule, one 24pt gap (the two
    /// adjoining margins collapse to a `max`, not a sum) and 4pt of rule. The
    /// top margin of the first and the bottom of the last are the ones the
    /// article zeroes.
    ///
    /// It used to measure 48 — two 24pt lines — because a document *opening*
    /// with `---` and closing with `---` was read as YAML front matter, and
    /// front matter is laid out as its own source. GFM spec #68.
    @Test func twoRulesInARowCollapseTheirAdjoiningMargins() {
        let m = metrics(16)
        #expect(same(layout("---\n---").height, m.ruleThickness + m.ruleGap + m.ruleThickness))
    }

    // MARK: - `pre { padding-bottom }`

    /// A code box's bottom padding is space **below the listing**, and for the
    /// whole life of the editor it was not: it was reserved as extra line
    /// height with the glyphs "lifted off it" by a negative `.baselineOffset`,
    /// and that lift moves the *reported* baseline and not the ink. The two
    /// cancelled exactly, so a one-line indented code block put its listing
    /// hard against the bottom of its own box while every height agreed.
    ///
    /// It is invisible to anything that reads a paragraph style or a baseline —
    /// `render-parity.sh`'s baseline column reads `glyphOrigin`, which has the
    /// offset already applied, so the instrument confirms its own input. What
    /// can see it is where the last line *ends* relative to where the box does,
    /// which is what this measures.
    @Test func aCodeBoxKeepsItsPaddingBelowTheListing() {
        let m = metrics(16)
        #expect(same(spaceBelowLastLine("    Zulu", at: "Zulu"), m.codePadding))
        // …and the box is still the same height it always measured: the
        // padding moved out of the line box, it did not appear or vanish.
        #expect(same(layout("    Zulu").height, m.codeLineHeight + 2 * m.codePadding))
    }

    /// The gap below a code block with something after it is the padding *and*
    /// the block's own margin — one inside the box and one outside it, which is
    /// exactly the pair `bottomMargin` and `paragraphSpacing` are.
    @Test func aCodeBoxWithABlockAfterItKeepsBoth() {
        let m = metrics(16)
        #expect(same(spaceBelowLastLine("    Zulu\nAfter.", at: "Zulu"),
                     m.codePadding + m.blockGap))
        // With a blank line typed between them the margin is the blank line's
        // — a blank run *is* the gap between two boxes here, so the fragment
        // keeps only the padding, which is the half that is inside the box.
        #expect(same(spaceBelowLastLine("    Zulu\n\nAfter.", at: "Zulu"), m.codePadding))
    }

    /// Once per **paragraph**, not once per wrapped line — the property that
    /// rules out putting the padding back into `minimumLineHeight`.
    /// `StyleApplier` styles without knowing the pane's width, so a listing
    /// that wraps to three visual lines would have paid it three times.
    @Test func aWrappedListingPaysItsPaddingOnce() {
        let m = metrics(16)
        let long = "    " + String(repeating: "zulu ", count: 60)
        let l = layout(long, width: 260)
        guard let fragment = l.fragment(at: 6), let last = fragment.textLineFragments.last else {
            Issue.record("no fragment")
            return
        }
        #expect(fragment.textLineFragments.count > 2)     // it really did wrap
        #expect(same(fragment.layoutFragmentFrame.height - last.typographicBounds.maxY,
                     m.codePadding))
    }

    /// The same band, made by the other three sites that reserve it — a fence
    /// with no closing delimiter, a code block inside a list item, and one
    /// inside a blockquote. One mechanism, so one measurement finds all of them.
    @Test func everySiteThatReservesThePaddingReservesTheSameBand() {
        let m = metrics(16)
        #expect(same(spaceBelowLastLine("```\nlet x = 1", at: "let x"), m.codePadding))
        #expect(same(spaceBelowLastLine("- foo\n\n      bar", at: "bar"), m.codePadding))
        #expect(same(spaceBelowLastLine(">     foo", at: "foo"), m.codePadding))
    }
}
