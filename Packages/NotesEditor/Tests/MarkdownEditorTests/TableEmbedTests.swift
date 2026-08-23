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

    private static func blankImage(_ size: CGSize) -> PlatformImage {
        #if canImport(AppKit)
        return NSImage(size: size)
        #else
        return UIGraphicsImageRenderer(size: size).image { _ in }
        #endif
    }

    /// Collapse the document's table and return the paragraph style the band
    /// landed on.
    private func bandStyle(for text: String, imageHeight: CGFloat) async throws
        -> (document: EditorDocument, style: NSParagraphStyle)
    {
        let document = EditorDocument(
            text: text,
            services: EditorServices(
                blockRenderer: FixedSizeRenderer(size: CGSize(width: 120, height: imageHeight))))
        // Caret at the very end, so the table itself is never revealed.
        document.selectionDidChange(NSRange(location: (text as NSString).length, length: 0))

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
