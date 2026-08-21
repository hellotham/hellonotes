//
//  Trash.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  Deleting a note has to actually delete it — on both platforms.
//
//  `FileManager.trashItem` is the right call on macOS: it puts the file in the
//  Finder's Trash, where the user can get it back, which is what "Move to
//  Trash" promises. On iOS it is documented as available and **fails for most
//  locations an app can write to** — there is no user-visible Trash for an app
//  container, and a Files-provider folder may or may not offer one depending on
//  the provider.
//
//  What that cost: `Collection.deleteNote` caught the throw, reported it, and
//  then called `forget(note)` regardless. So on iPad the note disappeared from
//  the sidebar, stayed on disk, and came back at the next scan. Delete looked
//  like it worked, and undid itself later.
//
//  So: try the Trash, and where there is no Trash to move it to, remove it.
//  The distinction is reported back to the caller rather than swallowed,
//  because "moved to Trash" and "deleted permanently" are different promises
//  and the UI should be able to tell the user which one happened.
//

import Foundation

enum Trash {

    /// What became of the item.
    enum Outcome: Equatable {
        /// Moved somewhere the user can retrieve it from.
        case trashed
        /// Removed outright — no Trash was available for this location.
        case deleted
    }

    /// Move `url` to the Trash, or delete it where the platform has no Trash
    /// for that location.
    ///
    /// - Throws: only when the item is still on disk afterwards. A caller may
    ///   therefore treat a non-throwing return as "it is gone", which is what
    ///   makes it safe to drop the item from the model.
    @discardableResult
    static func item(at url: URL) throws -> Outcome {
        // Already gone is the outcome the caller wanted. Treating it as a
        // failure would strand a row in the sidebar for a file that no longer
        // exists — the exact phantom the caller drops the note to avoid.
        guard FileManager.default.fileExists(atPath: url.path) else { return .deleted }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return .trashed
        } catch {
            #if os(macOS)
            // The Mac has a Trash for every location the app can reach, so a
            // failure here is a real failure (permissions, a vanished file) and
            // must not be escalated into an unrecoverable delete.
            throw error
            #else
            // iOS: no Trash for this location. Removing it is what the user
            // asked for; leaving it is the bug.
            try FileManager.default.removeItem(at: url)
            return .deleted
            #endif
        }
    }
}
