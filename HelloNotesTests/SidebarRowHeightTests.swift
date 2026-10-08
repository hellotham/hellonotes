//
//  SidebarRowHeightTests.swift
//  HelloNotesTests
//
//  The sidebar's rows are as short as their contents allow, and no shorter.
//
//  Density is worth having — a note row was 42pt for 30pt of text, so a quarter
//  of the Mac's sidebar was slack — but the failure mode of tightening is
//  clipped descenders, and it is invisible from here: the outline is an
//  `NSOutlineView` in the running app, and this suite has no window.
//
//  So the heights are asserted against the same measurement they were chosen
//  from — `NSLayoutManager.defaultLineHeight` at the cells' own fonts. If
//  someone changes a cell's font, or shaves another two points off a row, the
//  arithmetic fails here rather than on someone's screen.
//

import Testing
import Foundation
#if canImport(AppKit)
import AppKit
#endif
@testable import HelloNotes

@Suite @MainActor
struct SidebarRowHeightTests {

    #if canImport(AppKit)
    private func lineHeight(_ font: NSFont) -> CGFloat {
        NSLayoutManager().defaultLineHeight(for: font)
    }

    /// A note row is a 13pt semibold title over an 11pt subtitle, 1pt apart.
    @Test func theNoteRowFitsItsTwoLines() {
        let content = lineHeight(.systemFont(ofSize: 13, weight: .semibold))
            + 1 + lineHeight(.systemFont(ofSize: 11))
        #expect(content == 30, "the fonts changed — the row height was chosen from this number")
        #expect(SidebarRowHeights.note >= content,
                "a note row is shorter than the text in it; descenders will clip")
        #expect(SidebarRowHeights.note <= content + 6,
                "a note row has more than 6pt of slack — that is a row per six rows")
    }

    /// A folder, place or attachment row is a single 12pt label beside a 12pt
    /// symbol. Symbols draw taller than their point size, which is why the
    /// margin here is larger than the note row's.
    @Test func theSingleLineRowsFitTheirLabelAndGlyph() {
        let content = lineHeight(.systemFont(ofSize: 12))
        #expect(content == 15)
        #expect(SidebarRowHeights.leaf >= content + 4,
                "a 12pt SF Symbol draws taller than a 12pt line; leave it room")
        #expect(SidebarRowHeights.collection >= SidebarRowHeights.leaf,
                "a collection row carries a spinner and a close button as well")
    }
    #endif
}
