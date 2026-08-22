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
            // iOS: fall back to removing it **only** when the failure actually
            // says "this location has no Trash". The catch used to take any
            // error at all, so a File Provider that was merely unreachable, or
            // a placeholder still materialising, turned a retryable hiccup into
            // an irreversible delete of the note — under a confirmation sheet
            // that had just promised the user they could recover it.
            guard isMissingTrash(error) else { throw error }
            try FileManager.default.removeItem(at: url)
            return .deleted
            #endif
        }
    }

    /// Whether `error` means "there is no Trash for this location" rather than
    /// "the move failed".
    ///
    /// Only the first justifies deleting outright. Anything else — no
    /// permission, the volume is read-only, the provider did not answer — is a
    /// failure the caller must see, because the note is still on disk and the
    /// user was told it would be recoverable. The question is the same on both
    /// platforms; what differs is that the Mac never answers yes, which is why
    /// only the `#else` branch above consults it.
    static func isMissingTrash(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSCocoaErrorDomain else { return false }
        switch ns.code {
        case NSFeatureUnsupportedError,
             NSFileWriteUnsupportedSchemeError,
             NSFileWriteInvalidFileNameError:
            return true
        default:
            return false
        }
    }
}
