//
//  TextColumnTests.swift
//  MarkdownEditorTests
//
//  The pane's text column moves the *text*, never the view: the editor fills
//  its pane — its scroller at the pane's edge — and its text sits in the
//  column inside it. It used to be a frame around the editor, so the scroller
//  was the column's and, with the default settings, 32pt in from the window's
//  edge (build 28).
//
//  On the Mac the column goes through `textContainerOrigin`, which AppKit has
//  to honour for drawing *and* for hit-testing, or the caret lands beside the
//  word clicked. Both are checked here against a view with no column: the ink
//  and the character a click finds move by exactly the margin.
//

import Foundation
import Testing
@testable import MarkdownEditor

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@MainActor
@Suite struct TextColumnTests {

    // MARK: - The rule

    @Test("The whole pane, by default")
    func fullIsTheWholePane() {
        let column = TextColumn.full.resolve(in: 800)
        #expect(column.leading == 0 && column.width == 800 && !column.centred)
        #expect(TextColumn.full.margins(in: 800) == (0, 0))
    }

    @Test("A proportion stays at the leading edge; a measure that bites is centred")
    func proportionLeadsAndMeasureCentres() {
        let half = TextColumn(proportion: 0.5).resolve(in: 800)
        #expect(half.leading == 0 && half.width == 400 && !half.centred)
        #expect(TextColumn(proportion: 0.5).margins(in: 800) == (0, 400))

        let measured = TextColumn(measure: 300).resolve(in: 800)
        #expect(measured.leading == 250 && measured.width == 300 && measured.centred)
        #expect(TextColumn(measure: 300).margins(in: 800) == (250, 250))

        // A measure wider than the proportion does not bite, so nothing centres.
        let loose = TextColumn(proportion: 0.5, measure: 600).resolve(in: 800)
        #expect(loose.leading == 0 && loose.width == 400 && !loose.centred)
    }

    @Test("Never below the floor, never wider than the pane")
    func floorAndPane() {
        let floored = TextColumn(proportion: 0.5, floor: 320).resolve(in: 500)
        #expect(floored.width == 320)
        let narrow = TextColumn(proportion: 0.5, floor: 320).resolve(in: 250)
        #expect(narrow.width == 250, "a pane narrower than the floor is the column")
    }

    // MARK: - The editor

    /// Short lines, so a narrower column wraps none of them and every line
    /// starts with the same glyph in both views.
    static let note = (1...30).map { "Line \($0) of a note." }.joined(separator: "\n\n")
    static let size = CGSize(width: 600, height: 400)

    #if canImport(AppKit)

    private func editor(column: TextColumn) throws -> (MarkdownTextView, NSScrollView, NSWindow) {
        let document = EditorDocument(text: Self.note)
        document.styleEverythingNow()
        let (scrollView, textView) = MarkdownTextView.scrollableEditor(document: document)
        scrollView.frame = NSRect(origin: .zero, size: Self.size)
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Pinned: the Mac turns dark at sunset, and a picture's colours with it.
        window.appearance = NSAppearance(named: .aqua)
        window.contentView?.addSubview(scrollView)
        textView.textColumn = column
        let layoutManager = try #require(textView.textLayoutManager)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        window.contentView?.layoutSubtreeIfNeeded()
        textView.layoutSubtreeIfNeeded()
        return (textView, scrollView, window)
    }

    /// The leftmost column of ink in the view's visible part, in points.
    private func inkLeft(of view: NSView) throws -> CGFloat {
        let rect = view.visibleRect
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: rep)
        let scale = CGFloat(rep.pixelsWide) / rect.width
        var left = Int.max
        // The editor paints no background, so anything opaque is ink.
        for y in 0..<rep.pixelsHigh {
            for x in 0..<min(left, rep.pixelsWide) {
                if let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0.5 {
                    left = x
                    break
                }
            }
        }
        try #require(left != Int.max, "no ink in the editor")
        return CGFloat(left) / scale
    }

    @Test("A centred column moves the text, the ink and the click — not the view")
    func aCentredColumnMovesTheTextNotTheView() throws {
        let (plain, plainScroll, plainWindow) = try editor(column: .full)
        defer { plainWindow.contentView = nil }
        let (measured, scroll, window) = try editor(column: TextColumn(measure: 300))
        defer { window.contentView = nil }

        // The view still fills its pane.
        #expect(scroll.frame.width == Self.size.width && measured.frame.width == plain.frame.width,
                "the column narrowed the view rather than placing the text")
        #expect(plainScroll.frame.width == Self.size.width)

        // The text sits in the column: 150pt in from each side.
        let base = EditorMetrics.textContainerInset.width
        #expect(measured.textContainerOrigin.x == base + 150)
        let container = try #require(measured.textContainer?.size.width)
        #expect(abs(container - (300 - 2 * base)) < 0.5, "the container is \(container)pt, not the column's")

        // The ink moved by exactly the margin.
        let plainInk = try inkLeft(of: plain)
        let measuredInk = try inkLeft(of: measured)
        #expect(abs(measuredInk - plainInk - 150) <= 0.5,
                "the text drew at \(measuredInk) against \(plainInk) — not where the origin says")

        // And a click finds the same character, 150pt further right.
        let at = CGPoint(x: plain.textContainerOrigin.x + 60, y: plain.textContainerOrigin.y + 4)
        let plainIndex = plain.characterIndexForInsertion(at: at)
        let measuredIndex = measured.characterIndexForInsertion(at: CGPoint(x: at.x + 150, y: at.y))
        #expect(plainIndex > 0 && measuredIndex == plainIndex,
                "a click 150pt right of the same point found \(measuredIndex), not \(plainIndex)")
    }

    @Test("A proportion keeps the text at the leading edge and narrows the line")
    func aProportionNarrowsTheLineInPlace() throws {
        let (textView, _, window) = try editor(column: TextColumn(proportion: 0.5))
        defer { window.contentView = nil }
        let base = EditorMetrics.textContainerInset.width
        #expect(textView.textContainerOrigin.x == base)
        let container = try #require(textView.textContainer?.size.width)
        #expect(abs(container - (300 - 2 * base)) < 0.5)
        #expect(abs(textView.trailingTextInset - (300 + base)) < 0.5)
    }

    #else

    private func editor(column: TextColumn) throws -> (MarkdownUITextView, UIWindow) {
        let document = EditorDocument(text: Self.note)
        document.styleEverythingNow()
        let controller = UIViewController()
        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.size))
        window.rootViewController = controller
        window.isHidden = false
        controller.view.frame = window.bounds
        let textView = MarkdownUITextView.make(document: document)
        textView.frame = controller.view.bounds
        textView.textColumn = column
        controller.view.addSubview(textView)
        controller.view.layoutIfNeeded()
        textView.layoutIfNeeded()
        return (textView, window)
    }

    @Test("A centred column is in the left and right insets, and the view fills its pane")
    func aCentredColumnIsInTheInsets() throws {
        let (textView, window) = try editor(column: TextColumn(measure: 300))
        defer { window.isHidden = true }
        let base = EditorMetrics.textContainerInset.width
        #expect(textView.frame.width == Self.size.width)
        #expect(textView.textContainerInset.left == base + 150)
        #expect(textView.textContainerInset.right == base + 150)
    }

    @Test("A proportion keeps the text at the leading edge")
    func aProportionLeads() throws {
        let (textView, window) = try editor(column: TextColumn(proportion: 0.5))
        defer { window.isHidden = true }
        let base = EditorMetrics.textContainerInset.width
        #expect(textView.textContainerInset.left == base)
        #expect(textView.textContainerInset.right == base + 300)
    }

    #endif
}
