//
//  DiagramZoomViewTests.swift
//  HelloNotesTests
//
//  The app's half of the diagram zoom: which diagram it opens on, the note's
//  diagrams found by every spelling the editor draws, Preview's enlarge button
//  surviving the trip through cmark-gfm — and the zoom drawing the diagram the
//  note draws, the right way up, through the canvas it is shown in.
//
//  The editor's half — the button drawn, hit and pressed — is
//  `DiagramZoomTests` in the NotesEditor package.
//

import Testing
import Foundation
import CoreGraphics
import SwiftUI
import GFMRender
import MarkdownEditor
@testable import HelloNotes
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@Suite @MainActor
struct DiagramZoomViewTests {

    static let flow = "graph TD\n  A --> B"
    static let pie = "pie\n  \"x\" : 1"

    private static func fence(_ source: String) -> String { "```mermaid\n\(source)\n```" }

    /// Where each ```` ```mermaid ```` fence starts.
    private func fences(in text: String) -> [Int] {
        let ns = text as NSString
        var found: [Int] = []
        var from = 0
        while true {
            let range = ns.range(of: "```mermaid", range: NSRange(location: from, length: ns.length - from))
            guard range.location != NSNotFound else { return found }
            found.append(range.location)
            from = NSMaxRange(range)
        }
    }

    // MARK: - Which diagram it opens on

    /// Two identical diagrams are two diagrams: the second one's button opens
    /// the second, by place, and the list holds both.
    @Test func aPressOpensOnItsOwnDiagramBesideAnIdenticalOne() throws {
        let text = "Intro\n\n\(Self.fence(Self.flow))\n\nMiddle\n\n\(Self.fence(Self.flow))\n\n\(Self.fence(Self.pie))\n"
        let at = fences(in: text)
        let request = try #require(DiagramZoomRequest.make(
            text: text, zoom: DiagramZoom(source: Self.flow, location: at[1]), caret: nil))
        #expect(request.sources == [Self.flow, Self.flow, Self.pie])
        #expect(request.start == 1)
    }

    /// Preview has no offsets, so it goes by source; a place that no longer
    /// holds that source — the note changed under the press — goes by source
    /// too; and a diagram the note does not hold at all is shown on its own
    /// rather than some other one.
    @Test func withoutAPlaceItGoesBySourceAndNeverOpensTheWrongDiagram() throws {
        let text = "\(Self.fence(Self.flow))\n\n\(Self.fence(Self.pie))\n"
        let at = fences(in: text)
        let fromPreview = try #require(DiagramZoomRequest.make(
            text: text, zoom: DiagramZoom(source: Self.pie), caret: nil))
        #expect(fromPreview.start == 1)
        let moved = try #require(DiagramZoomRequest.make(
            text: text, zoom: DiagramZoom(source: Self.pie, location: at[0]), caret: nil))
        #expect(moved.start == 1, "the place held a different diagram, and the source should have won")
        let gone = try #require(DiagramZoomRequest.make(
            text: text, zoom: DiagramZoom(source: "graph LR\n  X --> Y"), caret: nil))
        #expect(gone.sources == ["graph LR\n  X --> Y"] && gone.start == 0)
    }

    /// From the bar or the menu: the diagram the caret is in, else the nearest;
    /// the first without a caret; nothing at all without a diagram.
    @Test func theCommandOpensOnTheDiagramNearestTheCaret() throws {
        let text = "\(Self.fence(Self.flow))\n\nA paragraph between the two diagrams.\n\n\(Self.fence(Self.pie))\n"
        let ns = text as NSString
        func start(caret: Int?) -> Int? {
            DiagramZoomRequest.make(text: text, zoom: nil, caret: caret)?.start
        }
        #expect(start(caret: nil) == 0)
        #expect(start(caret: ns.range(of: "\"x\"").location) == 1, "inside the second")
        #expect(start(caret: ns.range(of: "A paragraph").location) == 0, "nearer the first")
        #expect(start(caret: ns.range(of: "diagrams.").location) == 1, "nearer the second")
        #expect(DiagramZoomRequest.make(text: "No diagrams here.", zoom: nil, caret: 0) == nil)
    }

    // MARK: - Every spelling the editor draws

    /// The app lists a note's diagrams by the editor's own rule now. The
    /// expression it used knew one spelling, and the control shows it finding
    /// none of these — each a picture in the note that had no Mermaid command
    /// and could not be found by the zoom.
    @Test(arguments: [("~~~mermaid", "~~~"), ("```Mermaid", "```"), ("```mermaid theme=dark", "```")])
    func everySpellingTheEditorDrawsIsListed(open: String, close: String) throws {
        let text = "Before\n\n\(open)\n\(Self.flow)\n\(close)\n\nAfter"
        #expect(MarkdownParsing.mermaidBlocks(in: text) == [Self.flow])

        let replaced = try NSRegularExpression(pattern: "```mermaid[ \\t]*\\n(.*?)\\n```",
                                               options: [.dotMatchesLineSeparators])
        #expect(replaced.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) == 0,
                "the control: the old expression should not have found this spelling")
    }

    /// Preview draws — and gives a button to — every spelling the editor draws,
    /// by asking the editor's rule. It kept a copy of its own that wanted the
    /// info string to be the one word, so these two were pictures in Edit and
    /// code in Preview, with no button to press; the control applies that copy.
    @Test(arguments: ["```mermaid theme=dark", "```mermaid\ttheme=dark"])
    func previewDrawsEverySpellingTheEditorDraws(open: String) async {
        let markdown = await PreviewSuperset.apply(to: "\(open)\n\(Self.flow)\n```\n\nAfter\n",
                                                   isDark: false, embeds: nil)
        #expect(markdown.contains("class=\"hn-zoom\""), "Preview left this diagram as code")
        #expect(!markdown.contains(open), "the fence reached the page")

        let info = open.drop(while: { $0 == "`" })
        #expect(info.trimmingCharacters(in: .whitespaces).lowercased() != "mermaid",
                "the control: Preview's old copy of the rule should have refused this spelling")
    }

    /// A transclusion card draws every spelling the editor draws, by the same
    /// rule. It kept its own, which knew backtick fences whose info string was
    /// the one word, so these two were drawn in their own note and shown as
    /// code in every card that embedded it; the control applies that rule.
    @Test(arguments: [("~~~mermaid", "~~~"), ("```mermaid theme=dark", "```")])
    func aTransclusionCardDrawsEverySpellingTheEditorDraws(open: String, close: String) {
        let card = NoteTranscluder.attributedBody(from: "Before\n\n\(open)\n\(Self.flow)\n\(close)\n\nAfter\n",
                                                  isDark: false)
        var pictures = 0
        card.enumerateAttribute(.attachment, in: NSRange(location: 0, length: card.length)) { value, _, _ in
            if value != nil { pictures += 1 }
        }
        #expect(pictures == 1, "the card showed this diagram as code")
        #expect(!card.string.contains("A --> B"), "the diagram's source reached the card")

        let oldRule = open.hasPrefix("```")
            && open.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() == "mermaid"
        #expect(!oldRule, "the control: the card's old rule should have refused this spelling")
    }

    // MARK: - Preview's button

    /// The button carries its diagram's source through cmark-gfm in one piece.
    ///
    /// The markup is a raw HTML block, which ends at a blank line — and long
    /// diagrams are spaced with blank lines. The control writes the same markup
    /// with the line breaks left in, and cmark cuts it there: the rest becomes
    /// a paragraph, and the attribute's closing quote and the tag's bracket
    /// reach the page as text (`&quot;&gt;`), leaving the button's attribute
    /// open to swallow whatever follows.
    @Test func previewsButtonSurvivesABlankLineInItsDiagram() async throws {
        let source = "graph TD\n\n  A[\"x & y\"] --> B"
        let markdown = await PreviewSuperset.apply(to: "\(Self.fence(source))\n\nAfter\n",
                                                   isDark: false, embeds: nil)
        let value = "graph TD&#10;&#10;  A[&quot;x &amp; y&quot;] --&gt; B"
        #expect(markdown.contains("data-hn-zoom=\"\(value)\""), "the diagram did not render, or its button is missing")

        let html = GFMRenderer.html(markdown)
        #expect(html.contains("data-hn-zoom=\"\(value)\"></button></span></p>"),
                "the button did not reach the page whole")
        #expect(!html.contains("&quot;&gt;</button>"), "part of the button reached the page as text")

        let naive = "<p class=\"hn-diagram-wrap\"><span class=\"hn-diagram-box\"><button class=\"hn-zoom\" "
            + "data-hn-zoom=\"graph TD\n\n  A --&gt; B\"></button></span></p>\n"
        #expect(GFMRenderer.html(naive).contains("&quot;&gt;</button>"),
                "the control: with its line breaks left in, the tag should have been cut")
    }

    // MARK: - The drawing

    /// The zoom draws the diagram the note draws — same layout, same labels,
    /// the right way up — through a SwiftUI canvas, as the zoom shows it.
    ///
    /// The two come by different roads: the note's picture is BeautifulMermaid's
    /// bitmap, drawn bottom-up on the Mac and flipped afterwards; the zoom draws
    /// vectors straight into the canvas's top-down context, with the labels
    /// drawn by AppKit or UIKit into whatever context is current. The control
    /// is the note's picture upside down: a comparison that cannot tell those
    /// apart can tell nothing apart.
    ///
    /// One box over three, so that upside down it is three over one: a straight
    /// chain of boxes is nearly its own mirror image, and made a weak control —
    /// 13% apart, against 4% between the note and the zoom, which is the two
    /// roads' font smoothing (the note's labels are a touch heavier) and not a
    /// difference of picture. Looked at before this was written.
    @Test func theZoomDrawsTheDiagramTheNoteDraws() throws {
        let source = "flowchart TD\n  A[Write] --> B[Link]\n  A --> C[Find]\n  A --> D[Ask]"
        let picture = try #require(MermaidDiagramRenderer.standaloneImage(source: source, isDark: false))
        let drawing = try #require(MermaidDiagramRenderer.drawing(source: source, isDark: false))
        #expect(abs(picture.size.width - drawing.size.width) < 1
                && abs(picture.size.height - drawing.size.height) < 1,
                "the zoom laid the diagram out at a different size: \(drawing.size) vs \(picture.size)")

        let scale: CGFloat = 2
        let width = Int((drawing.size.width * scale).rounded())
        let height = Int((drawing.size.height * scale).rounded())
        let whole = CGRect(x: 0, y: 0, width: width, height: height)

        let note = try #require(Self.cgImage(of: picture))
        let expected = Self.pixels(width, height) { $0.draw(note, in: whole) }

        let canvas = ImageRenderer(content: Canvas { context, _ in
            context.withCGContext { drawing.draw(in: $0) }
        }.frame(width: drawing.size.width, height: drawing.size.height))
        canvas.scale = scale
        let zoomed = try #require(canvas.cgImage)
        let drawn = Self.pixels(width, height) { $0.draw(zoomed, in: whole) }

        let mirrored = Self.pixels(width, height) { context in
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(note, in: whole)
        }

        let same = Self.difference(expected, drawn)
        let upsideDown = Self.difference(expected, mirrored)
        #expect(upsideDown > 0.2, "the control: a picture and its mirror image should differ (\(upsideDown))")
        #expect(same < upsideDown / 4,
                "the zoom's diagram differs from the note's (\(same)) about as much as an upside-down one (\(upsideDown))")
    }

    /// The editor renders a diagram off the main actor now: parse, layout and
    /// rasterise — 123ms at 120 nodes — had been held on it by one AppKit
    /// flip. The picture drawn off the main actor has to be the one drawn on
    /// it, pixel for pixel; which way up it is, is
    /// `theZoomDrawsTheDiagramTheNoteDraws`' to hold.
    @Test func aDiagramRendersTheSameOffTheMainActor() async throws {
        let source = "flowchart TD\n  A[Write] --> B[Link]\n  A --> C[Find]\n  A --> D[Ask]"
        let onMain = try #require(MermaidDiagramRenderer.standaloneImage(source: source, isDark: false))
        let offMainImage = await offMain { MermaidDiagramRenderer.standaloneImage(source: source, isDark: false) }
        let a = try #require(Self.cgImage(of: onMain))
        let b = try #require(offMainImage.flatMap { Self.cgImage(of: $0) }, "nothing was drawn off the main actor")
        #expect(a.width == b.width && a.height == b.height)
        let width = a.width, height = a.height
        let drawnOn = Self.pixels(width, height) { $0.draw(a, in: CGRect(x: 0, y: 0, width: width, height: height)) }
        let drawnOff = Self.pixels(width, height) { $0.draw(b, in: CGRect(x: 0, y: 0, width: width, height: height)) }
        #expect(drawnOn.contains { $0 != 0 }, "the diagram drew nothing — this test is not comparing anything")
        #expect(drawnOn == drawnOff, "the picture drawn off the main actor is not the one drawn on it")
    }

    private static func cgImage(of image: PlatformImage) -> CGImage? {
        #if canImport(AppKit)
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        return image.cgImage
        #endif
    }

    /// RGBA bytes of whatever `draw` puts in a `width`×`height` bitmap.
    private static func pixels(_ width: Int, _ height: Int, _ draw: (CGContext) -> Void) -> [UInt8] {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        draw(context)
        guard let data = context.data else { return [] }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                         count: width * height * 4))
    }

    /// Of the pixels either picture inks, the share on which they disagree by
    /// more than a quarter of the range in any channel.
    private static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var inked = 0, differing = 0
        for pixel in stride(from: 0, to: a.count, by: 4) {
            guard a[pixel + 3] > 16 || b[pixel + 3] > 16 else { continue }
            inked += 1
            if (0..<4).contains(where: { abs(Int(a[pixel + $0]) - Int(b[pixel + $0])) > 64 }) {
                differing += 1
            }
        }
        return inked == 0 ? 1 : Double(differing) / Double(inked)
    }
}
