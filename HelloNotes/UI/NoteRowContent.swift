//
//  NoteRowContent.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  What a note row in the sidebar *says* — decided once, for both platforms.
//
//  The two sidebars cannot share a view: macOS draws `NSTableCellView`s inside
//  an `NSOutlineView` (`NoteOutlineList`), iOS draws SwiftUI rows in a `List`.
//  That much is a genuine platform difference. What is not is the *content* —
//  and with nothing shared, the two drifted all the way apart: the Mac's row is
//  a semibold title, a cloud badge when the note is online-only, and a second
//  line carrying the search snippet or the last-modified date. The iPad's was
//  `Text(note.title)`. Same tree, same data, half the information.
//
//  So the decision lives here and the drawing stays platform-specific. A row
//  that gains a field gains it on both platforms or neither.
//

import Foundation

/// A note plus the search snippet that found it, if a search found it.
///
/// Shared rather than per-shell: it is the unit both sidebars list, and it was
/// `private` to `MacContentView`, which is why the iPad's search could only
/// ever hand its tree bare `Note`s and lost every snippet on the way.
struct NoteRow: Identifiable {
    let note: Note
    let snippet: String?
    var id: Note.ID { note.id }
}

/// The three things a sidebar row shows about a note.
struct NoteRowContent {
    let title: String
    /// The search snippet when the row came from a search, otherwise the
    /// modification date. Never empty — a row with no second line at all reads
    /// as a different kind of row.
    let subtitle: String
    /// In a cloud folder, not downloaded. Worth saying, because opening it will
    /// block on a network fetch.
    let isOnlineOnly: Bool

    static func make(_ note: Note, snippet: String? = nil) -> NoteRowContent {
        NoteRowContent(title: note.title,
                       subtitle: snippet ?? Self.dateFormatter.string(from: note.lastModified),
                       isOnlineOnly: note.isOnlineOnly)
    }

    /// Shared so the same note is not dated two ways on two devices.
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// The label a cloud badge carries for VoiceOver, on either platform.
    static let onlineOnlyLabel = "Online only — not downloaded"
}
