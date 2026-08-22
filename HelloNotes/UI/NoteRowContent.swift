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

/// What a *collection* row in the sidebar says.
///
/// The same job `NoteRowContent` does one level up, and for the same reason.
/// The AppKit cell showed five things beyond the name — an orange warning icon
/// and dimmed title when the folder is unreadable, a tooltip explaining why, a
/// spinner while a scan is running, a Git dot coloured by whether the working
/// tree is clean, and semibold for the focused collection. The SwiftUI row
/// showed `Text(collection.name).font(.headline)`.
///
/// That gap is worse than the note row's was. **An unreadable collection has to
/// look unreadable**: it keeps its notes listed, because they are the last true
/// picture of the folder, so without the warning the row is indistinguishable
/// from a healthy one and stale contents read as current.
struct CollectionRowContent {
    let name: String
    /// Why the folder cannot be read, if it cannot.
    let unavailable: CollectionState.UnavailableReason?
    /// A scan is running — visible on the row itself, not only in the status
    /// bar, because the sidebar is where you notice a collection is still
    /// filling in.
    let isScanning: Bool
    /// The collection the rest of the window is acting on.
    let isFocused: Bool
    /// `nil` when the folder is not a repository; otherwise whether the working
    /// tree is clean.
    let gitIsClean: Bool?

    var symbol: String { unavailable == nil ? "books.vertical" : "exclamationmark.triangle" }
    var isDimmed: Bool { unavailable != nil }

    /// The hover explanation, on either platform.
    var help: String? {
        if let unavailable {
            return "\(unavailable.explanation) Its notes are shown as they were."
        }
        return nil
    }

    /// The label the Git dot carries for VoiceOver.
    var gitLabel: String? {
        gitIsClean.map { $0 ? "No uncommitted changes" : "Uncommitted changes" }
    }

    var scanningLabel: String { "Scanning “\(name)”" }

    @MainActor
    static func make(_ collection: Collection, focusedID: Collection.ID?) -> CollectionRowContent {
        let reason: CollectionState.UnavailableReason? = {
            if case .unavailable(let reason) = collection.state { return reason }
            return nil
        }()
        return CollectionRowContent(
            name: collection.name,
            unavailable: reason,
            isScanning: collection.showsScanProgress,
            isFocused: collection.id == focusedID,
            gitIsClean: collection.git.status.isRepository ? collection.git.status.isClean : nil)
    }
}
