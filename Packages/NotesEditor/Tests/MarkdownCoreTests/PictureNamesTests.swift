//
//  PictureNamesTests.swift
//  MarkdownCoreTests
//
//  Which names an `![[…]]` embed draws as a picture.
//

import Foundation
import Testing
@testable import MarkdownCore

@Suite struct PictureNamesTests {
    @Test func aPictureIsKnownByItsExtensionInAnyCase() {
        for name in ["a.png", "a.PNG", "Pasted image 20241122123456.png", "photo.JPEG", "scan.heic",
                     "x.webp", "x.avif", "x.svg", "x.tif", "assets/a.gif"] {
            #expect(PictureNames.isPicture(name), "\(name)")
        }
        for name in ["Meeting notes", "report.pdf", "notes.md", "v1.png/notes", "png", ".png."] {
            #expect(!PictureNames.isPicture(name), "\(name)")
        }
    }

    /// The name an embed gives: before its alias's pipe — an escaped one in a
    /// table's row too — and before any `#…`.
    @Test func anEmbedsNameStopsAtItsPipeAndItsSubpath() {
        #expect(PictureNames.embedTarget("photo.png|300") == "photo.png")
        #expect(PictureNames.embedTarget("photo.png\\|300") == "photo.png")
        #expect(PictureNames.embedTarget(" assets/photo.png#x ") == "assets/photo.png")
        #expect(PictureNames.embedTarget("Note") == "Note")
    }

    /// Obsidian's size: after the last pipe, a width or a width and height,
    /// whole numbers above nought — in a description and in an embed alike.
    @Test func aSizeIsTheLastThingAfterAPipe() {
        func size(_ text: String) -> [Int?]? {
            PictureNames.sizeSuffix(of: text).map { [$0.width, $0.height] }
        }
        #expect(size("A cat|300") == [300, nil])
        #expect(size("|300") == [300, nil])
        #expect(size("A cat|300x200") == [300, 200])
        #expect(size("A cat|300X200") == [300, 200])
        #expect(size("cat.png|A cat|120") == [120, nil])
        #expect(size("cat.png\\|120") == [120, nil])
        #expect(size(" A cat | 300 ") == [300, nil])
        // Words, not sizes.
        for text in ["A cat", "300", "A cat|x300", "A cat|300x", "A cat|0", "A cat|300x0",
                     "A cat|30 0", "A cat|-3", "A cat|3.5", "A cat|٣٠٠"] {
            #expect(size(text) == nil, "\(text)")
        }
        // No wider or taller than `largestSize`: past it, a size asked Edit
        // for a bitmap no device can make, and the pixel count trapped.
        #expect(size("A cat|10000x10000") == [10_000, 10_000])
        for text in ["A cat|10001", "A cat|300x10001", "A cat|100x9223372036854775807",
                     "A cat|99999999999999999999"] {
            #expect(size(text) == nil, "\(text)")
        }
    }

    /// The size a page draws `<img width height>` at under `max-width: 100%`.
    @Test func aPictureIsDrawnAtTheSizeAskedForAndNeverPastThePane() {
        let natural = CGSize(width: 40, height: 20)
        func drawn(_ width: Int?, _ height: Int?, max: CGFloat = 600) -> CGSize {
            PictureNames.drawnSize(natural: natural, maxWidth: max, width: width, height: height)
        }
        #expect(drawn(nil, nil) == natural)                                   // its own, not up
        #expect(PictureNames.drawnSize(natural: CGSize(width: 1200, height: 600), maxWidth: 600,
                                       width: nil, height: nil) == CGSize(width: 600, height: 300))
        #expect(drawn(100, nil) == CGSize(width: 100, height: 50))            // up past its own
        #expect(drawn(30, 30) == CGSize(width: 30, height: 30))               // both, as given
        #expect(drawn(900, nil, max: 300) == CGSize(width: 300, height: 150)) // down to the pane
        #expect(drawn(900, 100, max: 300) == CGSize(width: 300, height: 100)) // a height stays
    }
}
