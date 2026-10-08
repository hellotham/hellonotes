//
//  TableImageMarkupTests.swift
//  HelloNotesTests
//
//  The picture the editor draws in place of a table shows each cell as the
//  page does — bold set semibold, code in its pill, a link as its text — and
//  not the Markdown typed into it. It drew `NSAttributedString(string: cell)`:
//  the source, asterisks, backticks and destinations included
//  (docs/implemented.md §51.27; seen on the HN-iPad simulator in
//  DefaultCollection's Intelligence.md).
//
//  Read from pixels, because what is drawn is the claim. Each test compares a
//  band of the picture — one row of the grid, found by the geometry the
//  renderer lays out from — against another band the page draws identically.
//

import Foundation
import CoreGraphics
import Testing
import MarkdownCore
import MarkdownEditor
@testable import HelloNotes
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@MainActor
@Suite struct TableImageMarkupTests {

    private let theme = EditorTheme(fontSize: 16)

    private func image(_ source: String, isDark: Bool = false) throws -> PlatformImage {
        try #require(TableImageRenderer.image(source: source, maxWidth: 800, fontSize: 16, isDark: isDark),
                     "no picture for \(source.debugDescription)")
    }

    // MARK: - What is drawn

    /// A link, a wiki link's alias and an escaped `*` are drawn as the text the
    /// page shows: the picture is the size of the plain text's, and its ink
    /// covers the same span. Drawn as source, the destination made both wider.
    @Test func aLinkIsDrawnAsItsTextNotItsSource() throws {
        let pairs: [(markup: String, shown: String)] = [
            ("[link text](https://example.com/a/rather/long/path)", "link text"),
            // In a table the alias's pipe is escaped, or it divides the cell.
            ("[[Examples/Nested Note\\|shown instead]]", "shown instead"),
            ("a \\* b", "a * b"),
        ]
        for (markup, shown) in pairs {
            let marked = try raster(image("| \(markup) |\n| --- |\n| x |"))
            let plain = try raster(image("| \(shown) |\n| --- |\n| x |"))
            #expect(marked.width == plain.width && marked.height == plain.height,
                    "\(markup): \(marked.width)×\(marked.height) against \(plain.width)×\(plain.height)")
            let band = try rowBand(0, of: "| \(shown) |\n| --- |\n| x |")
            let a = try #require(inkExtent(marked, band: band), "nothing drawn for \(markup)")
            let b = try #require(inkExtent(plain, band: band), "nothing drawn for \(shown)")
            #expect(abs(a.lowerBound - b.lowerBound) <= 0.5 && abs(a.upperBound - b.upperBound) <= 0.5,
                    "\(markup) drew \(a), \(shown) draws \(b)")
        }
    }

    /// `**word**` in a body cell is the same ink as `word` in the header, which
    /// `th` sets semibold — and the control, plain `word` in a body cell, is
    /// not: regular is narrower.
    @Test func boldIsSetSemiboldAndWithoutItsAsterisks() throws {
        let source = "| word |\n| --- |\n| **word** |"
        let picture = try raster(image(source))
        let header = try #require(inkExtent(picture, band: rowBand(0, of: source)))
        let body = try #require(inkExtent(picture, band: rowBand(1, of: source)))
        #expect(abs(header.lowerBound - body.lowerBound) <= 0.5
                && abs(header.upperBound - body.upperBound) <= 0.5,
                "**word** drew \(body); the header's semibold word is \(header)")

        let control = "| word |\n| --- |\n| word |"
        let plain = try raster(image(control))
        let plainHeader = try #require(inkExtent(plain, band: rowBand(0, of: control)))
        let plainBody = try #require(inkExtent(plain, band: rowBand(1, of: control)))
        #expect(plainHeader.upperBound - plainBody.upperBound >= 0.5,
                "the control: regular \(plainBody) should be narrower than semibold \(plainHeader)")
    }

    /// `` `code` `` sits in GitHub's pill — `code { padding: .2em .4em;
    /// background: --bgColor-neutral-muted }` — so the cell's padding band
    /// left of the text is filled with the pill's colour, and the text starts
    /// a pill's padding in. Drawn as source, it was bare backticks.
    @Test func codeSitsInItsPill() throws {
        let source = "| `code` |\n| --- |\n| x |"
        let picture = try raster(image(source))
        let band = try rowBand(0, of: source)
        let mid = (band.lowerBound + band.upperBound) / 2
        let m = theme.metrics
        let textLeft = m.hairline + m.cellPadX
        let pill = picture.pixel(at: textLeft + m.inlineCodePadX / 2, mid)
        // #818b98 at 12.2%, premultiplied: about (16, 17, 19, 31).
        #expect(pill.a >= 15 && pill.a <= 60, "no pill left of the code: \(pill)")
        #expect(abs(pill.r - 16) <= 8 && abs(pill.g - 17) <= 8 && abs(pill.b - 19) <= 8,
                "the pill is not GitHub's colour: \(pill)")

        // The pill spans the code and its padding. Read between the outer grid
        // lines, which are painted too.
        let row = picture.row(at: mid)
        let inside = 4..<(picture.width - 4)
        let first = try #require(inside.first { row[$0].a >= 15 }, "nothing painted on the code's line")
        let last = try #require(inside.last { row[$0].a >= 15 })
        let painted = CGFloat(first) / 2 ... CGFloat(last + 1) / 2
        let mono = PlatformFont.monospacedSystemFont(ofSize: m.codeSize, weight: .regular)
        let expected = NSAttributedString(string: "code", attributes: [.font: mono]).size().width
            + 2 * m.inlineCodePadX
        #expect(abs((painted.upperBound - painted.lowerBound) - expected) <= 1.5,
                "the pill is \(painted), expected \(expected)pt wide from \(textLeft)")
        #expect(abs(painted.lowerBound - textLeft) <= 1, "the pill starts at \(painted.lowerBound)")
    }

    /// A header cell whose column declares no alignment (`---`) is centred, as
    /// the page centres a `th` by default; a declared one (`:--`) is not —
    /// the control. The picture set every header from the left, which no
    /// height can see and every screenshot does.
    @Test func aHeaderWithNoAlignmentOfItsOwnIsCentred() throws {
        let m = theme.metrics
        for (delimiter, centred) in [("---", true), (":--", false)] {
            let source = "| h |\n| \(delimiter) |\n| a much longer body cell |"
            let picture = try raster(image(source))
            let ink = try #require(inkExtent(picture, band: rowBand(0, of: source)))
            let grid = try #require(GFMTableGeometry.fitted(source: source, theme: theme, maxWidth: 800))
            let box = grid.columnTextWidths[0] + 2 * m.cellPadX
            let middle = m.hairline + box / 2
            if centred {
                #expect(abs((ink.lowerBound + ink.upperBound) / 2 - middle) <= 1,
                        "`\(delimiter)`: the header's ink \(ink) is not centred on \(middle)")
            } else {
                #expect(abs(ink.lowerBound - (m.hairline + m.cellPadX)) <= 1.5,
                        "`\(delimiter)`: the header's ink \(ink) does not start at the cell's padding")
            }
        }
    }

    /// The control for the colours: a dark table's text is light. The picture
    /// is drawn for the appearance it is asked for, whatever the process's is.
    @Test func aDarkTableIsDrawnInDarkInk() throws {
        let source = "| plain words |\n| --- |\n| x |"
        let picture = try raster(image(source, isDark: true))
        let band = try rowBand(0, of: source)
        var brightest = 0
        for y in Int(band.lowerBound * 2)..<Int(band.upperBound * 2) {
            for x in 0..<picture.width {
                let p = picture.pixel(x, y)
                guard p.a > 240 else { continue }
                brightest = max(brightest, min(p.r, p.g, p.b))
            }
        }
        #expect(brightest > 200, "dark text on a dark table: brightest opaque ink \(brightest)")
    }

    // MARK: - Reading the picture

    /// An image's pixels at 2×, top row first — RGBA, premultiplied, sRGB.
    private struct Raster {
        let width: Int, height: Int
        let data: [UInt8]
        func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let i = (y * width + x) * 4
            return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
        }
        /// The pixel at a point, in the image's own points.
        func pixel(at x: CGFloat, _ y: CGFloat) -> (r: Int, g: Int, b: Int, a: Int) {
            pixel(min(width - 1, Int(x * 2)), min(height - 1, Int(y * 2)))
        }
        func row(at y: CGFloat) -> [(r: Int, g: Int, b: Int, a: Int)] {
            let py = min(height - 1, Int(y * 2))
            return (0..<width).map { pixel($0, py) }
        }
    }

    private func raster(_ image: PlatformImage) throws -> Raster {
        #if canImport(AppKit)
        var rect = CGRect(origin: .zero, size: image.size)
        let cg = try #require(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        #else
        let cg = try #require(image.cgImage)
        #endif
        let w = Int((image.size.width * 2).rounded()), h = Int((image.size.height * 2).rounded())
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                             bytesPerRow: w * 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bytes = try #require(context.data)
        let buffer = UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: UInt8.self), count: w * h * 4)
        return Raster(width: w, height: h, data: Array(buffer))
    }

    /// Row `r`'s band, in points, from the geometry the renderer draws by —
    /// less a point at each edge, so the grid's own lines are not read as ink.
    private func rowBand(_ r: Int, of source: String) throws -> ClosedRange<CGFloat> {
        let grid = try #require(GFMTableGeometry.fitted(source: source, theme: theme, maxWidth: 800))
        let border = theme.metrics.hairline
        let top = border + grid.rowHeights[..<r].reduce(0) { $0 + $1 + border }
        return (top + 1)...(top + grid.rowHeights[r] - 1)
    }

    /// The horizontal span of what is drawn in `band`, in points: every pixel
    /// that differs from the band's own background — read just inside the left
    /// border — between the outer grid lines.
    private func inkExtent(_ raster: Raster, band: ClosedRange<CGFloat>) -> ClosedRange<CGFloat>? {
        let mid = (band.lowerBound + band.upperBound) / 2
        let background = raster.pixel(at: 4, mid)
        var lo: Int?, hi: Int?
        for y in Int(band.lowerBound * 2)..<Int(band.upperBound * 2) {
            for x in 4..<(raster.width - 4) {
                let p = raster.pixel(x, y)
                let difference = max(abs(p.r - background.r), abs(p.g - background.g),
                                     abs(p.b - background.b), abs(p.a - background.a))
                guard difference > 48 else { continue }
                lo = min(lo ?? x, x)
                hi = max(hi ?? x, x)
            }
        }
        guard let lo, let hi else { return nil }
        return CGFloat(lo) / 2 ... CGFloat(hi + 1) / 2
    }
}
