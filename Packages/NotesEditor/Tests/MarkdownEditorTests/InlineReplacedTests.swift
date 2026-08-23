//
//  InlineReplacedTests.swift
//  MarkdownEditorTests
//
//  A picture *inside* a line of prose — `My ![foo](train.jpg)`, `a <img …> b`.
//
//  The editor has always drawn a paragraph that is nothing but an image, and
//  never one with a word beside it: the source stayed on screen where the
//  Preview showed a photograph. In the height sweep that reads as a tidy two
//  points, because the source happens to occupy one line and one line of prose
//  is 24pt where a line seating a 20pt picture is 26 — which is the actual
//  subject here. CSS aligns a replaced element on the baseline, so the line box
//  has to reach the whole of the picture's height above it while the strut
//  still hangs its descender and half-leading below.
//
//  These lay the note out for real. A paragraph style would say nothing: the
//  whole mechanism is one run's ascent against a pin that has to come off, and
//  what it is worth is what survives layout.
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

@Suite @MainActor struct InlineReplacedTests {

    /// A renderer that answers every image with one swatch, and nothing else.
    private struct SwatchRenderer: BlockRenderer {
        let image: PlatformImage
        func render(_ kind: BlockEmbedKind, maxWidth: CGFloat, darkMode: Bool) async -> PlatformImage? {
            if case .image = kind { return image }
            return nil
        }
    }

    /// A real image of the given size — `UIImage(size:)` does not exist, and a
    /// zero-sized one would reserve neither width nor height.
    private static func swatch(_ width: CGFloat, _ height: CGFloat) -> PlatformImage {
        let size = CGSize(width: width, height: height)
        #if canImport(AppKit)
        return NSImage(size: size)
        #else
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        #endif
    }

    /// Style `text`, wait for the picture to land on `needle`, and lay the
    /// result out offscreen. Returns nil if the image never arrived.
    private func laidOut(_ text: String, image: PlatformImage, needle: String,
                         caretAt: String? = nil, width: CGFloat = 600,
                         base: CGFloat = 16) async throws -> (document: EditorDocument, layout: Layout)? {
        let ns = text as NSString
        let document = EditorDocument(text: text, theme: EditorTheme(fontSize: base),
                                      services: EditorServices(blockRenderer: SwatchRenderer(image: image)))
        // The caret reveals the block it is in, and a revealed block shows its
        // source — so it is parked well away from the picture unless a test
        // is about the reveal.
        let caret = caretAt.map { ns.range(of: $0).location } ?? ns.length
        document.selectionDidChange(NSRange(location: caret, length: 0))
        document.styleEverythingNow()
        let offset = ns.range(of: needle).location
        guard offset != NSNotFound else { return nil }
        var arrived = false
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(20))
            if document.storage.attribute(inlineImageAttribute, at: offset, effectiveRange: nil) != nil {
                arrived = true
                break
            }
        }
        guard arrived else { return nil }
        return (document, Layout(document.storage, width: width))
    }

    /// One styled storage, laid out offscreen with the editor's own fragment
    /// subclass vended.
    @MainActor final class Layout {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        private let fragments = RenderedBlockLayoutDelegate()

        init(_ storage: NSTextStorage, width: CGFloat) {
            layoutManager.delegate = fragments
            let container = NSTextContainer(size: CGSize(width: width,
                                                         height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layoutManager.textContainer = container
            contentStorage.addTextLayoutManager(layoutManager)
            contentStorage.textStorage?.setAttributedString(storage)
            layoutManager.ensureLayout(for: layoutManager.documentRange)
        }

        func fragment(at offset: Int) -> NSTextLayoutFragment? {
            guard let start = contentStorage.location(contentStorage.documentRange.location,
                                                      offsetBy: offset) else { return nil }
            return layoutManager.textLayoutFragment(for: start)
        }

        /// The height of the *visual* line the character at `offset` sits on —
        /// not the fragment's, which would also count the block's trailing
        /// margin and the wrapped lines beside it.
        func lineHeight(at offset: Int) -> CGFloat {
            guard let fragment = fragment(at: offset),
                  let start = contentStorage.offset(from: contentStorage.documentRange.location,
                                                    to: fragment.rangeInElement.location) as Int?
            else { return -1 }
            let local = offset - start
            for line in fragment.textLineFragments {
                let r = line.characterRange
                if local >= r.location, local < r.location + r.length {
                    return line.typographicBounds.height
                }
            }
            return -1
        }
    }

    #if canImport(AppKit)
    /// AppKit rounds a line's ascent and descent to whole points before summing
    /// them. That rounding is where `BlockBoxes.halfLeading`'s own
    /// `round(ascender) + round(-descender)` comes from — it is what *both*
    /// engines measured — and it is why Edit and Preview can be identical here
    /// rather than merely close.
    private let slack: CGFloat = 0.01
    #else
    /// UIKit sums the exact font metrics instead, so the same picture line
    /// comes out `round(-descender) + descender` short of the box model —
    /// 0.13pt at body size. There is no WebKit on this side to be identical
    /// *to*: the tolerance here is that rounding, and nothing else is allowed
    /// to hide behind it.
    private let slack: CGFloat = 0.2
    #endif

    private func same(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < slack }

    // MARK: - The box

    /// The whole subject: a 20pt picture in a sentence makes that line 26pt,
    /// not 24 and not 20. Held against `BlockBoxes.lineHeight(seating:)` rather
    /// than against 26, so the rule is what is asserted and not one arithmetic
    /// result of it.
    @Test func aPictureInASentenceGrowsItsOwnLine() async throws {
        let theme = EditorTheme(fontSize: 16)
        let text = "Above.\n\nMy ![foo](train.jpg) tail\n\nBelow.\n"
        guard let (document, layout) = try await laidOut(text, image: Self.swatch(20, 20),
                                                         needle: "![foo]") else {
            Issue.record("the picture never arrived")
            return
        }
        let ns = text as NSString
        let onTheLine = ns.range(of: "![foo]").location
        #expect(same(layout.lineHeight(at: onTheLine),
                     BlockBoxes.lineHeight(seating: 20, box: .paragraph, theme: theme)))
        // The neighbours are untouched — this is a property of one line box.
        #expect(same(layout.lineHeight(at: ns.range(of: "Above.").location), theme.metrics.bodyLineHeight))
        #expect(same(layout.lineHeight(at: ns.range(of: "Below.").location), theme.metrics.bodyLineHeight))
        // Storage stays byte-pure Markdown, as every concealment here does.
        #expect(document.text == text)
    }

    /// CSS's rule is a `max`, and the `max` is the half people forget: an icon
    /// shorter than the strut's own ascent leaves the line exactly as it was.
    @Test func aPictureShorterThanTheStrutMovesNothing() async throws {
        let theme = EditorTheme(fontSize: 16)
        let text = "My ![foo](icon.png) tail\n"
        guard let (_, layout) = try await laidOut(text, image: Self.swatch(12, 10),
                                                  needle: "![foo]") else {
            Issue.record("the picture never arrived")
            return
        }
        let onTheLine = (text as NSString).range(of: "![foo]").location
        #expect(same(layout.lineHeight(at: onTheLine), theme.metrics.bodyLineHeight))
        #expect(same(BlockBoxes.lineHeight(seating: 10, box: .paragraph, theme: theme),
                     theme.metrics.bodyLineHeight))
    }

    /// The control that rules out the cheap repair. `![foo]` / `[]` is **one**
    /// paragraph of two source lines with one picture in it, and CSS grows only
    /// the line carrying the picture — so anything applied per *paragraph*
    /// (a line height, a minimum) overshoots by exactly one growth.
    @Test func onlyTheLineCarryingThePictureGrows() async throws {
        let theme = EditorTheme(fontSize: 16)
        let text = "![foo] \n[]\n\n[foo]: /url \"title\"\n"
        guard let (_, layout) = try await laidOut(text, image: Self.swatch(20, 20),
                                                  needle: "![foo]") else {
            Issue.record("the picture never arrived")
            return
        }
        let ns = text as NSString
        #expect(same(layout.lineHeight(at: ns.range(of: "![foo]").location),
                     BlockBoxes.lineHeight(seating: 20, box: .paragraph, theme: theme)))
        #expect(same(layout.lineHeight(at: ns.range(of: "[]").location),
                     theme.metrics.bodyLineHeight))
    }

    /// …and the same, one paragraph wide instead of two lines deep: a
    /// paragraph long enough to wrap grows once, on the visual line holding the
    /// picture, however many lines it wraps to. This is what a
    /// `minimumLineHeight` cannot do — `StyleApplier` styles without knowing
    /// the pane's width, so a pinned line applies to every wrapped line.
    @Test func aWrappedParagraphGrowsOnceNotOncePerLine() async throws {
        let theme = EditorTheme(fontSize: 16)
        let filler = String(repeating: "word ", count: 40)
        let text = "\(filler)![foo](train.jpg) \(filler)\n"
        guard let (_, layout) = try await laidOut(text, image: Self.swatch(20, 20),
                                                  needle: "![foo]", width: 240) else {
            Issue.record("the picture never arrived")
            return
        }
        guard let fragment = layout.fragment(at: 0) else {
            Issue.record("no fragment")
            return
        }
        let lines = fragment.textLineFragments
        #expect(lines.count > 3)   // it really did wrap
        let grown = lines.filter { $0.typographicBounds.height > theme.metrics.bodyLineHeight }
        #expect(grown.count == 1)
        #expect(same(grown.first?.typographicBounds.height ?? -1,
                     BlockBoxes.lineHeight(seating: 20, box: .paragraph, theme: theme)))
    }

    // MARK: - What replaces what

    /// The source collapses to nothing and the picture's own width is put back
    /// — so the words after it land where the Preview puts them.
    @Test func theSourceIsConcealedAndItsWidthIsThePicture() async throws {
        let text = "My ![foo](train.jpg) tail\n"
        guard let (document, _) = try await laidOut(text, image: Self.swatch(37, 20),
                                                    needle: "![foo]") else {
            Issue.record("the picture never arrived")
            return
        }
        let ns = text as NSString
        let start = ns.range(of: "![foo]").location
        let end = ns.range(of: "(train.jpg)").location + 10   // the closing `)`
        #expect((document.storage.attribute(.font, at: start + 1, effectiveRange: nil) as? PlatformFont)?
            .pointSize == EditorTheme.concealedSize)
        #expect(document.storage.attribute(.kern, at: end, effectiveRange: nil) as? CGFloat == 37)
        // Not a block embed: the block keeps its text, and only the span goes.
        #expect(document.storage.attribute(blockImageAttribute, at: start, effectiveRange: nil) == nil)
    }

    /// A raw `<img>` is a replaced element on exactly the same terms — it is
    /// the one inline HTML tag that draws a picture and no text.
    @Test func aRawIMGTagIsAReplacedElementToo() async throws {
        let theme = EditorTheme(fontSize: 16)
        let text = "start <img src=\"train.jpg\"> end\n"
        guard let (document, layout) = try await laidOut(text, image: Self.swatch(20, 20),
                                                         needle: "<img") else {
            Issue.record("the picture never arrived")
            return
        }
        let at = (text as NSString).range(of: "<img").location
        #expect(same(layout.lineHeight(at: at),
                     BlockBoxes.lineHeight(seating: 20, box: .paragraph, theme: theme)))
        #expect(document.text == text)
    }

    /// `![[embed]]` inside a sentence stays as source, on purpose. The host
    /// answers an `.image` whose target is not an image *file* with a
    /// note-transclusion card — the right answer for a block on a line of its
    /// own and an absurd one for a word inside a sentence — and nothing in the
    /// editor can tell the two apart.
    @Test func aWikiEmbedInsideALineStaysSource() async throws {
        let text = "see ![[pic.png]] here\n"
        let document = EditorDocument(text: text,
                                      services: EditorServices(blockRenderer: SwatchRenderer(image: Self.swatch(20, 20))))
        document.selectionDidChange(NSRange(location: (text as NSString).length, length: 0))
        document.styleEverythingNow()
        try await Task.sleep(for: .milliseconds(200))
        let at = (text as NSString).range(of: "![[").location
        #expect(document.storage.attribute(inlineImageAttribute, at: at, effectiveRange: nil) == nil)
        #expect(document.storage.attribute(blockImageAttribute, at: at, effectiveRange: nil) == nil)
    }

    /// Two pictures in one paragraph land one at a time, and the second one's
    /// pass restyles the first as well. Nothing it reads may be its own
    /// previous work: the half-leading it carries for the drawing is read from
    /// a character the raise never touches, and re-reading the raise instead
    /// seated the picture a whole image-height above the line.
    @Test func twoPicturesInOneParagraphBothSitOnTheBaseline() async throws {
        let theme = EditorTheme(fontSize: 16)
        let text = "one ![a](train.jpg) two ![b](moon.jpg) three\n\nElsewhere.\n"
        guard let (document, layout) = try await laidOut(text, image: Self.swatch(20, 20),
                                                         needle: "![b]") else {
            Issue.record("the picture never arrived")
            return
        }
        let ns = text as NSString
        let first = ns.range(of: "![a]").location
        let second = ns.range(of: "![b]").location
        let lift = -BlockBoxes.halfLeading(.paragraph, theme: theme)
        for at in [first, second] {
            #expect(document.storage.attribute(inlineImageAttribute, at: at, effectiveRange: nil) != nil)
            #expect(document.storage.attribute(inlineImageBaselineAttribute, at: at,
                                               effectiveRange: nil) as? CGFloat == -lift)
        }
        // One line, grown once — they share a baseline, so they share a box.
        #expect(same(layout.lineHeight(at: first),
                     BlockBoxes.lineHeight(seating: 20, box: .paragraph, theme: theme)))
        #expect(same(layout.lineHeight(at: second), layout.lineHeight(at: first)))
    }

    /// The caret is how you edit what you cannot see. With it inside the block
    /// the source is back and the line is a line of prose again.
    @Test func theCaretBringsTheSourceBack() async throws {
        let theme = EditorTheme(fontSize: 16)
        let text = "My ![foo](train.jpg) tail\n\nElsewhere.\n"
        guard let (document, _) = try await laidOut(text, image: Self.swatch(20, 20),
                                                    needle: "![foo]") else {
            Issue.record("the picture never arrived")
            return
        }
        let ns = text as NSString
        let at = ns.range(of: "![foo]").location
        document.selectionDidChange(NSRange(location: at + 2, length: 0))
        #expect(document.storage.attribute(inlineImageAttribute, at: at, effectiveRange: nil) == nil)
        let reopened = Layout(document.storage, width: 600)
        #expect(same(reopened.lineHeight(at: at), theme.metrics.bodyLineHeight))
    }
}
