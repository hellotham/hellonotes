//
//  GFMBoxMetricsTests.swift
//  MarkdownCoreTests
//
//  The box model is shared by two renderers that cannot see each other: the
//  live editor turns it into `NSParagraphStyle`s, the Preview turns it into
//  CSS. These tests are what keeps the turning honest — that the stylesheet
//  states the same numbers the editor lays out with, and that the rules which
//  are easy to get subtly wrong (collapsing margins, integral line heights)
//  stay right.
//

import Foundation
import Testing
@testable import MarkdownCore

@Suite struct GFMBoxMetricsTests {

    /// GitHub's own type scale, which the editor's used not to be: it had
    /// 1.7/1.4/1.2/1.1/1/1 where the stylesheet has 2/1.5/1.25/1/.875/.85, so
    /// an h1 was 26pt in Edit and 32pt in Preview.
    @Test func theTypeScaleIsGitHubs() {
        let m = GFMBoxMetrics(base: 16)
        #expect(m.headingSize(1) == 32)
        #expect(m.headingSize(2) == 24)
        #expect(m.headingSize(3) == 20)
        #expect(m.headingSize(4) == 16)
        #expect(m.headingSize(5) == 14)
        #expect(abs(m.headingSize(6) - 13.6) < 0.001)
        // Out-of-range levels clamp rather than trap.
        #expect(m.headingSize(0) == m.headingSize(1))
        #expect(m.headingSize(9) == m.headingSize(6))
    }

    /// At GitHub's own 16px root, every box metric is the value in the
    /// stylesheet. Away from it they scale together, which is the whole reason
    /// they are expressed as multiples of `base`: Text Size used to grow the
    /// type and leave the margins, so the layout got tighter as the text got
    /// bigger.
    @Test func theBoxModelIsGitHubsAndScalesWholesale() {
        let m = GFMBoxMetrics(base: 16)
        #expect(m.blockGap == 16)
        #expect(m.headingTopGap == 24)
        #expect(m.listIndent == 32)
        #expect(m.listItemGap == 4)
        #expect(m.quotePadding == 16)
        #expect(m.quoteBorder == 4)
        #expect(m.codePadding == 16)
        #expect(m.ruleThickness == 4)
        #expect(m.ruleGap == 24)
        #expect(m.cellPadY == 6)
        #expect(m.cellPadX == 13)

        let doubled = GFMBoxMetrics(base: 32)
        #expect(doubled.blockGap == 2 * m.blockGap)
        #expect(doubled.listIndent == 2 * m.listIndent)
        #expect(doubled.quoteIndent == 2 * m.quoteIndent)
        #expect(doubled.codePadding == 2 * m.codePadding)
    }

    /// Every line height is a whole point. WebKit does not use a fractional
    /// one as given — `line-height: 19.72px` laid code out 19px apart — so a
    /// fractional value is a value the two engines disagree about.
    @Test func lineHeightsAreIntegral() {
        for base in stride(from: CGFloat(9), through: 40, by: 0.4) {
            let m = GFMBoxMetrics(base: base)
            #expect(m.bodyLineHeight == m.bodyLineHeight.rounded(), "body at \(base)")
            #expect(m.codeLineHeight == m.codeLineHeight.rounded(), "code at \(base)")
            for level in 1...6 {
                #expect(m.headingLineHeight(level) == m.headingLineHeight(level).rounded(),
                        "h\(level) at \(base)")
            }
        }
    }

    /// Adjacent vertical margins **collapse**: the space between a paragraph
    /// and the heading after it is the larger of the two, not their sum.
    /// TextKit adds instead, which is why the editor asks for this number
    /// rather than setting both halves itself.
    @Test func adjacentMarginsCollapse() {
        let m = GFMBoxMetrics(base: 16)
        #expect(m.gap(after: .paragraph, before: .heading(level: 2)) == 24)
        #expect(m.gap(after: .heading(level: 2), before: .paragraph) == 16)
        #expect(m.gap(after: .paragraph, before: .paragraph) == 16)
        #expect(m.gap(after: .heading(level: 1), before: .heading(level: 2)) == 24)
        // Not the sum, in the case where the sum is the tempting answer.
        #expect(m.gap(after: .paragraph, before: .heading(level: 2))
                < m.marginBottom(.paragraph) + m.marginTop(.heading(level: 2)))
    }

    /// A tight list separates its items by `li + li`; a loose one by the
    /// margin on the `<p>` cmark wraps each item's content in. Only the item
    /// that ends the list outright carries the list's own bottom margin —
    /// `ul ul { margin-bottom: 0 }`.
    @Test func listItemMargins() {
        let m = GFMBoxMetrics(base: 16)
        #expect(m.marginTop(.listItem(top: .opensList, lastInList: false)) == 0)
        #expect(m.marginTop(.listItem(top: .sibling(loose: false), lastInList: false)) == 4)
        #expect(m.marginTop(.listItem(top: .sibling(loose: true), lastInList: false)) == 16)
        #expect(m.marginTop(.listItem(top: .opensNestedList(looseParent: false), lastInList: false)) == 0)
        #expect(m.marginTop(.listItem(top: .opensNestedList(looseParent: true), lastInList: false)) == 16)
        #expect(m.marginBottom(.listItem(top: .sibling(loose: false), lastInList: false)) == 0)
        #expect(m.marginBottom(.listItem(top: .sibling(loose: false), lastInList: true)) == 16)
    }

    /// The stylesheet has to *say* what the editor lays out. Anything stated as
    /// a ratio, or left at github-markdown-css's own px constant, is a number
    /// only one of the two surfaces is using.
    @Test func theStylesheetStatesTheSameNumbers() throws {
        for base in [CGFloat(12.8), 16, 24] {
            let m = GFMBoxMetrics(base: base)
            let css = m.css
            func has(_ needle: String) -> Bool { css.contains(needle) }
            func px(_ v: CGFloat) -> String {
                var s = String(format: "%.4f", Double(v))
                while s.hasSuffix("0") { s.removeLast() }
                if s.hasSuffix(".") { s.removeLast() }
                return s + "px"
            }
            #expect(has("font-size: \(px(base))"), "base at \(base)")
            #expect(has("line-height: \(px(m.bodyLineHeight))"), "body line height at \(base)")
            #expect(has("line-height: \(px(m.codeLineHeight))"), "code line height at \(base)")
            for level in 1...6 {
                #expect(has("font-size: \(px(m.headingSize(level)))"), "h\(level) at \(base)")
                #expect(has("line-height: \(px(m.headingLineHeight(level)))"), "h\(level) leading at \(base)")
            }
            #expect(has("margin-top: \(px(m.headingTopGap))"), "heading margin at \(base)")
            #expect(has("margin-bottom: \(px(m.blockGap))"), "block gap at \(base)")
            #expect(has("padding-left: \(px(m.listIndent))"), "list indent at \(base)")
            #expect(has("margin-top: \(px(m.listItemGap))"), "li+li at \(base)")
            #expect(has("padding: 0 \(px(m.quotePadding))"), "quote padding at \(base)")
            #expect(has("border-left-width: \(px(m.quoteBorder))"), "quote bar at \(base)")
            #expect(has("padding: \(px(m.codePadding))"), "code padding at \(base)")
            #expect(has("height: \(px(m.ruleThickness))"), "hr at \(base)")
            #expect(has("padding: \(px(m.cellPadY)) \(px(m.cellPadX))"), "cells at \(base)")
            // Nothing may be left as a unitless ratio: WebKit resolves those
            // itself, and it does not resolve them the way TextKit does.
            #expect(!css.contains("line-height: 1.45"), "code leading left as a ratio at \(base)")
            #expect(!css.contains("line-height: 1.25"), "heading leading left as a ratio at \(base)")
        }
    }
}
