//
//  TableEmbedTests.swift
//  MarkdownEditorTests
//
//  A table's source is replaced by a picture of it, and the space reserved for
//  that picture has to be the picture *plus the block's own bottom margin*.
//
//  Cross-platform on purpose. The collapse-and-band step was `#if
//  canImport(AppKit)` for its whole life, which is how iOS shipped a table that
//  stayed as pipes and dashes; the gate that would have caught it is a test
//  that runs on both.
//

import CoreGraphics
import Foundation
import Testing
@testable import MarkdownCore
@testable import MarkdownEditor

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@MainActor
@Suite struct TableEmbedTests {

    /// Any block, one fixed picture — the band is what is under test, not the
    /// drawing.
    private struct FixedSizeRenderer: BlockRenderer {
        let size: CGSize
        func render(_ kind: BlockEmbedKind, maxWidth: CGFloat, darkMode: Bool) async -> PlatformImage? {
            blankImage(size)
        }
    }

    /// `nonisolated`, because `BlockRenderer` is: the witness above cannot be
    /// `@MainActor`, so nothing it calls may be either. The suite is
    /// `@MainActor` and this is the one member reached from outside it.
    private nonisolated static func blankImage(_ size: CGSize) -> PlatformImage {
        #if canImport(AppKit)
        return NSImage(size: size)
        #else
        return UIGraphicsImageRenderer(size: size).image { _ in }
        #endif
    }

    /// Collapse the document's table and return the paragraph style the band
    /// landed on.
    private func bandStyle(for text: String, imageHeight: CGFloat, caret: Int? = nil) async throws
        -> (document: EditorDocument, style: NSParagraphStyle)
    {
        let document = EditorDocument(
            text: text,
            services: EditorServices(
                blockRenderer: FixedSizeRenderer(size: CGSize(width: 120, height: imageHeight))))
        // Caret at the very end unless told otherwise, so the table itself is
        // never revealed.
        document.selectionDidChange(NSRange(location: caret ?? (text as NSString).length, length: 0))

        let table = try #require(document.blocks.first {
            if case .table = $0.kind { return true }
            return false
        }).range
        var marked = false
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(20))
            document.storage.enumerateAttribute(blockImageAttribute, in: table, options: []) { v, _, stop in
                if v != nil { marked = true; stop.pointee = true }
            }
            if marked { break }
        }
        #expect(marked, "the table never collapsed to its rendered image")
        #expect(document.text == text, "collapsing a table must not touch a byte of it")

        let last = table.location + table.length - 1
        let style = try #require(document.storage.attribute(.paragraphStyle, at: last,
                                                           effectiveRange: nil) as? NSParagraphStyle)
        return (document, style)
    }

    /// With a blank line below, the blank run is already holding the block's
    /// margin, so the band is the picture and nothing else. This is the
    /// control: added on top here, every rendered block in an ordinarily
    /// written note would stand 16pt low.
    @Test func aBlankLineBelowKeepsTheBandToThePictureAlone() async throws {
        let imageHeight: CGFloat = 50
        let (document, style) = try await bandStyle(
            for: "| a | b |\n| - | - |\n| 1 | 2 |\n\n> quoted", imageHeight: imageHeight)
        #expect(style.paragraphSpacing == imageHeight)
        #expect(document.theme.metrics.blockGap == 16)
    }

    /// With the next block butted straight against it the gap has nowhere else
    /// to live, so the band carries it. It used not to: the band's style
    /// *replaces* the one `StyleApplier` laid down, and that is where the
    /// collapsed CSS margin sits when no blank run holds it — so a table with a
    /// blockquote on the very next line, which is how the GFM specification
    /// writes one, lost its `margin-bottom: 16` the moment its picture arrived.
    @Test func anAdjacentBlockGetsItsMarginOutOfTheBand() async throws {
        let imageHeight: CGFloat = 50
        let (document, style) = try await bandStyle(
            for: "| a | b |\n| - | - |\n| 1 | 2 |\n> quoted", imageHeight: imageHeight)
        #expect(style.paragraphSpacing == imageHeight + document.theme.metrics.blockGap)
    }

    /// Two identical tables are two pictures. They share one render — one cache
    /// key — and the second used to be turned away while the first was drawing
    /// and then never collapsed, because only the block that started a render
    /// was refreshed when it landed: a table (or a diagram) written twice kept
    /// its second copy as pipes and dashes.
    @Test func identicalTablesAreBothDrawn() async throws {
        let table = "| a | b |\n| - | - |\n| 1 | 2 |"
        let text = "\(table)\n\nBetween\n\n\(table)\n\nAfter"
        let document = EditorDocument(
            text: text,
            services: EditorServices(
                blockRenderer: FixedSizeRenderer(size: CGSize(width: 120, height: 50))))
        document.selectionDidChange(NSRange(location: (text as NSString).length, length: 0))
        document.styleEverythingNow()
        var pictures = 0
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(20))
            pictures = 0
            document.storage.enumerateAttribute(
                blockImageAttribute, in: NSRange(location: 0, length: document.storage.length),
                options: []) { v, _, _ in if v != nil { pictures += 1 } }
            if pictures == 2 { break }
        }
        #expect(pictures == 2, "the second of two identical tables was never drawn")
    }

    /// The picture starts where the block starts, as the page's `<table>` does
    /// — mid-note, opening the note, and ending it, where the band is made of
    /// the line box instead (`blockImageTopAttribute`). The concealed source
    /// lines above it are pinned to 0.01 each and may come first; nothing else
    /// may.
    @Test(arguments: ["Above\n\n| a | b |\n| - | - |\n| 1 | 2 |\n\nBelow",
                      "| a | b |\n| - | - |\n| 1 | 2 |\n\nBelow",
                      "Above\n\n| a | b |\n| - | - |\n| 1 | 2 |"])
    func thePictureStartsWhereTheBlockDoes(text: String) async throws {
        // The caret somewhere the table is not: before it, or after it.
        let (document, _) = try await bandStyle(for: text, imageHeight: 50,
                                                caret: text.hasPrefix("Above") ? 0 : nil)
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        let fragments = RenderedBlockLayoutDelegate()
        layoutManager.delegate = fragments
        let container = NSTextContainer(size: CGSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = EditorMetrics.lineFragmentPadding
        layoutManager.textContainer = container
        contentStorage.addTextLayoutManager(layoutManager)
        contentStorage.textStorage?.setAttributedString(document.storage)
        layoutManager.ensureLayout(for: layoutManager.documentRange)

        let tableStart = (text as NSString).range(of: "| a |").location
        var blockTop: CGFloat?
        var picture: CGRect?
        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location,
                                                   options: [.ensuresLayout]) { fragment in
            let offset = contentStorage.offset(from: contentStorage.documentRange.location,
                                               to: fragment.rangeInElement.location)
            if offset == tableStart { blockTop = fragment.layoutFragmentFrame.minY }
            if let frame = (fragment as? RenderedBlockFragment)?.pictureFrame() { picture = frame }
            return true
        }
        let top = try #require(blockTop)
        let drawn = try #require(picture, "no fragment draws the table's picture")
        // The concealed source lines are 0.01 each; the picture may start
        // below them, and nowhere lower.
        #expect(abs(drawn.minY - top) <= 0.05, "picture at \(drawn.minY), block at \(top)")
        #expect(drawn.height == 50)
    }

    /// A table that is not one — GFM refuses a delimiter row whose cell count
    /// does not match its header — draws no picture, and its source stays on
    /// screen at full height. Rendered anyway, the editor showed a grid where
    /// the page shows three lines of prose.
    @Test func aMismatchedDelimiterRowIsNeverCollapsed() async throws {
        let text = "| abc | def |\n| --- |\n| bar |"
        let document = EditorDocument(
            text: text,
            services: EditorServices(
                blockRenderer: FixedSizeRenderer(size: CGSize(width: 120, height: 50))))
        document.selectionDidChange(NSRange(location: (text as NSString).length, length: 0))
        try await Task.sleep(for: .milliseconds(200))

        #expect(!document.blocks.contains { if case .table = $0.kind { return true }; return false })
        var marked = false
        document.storage.enumerateAttribute(
            blockImageAttribute, in: NSRange(location: 0, length: document.storage.length),
            options: []) { v, _, stop in
                if v != nil { marked = true; stop.pointee = true }
            }
        #expect(!marked)
    }
}
