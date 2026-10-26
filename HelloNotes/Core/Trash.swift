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
//  And a test host has a Trash of its own (`testBin`): the hosted suite
//  deletes notes and folders the way the app does, and on the Mac each went
//  to the Trash of the Mac running it (implemented.md §51.65).
//

import Foundation

/// `nonisolated`: a delete runs away from the main actor (`Collection.deleteNote`,
/// `RemoteMirror.sendDelete(of:removing:failed:)`).
nonisolated enum Trash {

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
        // A test host trashes into a Trash of its own, never the Mac's.
        if let bin = testBin {
            let place = bin.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: place.appending(path: url.lastPathComponent))
            return .trashed
        }
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

    /// The test host's own Trash: where a hosted test's deletes go on the Mac,
    /// in place of the Trash of the Mac the suite runs on.
    ///
    /// The suite deletes notes and folders as the app does — `deleteNote`,
    /// `deleteFolder`, the cloud mirror's delete — and every one went to the
    /// person's Trash, named as the test named it, dozens a day
    /// (implemented.md §51.65). Here an item is moved as the Trash moves it,
    /// into a folder of the run's own in the host's temporary folder, and the
    /// outcome is `.trashed`: nothing that is tested changes, as nothing does
    /// for the rest of what `TestEnvironment` keeps from a test host. A run's
    /// folder outlives the run, for a test to look in; the next run to trash
    /// something clears the folders of runs a day old, so a run going on at
    /// the same time keeps its own.
    ///
    /// `nil` outside a test host — and on iOS, where an app's container has
    /// no Trash, and nothing a test deletes in the simulator reaches the Mac's.
    static let testBin: URL? = {
        #if os(macOS)
        guard TestEnvironment.isRunningTests else { return nil }
        let runs = FileManager.default.temporaryDirectory
            .appending(path: "HelloNotes Test Trash", directoryHint: .isDirectory)
        clearRuns(in: runs, changedBefore: Date().addingTimeInterval(-86_400))
        let bin = runs.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        return bin
        #else
        return nil
        #endif
    }()

    /// Clear the folders of earlier runs last changed before `date`.
    private static func clearRuns(in runs: URL, changedBefore date: Date) {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: runs, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for folder in folders {
            let changed = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if (changed ?? .distantPast) < date { try? fm.removeItem(at: folder) }
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
