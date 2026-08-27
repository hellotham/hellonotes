//
//  ScreenRenderTests.swift
//  HelloNotesTests
//
//  Created by Chris Tham on 27/8/2026.
//
//  Does the screen paint anything at all?
//
//  A weaker check than it first looks, and the limit is worth stating because
//  the obvious reading is wrong. This renders a view offscreen with
//  `ImageRenderer` and counts glyph pixels, so it catches a screen that draws
//  *nothing* — a view whose body throws everything away, a section that renders
//  empty.
//
//  **It does not catch the nested-`Form` bug that shipped in build 11.** That
//  was tested here first, with `Form { LLMSettingsForm(…) }` as a negative
//  control, and the control failed twice: offscreen, the nested form and the
//  plain one render *identically* (48,534 glyph pixels each). The collapse
//  needs a live navigation hierarchy, which `ImageRenderer` does not build. The
//  first attempt was worse still — counting "not white" scored both at 312,000,
//  the entire canvas, because a grouped form fills its background with a light
//  grey.
//
//  Both failures were the control doing its job. A check of this kind without
//  one is a check that quietly starts passing for everything, which is how the
//  parity tests that preceded it came to certify a screen that had never once
//  drawn. The nesting check lives in `HelloNotesUITests`, where the app is
//  really launched and really navigated.
//

import Testing
import SwiftUI
@testable import HelloNotes

#if os(iOS)
import UIKit

@MainActor
struct ScreenRenderTests {

    /// How much of the view actually painted.
    ///
    /// **Not a height.** A `Form` is a scrolling viewport, so it reports the
    /// size it is *offered* rather than the size it *contains* — the same rule
    /// that governs every representable in this app — and `sizeThatFits`
    /// answered 0 for a perfectly healthy form. What distinguishes a screen
    /// from a collapsed one is whether anything was drawn, so that is what is
    /// measured: pixels differing from the background.
    private func paintedPixels<V: View>(_ view: V,
                                        size: CGSize = CGSize(width: 390, height: 800)) -> Int {
        let renderer = ImageRenderer(content:
            view.frame(width: size.width, height: size.height).background(.white))
        renderer.scale = 1
        guard let cg = renderer.uiImage?.cgImage else { return 0 }

        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &bytes, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        // **Dark pixels — i.e. glyphs.** The first attempt counted anything
        // that was not white, and the negative control caught it immediately:
        // a healthy form and a collapsed one both scored 312,000, the entire
        // canvas, because a grouped form fills its background with a light grey
        // that is "not white". Text is what distinguishes a screen with rows on
        // it from a screen with one clipped header, so text is what is counted.
        var painted = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let r = Int(bytes[index]), g = Int(bytes[index + 1]), b = Int(bytes[index + 2])
            // Rec. 601 luma, integer arithmetic.
            if (299 * r + 587 * g + 114 * b) / 1000 < 140 { painted += 1 }
        }
        return painted
    }

    /// The screen that shipped broken.
    @Test func aiSettingsDrawsItsContent() {
        let painted = paintedPixels(LLMSettingsForm(settings: LLMSettings()))
        #expect(painted > 2_000,
                "AI settings painted \(painted) glyph pixels — that is a collapsed form, not a screen")
    }

    /// The folder-convention rows, which carry four of the fields that had no
    /// label on iOS.
    @Test func folderSettingsDrawTheirRows() {
        let painted = paintedPixels(Form { FolderConventionSections() })
        #expect(painted > 2_000, "folder settings painted \(painted) pixels")
    }
}
#endif
