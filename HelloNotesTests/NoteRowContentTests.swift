//
//  NoteRowContentTests.swift
//  HelloNotesTests
//
//  A sidebar row is mostly empty space, and the date is why.
//
//  "2 Sep 2026 at 7:28 am" is 21 characters — wider than the title it would sit
//  beside — so the date needed a line of its own, and every row in the list cost
//  two. On an iPad in portrait, where the note list is handed most of the
//  window, that spent half the available height on whitespace.
//
//  Two changes, guarded here: the date says only as much as distinguishes one
//  row from another, and the layout follows the *width it is given* rather than
//  the device it is on.
//

import Testing
import Foundation
import SwiftUI
@testable import HelloNotes

@Suite @MainActor
struct NoteRowContentTests {

    /// Only the nearest unit that differs, so every case fits a column.
    @Test func theDateSaysAsMuchAsDistinguishesTheRow() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try #require(DateComponents(
            calendar: calendar, year: 2026, month: 9, day: 3, hour: 9, minute: 0).date)

        func date(_ month: Int, _ day: Int, _ year: Int = 2026, hour: Int = 7, minute: Int = 28) throws -> Date {
            try #require(DateComponents(calendar: calendar, year: year, month: month,
                                        day: day, hour: hour, minute: minute).date)
        }
        func rendered(_ d: Date) -> String {
            NoteRowContent.compactDate(d, now: now, calendar: calendar)
        }

        // Today → the time is the only thing that separates two of today's notes.
        let today = rendered(try date(9, 3))
        #expect(today.contains("28"), "today should render a time, got \(today)")
        #expect(!today.contains("2026"), "today does not need the year: \(today)")

        #expect(rendered(try date(9, 2)) == "Yesterday")

        // Earlier this week → the weekday.
        let thisWeek = rendered(try date(8, 30))
        #expect(thisWeek.count <= 4, "a weekday should be abbreviated, got \(thisWeek)")
        #expect(!thisWeek.contains("2026"))

        // Earlier this year → day and month, no year.
        let thisYear = rendered(try date(3, 14))
        #expect(!thisYear.contains("2026"), "this year is implied: \(thisYear)")
        #expect(thisYear.contains("14"))

        // Older → a numeric date, which is the only case that carries a year.
        let older = rendered(try date(3, 14, 2019))
        #expect(older.contains("19"), "an older note must say which year: \(older)")
    }

    /// Every rendering is short enough to be a column rather than a line.
    ///
    /// The point of the change, stated as a measurement: the old format was 21
    /// characters, and a 280pt sidebar has room for roughly 30 at caption size —
    /// so title *and* date could never have shared a line.
    @Test func everyDateIsColumnWidth() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try #require(DateComponents(
            calendar: calendar, year: 2026, month: 9, day: 3, hour: 9, minute: 0).date)
        for daysAgo in 0...900 {
            let d = try #require(calendar.date(byAdding: .day, value: -daysAgo, to: now))
            let text = NoteRowContent.compactDate(d, now: now, calendar: calendar)
            #expect(text.count <= 12,
                    "\(daysAgo) days ago rendered as \"\(text)\" — too wide for a column")
            #expect(!text.isEmpty)
        }
    }

    /// A snippet is prose and keeps its own line; a date never gets one in the
    /// wide layout. Kept as a field test because the row's two layouts differ
    /// only in which of these they read.
    @Test func aSearchRowKeepsItsSnippetAndAPlainRowHasNone() {
        let note = Note(title: "Meeting", fileURL: URL(filePath: "/tmp/Meeting.md"),
                        lastModified: Date(), fileSize: 10)
        #expect(NoteRowContent.make(note).snippet == nil,
                "a row outside a search has no second line to draw")
        #expect(NoteRowContent.make(note, snippet: "…the budget…").snippet == "…the budget…")
        #expect(!NoteRowContent.make(note).date.isEmpty,
                "the date is always available — the layout decides where it goes")
    }

    /// The Mac can never reach the two-column width, and that is load-bearing.
    ///
    /// `noteCell` in `NoteOutlineList` is stacked unconditionally and says so in
    /// a comment. If the sidebar's cap ever rises past the threshold, that
    /// comment becomes false and the Mac silently keeps the layout it should
    /// have left — so the coupling is asserted rather than described.
    @Test func sidebarStaysBelowTheTwoColumnThreshold() {
        #expect(ShellMetrics.sidebarCap < ShellMetrics.noteRowTwoColumn,
                "a Mac sidebar can now be wide enough for two columns, but NoteOutlineList.noteCell still stacks unconditionally")
        #expect(ShellMetrics.noteRowTouchMinimum >= 44,
                "a note row must stay a 44pt touch target however dense it gets")
    }
}
