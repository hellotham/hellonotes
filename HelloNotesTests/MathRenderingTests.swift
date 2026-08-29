//
//  MathRenderingTests.swift
//  HelloNotesTests
//
//  Created by Chris Tham on 29/8/2026.
//
//  Which way up is the maths?
//
//  `MathImageRenderer` produced **vertically flipped** images on iOS and nothing
//  noticed. `iOSEditorSnapshotTests` renders maths on this platform and passed
//  the whole time, because a snapshot test that checks an image *exists* cannot
//  see that it is upside down. On screen it was unmistakable — `dx` rendered as
//  `qx`, the `²` exponent sat where a subscript goes, and `√π/2` came out with
//  the 2 on top — and it was found by opening a note, not by any test.
//
//  So the check is a *relative* one, which is what makes it robust: render the
//  same glyph with a superscript and with a subscript, and compare where each
//  puts its ink. Upright, `A²` is top-heavy relative to `A₂`. Flipped, the
//  relationship inverts. No absolute pixel positions, no font metrics, nothing
//  that drifts when SwiftMath changes a glyph.
//

import Testing
import Foundation
import CoreGraphics
@testable import HelloNotes

#if os(iOS)
import UIKit

@MainActor
struct MathRenderingTests {

    /// What fraction of a rendered formula's ink sits in the upper half.
    private func topInkFraction(_ latex: String) throws -> Double {
        let image = try #require(
            MathImageRenderer.image(latex: latex, fontSize: 34, color: .white),
            "renderer returned nothing for \(latex)")
        let cg = try #require(image.cgImage)

        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try #require(CGContext(
            data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Alpha, not luminance: the glyphs are white on transparent.
        var top = 0, bottom = 0
        for y in 0..<h {
            for x in 0..<w where bytes[(y * w + x) * 4 + 3] > 40 {
                if y < h / 2 { top += 1 } else { bottom += 1 }
            }
        }
        let total = top + bottom
        #expect(total > 0, "\(latex) rendered no ink at all")
        return total == 0 ? 0 : Double(top) / Double(total)
    }

    /// The orientation check.
    ///
    /// A `CGImage` drawn upside down still has ink, still has the right size and
    /// still round-trips through every existing assertion — the *only* thing
    /// that changes is where the ink is, so that is what this measures.
    @Test func aSuperscriptRendersAboveASubscript() throws {
        let superscript = try topInkFraction("A^{2}")
        let subscripted = try topInkFraction("A_{2}")
        #expect(superscript > subscripted,
                "A² put \(superscript) of its ink up top and A₂ put \(subscripted) — if that is the wrong way round the maths is rendering flipped")
    }

    /// A second, independent angle: a fraction's numerator is above its bar.
    /// `\frac{1}{2222}` is deliberately bottom-heavy in glyph count, so an
    /// upright render puts *less* than half its ink in the top half.
    @Test func aFractionsDenominatorIsBelowIt() throws {
        let fraction = try topInkFraction("\\frac{1}{2222}")
        #expect(fraction < 0.5,
                "the numerator side holds \(fraction) of the ink — a wide denominator should outweigh a single digit, so this reads as inverted")
    }
    /// Where does the fault live: the shared capture helper, or the maths label?
    ///
    /// `PlatformImageKit.cgImage` is generic — "render a laid-out view" — so if
    /// it flips *any* view the fix belongs there, and if it only flips
    /// `MTMathUILabel` then the helper is fine and the maths path is doing
    /// something of its own. Guessing between those two would put the fix in the
    /// wrong place and break the other caller the day one arrives.
    @Test func theCaptureHelperIsUprightForAnOrdinaryView() throws {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        view.backgroundColor = .clear
        // Opaque block in the TOP half only.
        let marker = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 20))
        marker.backgroundColor = .white
        view.addSubview(marker)
        view.layoutIfNeeded()

        let cg = try #require(PlatformImageKit.cgImage(of: view, scale: 1))
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try #require(CGContext(
            data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var top = 0, bottom = 0
        for y in 0..<h {
            for x in 0..<w where bytes[(y * w + x) * 4 + 3] > 40 {
                if y < h / 2 { top += 1 } else { bottom += 1 }
            }
        }
        #expect(top > bottom,
                "a block placed in the view's top half came back with \(top) px up top and \(bottom) below — the shared helper itself is flipping")
    }

}
#endif
