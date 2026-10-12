//
//  LinkColourTests.swift
//  MarkdownEditorTests
//
//  A link is drawn in the colour the document gave it.
//
//  `StyleApplier` colours a link with the theme's accent, and a link to a note
//  that does not exist with its muted grey — and marks both `.link`, so the
//  text view gives them a click and a pointer. A text view also has its own
//  idea of what a `.link` looks like (`linkTextAttributes`), and draws that
//  *over* the string's: system blue and an underline on the Mac, the tint on
//  iOS. So on the Mac every wiki-link in Edit was blue and underlined beside a
//  Preview that drew the same link in the accent, and on both platforms a link
//  to a missing note looked exactly like one to a note that is there.
//
//  Found by the whole-window comparison once it lined up
//  (docs/implemented.md §51.43): chrome that matched around a note whose links
//  were two colours.
//

import Foundation
import Testing
@testable import MarkdownEditor
import MarkdownCore
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@MainActor
@Suite struct LinkColourTests {

    /// Unlike system blue, the muted grey and the text's near-black, so a
    /// measured colour says which of them drew it.
    #if canImport(AppKit)
    private static let accent = NSColor(srgbRed: 0.85, green: 0.10, blue: 0.45, alpha: 1)
    #else
    private static let accent = UIColor(red: 0.85, green: 0.10, blue: 0.45, alpha: 1)
    #endif

    /// A plain line first — the caret starts there, and the line the caret is
    /// on shows its link's brackets. Then, in pairs, something the document
    /// colours and no view has an opinion of, and the link that should be the
    /// same colour: a Markdown link's text (the accent, and not `.link`)
    /// before a link to a note that exists; a comment (the theme's grey)
    /// before a link to a note that does not.
    private static let note = """
        Intro

        [label](https://example.com)

        [[Here]]

        %%aside%%

        [[Gone]]

        """

    private func document() -> EditorDocument {
        let document = EditorDocument(text: Self.note, theme: EditorTheme(accent: Self.accent),
                                      services: EditorServices(wikiLinkExists: { $0 == "Here" }))
        document.styleEverythingNow()
        return document
    }

    /// The view adds no colour and no underline of its own to a link.
    @Test func theViewLeavesALinksLookToTheDocument() {
        #if canImport(AppKit)
        let (_, textView) = MarkdownTextView.scrollableEditor(document: document())
        let own = textView.linkTextAttributes ?? [:]
        #else
        let own = MarkdownUITextView.make(document: document()).linkTextAttributes ?? [:]
        #endif
        #expect(own[.foregroundColor] == nil, "the view colours links itself: \(String(describing: own[.foregroundColor]))")
        #expect(own[.underlineStyle] == nil, "the view underlines links itself")
    }

    #if canImport(AppKit)
    /// What is drawn, not what is set: the ink of each link, measured.
    @Test func aLinkIsDrawnInTheAccentAndAMissingOneInGrey() throws {
        let document = document()
        let (scrollView, textView) = MarkdownTextView.scrollableEditor(document: document)
        scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        scrollView.scrollerStyle = .overlay
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Pinned: the Mac turns dark at sunset, and the theme's colours with it.
        window.appearance = NSAppearance(named: .aqua)
        window.contentView?.addSubview(scrollView)
        defer { window.contentView = nil }
        let layoutManager = try #require(textView.textLayoutManager)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        window.contentView?.layoutSubtreeIfNeeded()

        let lines = try inkOfEachLine(in: textView)
        try #require(lines.count == 5, "expected five lines of ink, found \(lines.count)")
        let (intro, label, here, aside, gone) = (lines[0], lines[1], lines[2], lines[3], lines[4])

        // Measured against ink drawn the same way, not against the theme's
        // numbers: a picture of a view is in the display's colour space, and
        // the accent read back from one is not the accent that went in.
        //
        // The controls first: the three colours really are three, or two
        // lines that match below could match by all being one.
        #expect(!isSame(label, intro) && !isSame(aside, intro) && !isSame(label, aside),
                "text, the accent and the grey were not told apart: \(intro) \(label) \(aside)")
        #expect(isSame(here, label), "a link to a note that exists is drawn \(here), and the accent is \(label)")
        #expect(isSame(gone, aside),
                "a link to a note that does not exist is drawn \(gone), and the theme's grey is \(aside)")
    }

    /// The colour of the ink on each line that has any. The editor paints no
    /// background, so what is opaque is ink — and of that, the pixel furthest
    /// from white is a glyph's solid middle: an average takes in the
    /// antialiased edges, which read a fifth of the way to white.
    private func inkOfEachLine(in view: NSView) throws -> [NSColor] {
        let rect = view.visibleRect
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: rep)
        var lines: [[NSColor]] = []
        var current: [NSColor] = []
        for y in 0..<rep.pixelsHigh {
            var row: [NSColor] = []
            for x in 0..<rep.pixelsWide {
                if let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), colour.alphaComponent > 0.95 {
                    row.append(colour)
                }
            }
            if row.isEmpty {
                if !current.isEmpty { lines.append(current); current = [] }
            } else {
                current += row
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.compactMap { ink in
            ink.min { $0.redComponent + $0.greenComponent + $0.blueComponent
                    < $1.redComponent + $1.greenComponent + $1.blueComponent }
        }
    }

    private func isSame(_ a: NSColor, _ b: NSColor) -> Bool {
        abs(a.redComponent - b.redComponent) < 0.04 && abs(a.greenComponent - b.greenComponent) < 0.04
            && abs(a.blueComponent - b.blueComponent) < 0.04
    }
    #endif
}
