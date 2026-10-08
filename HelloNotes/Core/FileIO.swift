//
//  FileIO.swift
//  HelloNotes
//
//  Created by Chris Tham on 20/7/2026.
//
//  Coordinated file access for vault note content.
//
//  HelloNotes treats the file system as the source of truth, and that file
//  system is increasingly a *cloud* one: on macOS the modern cloud clients
//  (Box, Dropbox, OneDrive personal/business, Google Drive) and iCloud Drive
//  all surface their storage through Apple's File Provider under
//  `~/Library/CloudStorage/…`; on iOS the same providers appear in Files. In
//  those folders a file can be *dataless* (online-only): its metadata is local
//  but its bytes live in the cloud and are only "materialized" on demand.
//
//  A plain `String(contentsOf:)` / `Data(contentsOf:)` read of a dataless file
//  does NOT reliably trigger materialization — on File Provider volumes it can
//  fail outright (EDEADLK / "Resource deadlock avoided"). The supported path is
//  `NSFileCoordinator`: a *coordinated* read tells the system "I need these
//  bytes now", so the File Provider extension downloads the file before the
//  accessor block runs. For ordinary local files coordination is effectively a
//  no-op, so routing every vault read/write through here is safe everywhere and
//  is the foundation for opening cloud folders natively.
//
//  Scope: this covers *vault* files (notes and their attachments). App-private
//  files that never live in a user's cloud folder — the index cache, chat
//  transcripts, the widget snapshot — deliberately keep their direct writes.
//

import Foundation
import Synchronization

/// `nonisolated` deliberately. The target builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would otherwise put every
/// one of these on the main actor — and the whole point of them is to be called
/// from the off-main work that scanning, indexing and link-rewriting do. They
/// hold no state; `NSFileCoordinator` and `FileManager` are safe to use from
/// any thread. Hopping back to the main actor to read a file would undo the
/// off-main scan work (implemented.md) and put vault I/O in front of the caret.
nonisolated enum FileIO {

    // MARK: - Reads

    /// Coordinated `Data` read. Materializes an online-only (dataless) file on
    /// demand before returning its bytes.
    static func readData(at url: URL) throws -> Data {
        var coordinatorError: NSError?
        var result: Result<Data, Error>?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        // `options: []` = a normal read intent, which materializes the file.
        // (`.immediatelyAvailableMetadataOnly` would *avoid* materialization —
        // the opposite of what a content read wants.)
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { actualURL in
            result = Result { try Data(contentsOf: actualURL) }
        }
        if let coordinatorError { throw coordinatorError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    /// Coordinated UTF-8 read. Throws (rather than substituting replacement
    /// characters) on invalid UTF-8, matching the old `String(contentsOf:
    /// encoding: .utf8)` behaviour so `try?` call sites still skip binary files.
    static func readString(at url: URL) throws -> String {
        let data = try readData(at: url)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return string
    }

    // MARK: - Materialization state

    /// Whether the file's *content* is available locally right now — so reading
    /// it won't trigger a cloud download.
    ///
    /// Returns `true` for ordinary local files and for cloud (File Provider)
    /// files whose bytes are already downloaded. Returns `false` only when the
    /// item is explicitly online-only (`.notDownloaded`). When the status can't
    /// be determined (not a ubiquitous item, or a provider that doesn't report
    /// it) we return `true` — being conservative here means we never *hide* a
    /// file we could have read; the cost is that such providers fall back to the
    /// pre-Phase-1 read-everything behaviour.
    ///
    /// The eager indexers use this to skip online-only notes rather than pull an
    /// entire cloud vault local on first open. Reading resource values is cheap
    /// metadata access and does not itself materialize the file.
    static func isMaterialized(at url: URL) -> Bool {
        if let probe = materialisedProbes.withLock({ $0[url.path] }) { probe(Thread.isMainThread) }
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]),
            values.isUbiquitousItem == true,
            let status = values.ubiquitousItemDownloadingStatus
        else { return true }   // not a cloud item, or status unknown → treat as available
        return status != .notDownloaded
    }

    /// Told, for a file's path, whether a look at its download state ran on
    /// the main thread — a test's way to see where it is asked, which no
    /// timing can show for a local file and a File Provider's can block on.
    /// Keyed by path, so tests running at once hear only their own files;
    /// empty outside tests.
    nonisolated static let materialisedProbes = Mutex<[String: @Sendable (_ onMainThread: Bool) -> Void]>([:])

    /// Whether a note's *content* is available to read right now.
    ///
    /// `isMaterialized` answers only for iCloud items and returns `true` for
    /// everything else — including a direct-API mirror's zero-byte placeholder,
    /// which is a file that exists and has no content. `Note.isOnlineOnly`
    /// carries that second case (the scan sets it from the mirror's manifest),
    /// so the two together are the real question every indexer means to ask.
    ///
    /// Getting this wrong is not a missing feature but a data-loss path: an
    /// indexer that reads a placeholder records an empty note, and an editor
    /// that opens one will upload the emptiness back over the original.
    static func hasContentAvailable(_ note: Note) -> Bool {
        !note.isOnlineOnly && isMaterialized(at: note.fileURL)
    }

    // MARK: - Writes

    /// Coordinated atomic *replace*. On a cloud folder this hands the new bytes
    /// to the File Provider to upload. The temp-file-plus-rename keeps a crash
    /// mid-write from ever leaving a truncated note on disk.
    static func write(_ data: Data, to url: URL) throws {
        var coordinatorError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { actualURL in
            do { try data.write(to: actualURL, options: .atomic) }
            catch { writeError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }
    }

    static func write(_ string: String, to url: URL) throws {
        try write(Data(string.utf8), to: url)
    }

    /// Coordinated *compare-and-replace*: write `string` only if the file still
    /// reads as `expected`. Returns `false`, having written nothing, when it
    /// does not.
    ///
    /// For a write computed from an earlier read that someone then approved —
    /// an Assistant edit. Between that read and the approval the editor may
    /// save the person's own typing (clicking Approve in another window is
    /// enough to end editing there), and a plain `write` would put the approved
    /// text over it without a word. The comparison happens inside the same
    /// coordinated write, so no other coordinated writer — the editor's
    /// `write`, a sync provider — can land between the check and the replace.
    /// The file is decoded exactly as `readString` decodes it, so a note read
    /// with that compares equal to itself.
    static func replace(_ string: String, at url: URL, ifContentsEqual expected: String) throws -> Bool {
        var coordinatorError: NSError?
        var outcome: Result<Bool, Error> = .success(false)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { actualURL in
            outcome = Result {
                // Inside the write claim, so this read is already coordinated.
                let current = try Data(contentsOf: actualURL)
                guard String(data: current, encoding: .utf8) == expected else { return false }
                try Data(string.utf8).write(to: actualURL, options: .atomic)
                return true
            }
        }
        if let coordinatorError { throw coordinatorError }
        return try outcome.get()
    }

    /// Coordinated *replace, unless the file has changed*: write `data` only if
    /// the file's bytes are still `expected` — the ones last loaded or written —
    /// or there is no file at all. Returns `false`, having written nothing,
    /// when they are not.
    ///
    /// **The editor's save.** It replaced the file blindly, so a change made
    /// elsewhere after the last look at the file — by another device, a sync
    /// client, another app — was written over the moment a save came, and a
    /// save already past its checks when the change was noticed wrote mine
    /// over theirs with the banner up. Compared inside the write claim, no
    /// other coordinated writer can land between the check and the replace.
    /// Bytes, not `String ==`: a change of normalisation is a change to a file.
    static func replace(_ data: Data, at url: URL, ifBytesAre expected: Data) throws -> Bool {
        var coordinatorError: NSError?
        var outcome: Result<Bool, Error> = .success(false)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { actualURL in
            outcome = Result {
                // Inside the write claim, so this read is already coordinated.
                if let current = try? Data(contentsOf: actualURL) {
                    guard current == expected else { return false }
                } else if FileManager.default.fileExists(atPath: actualURL.path) {
                    // There, and unreadable: not a file to replace blind.
                    return false
                }
                try data.write(to: actualURL, options: .atomic)
                return true
            }
        }
        if let coordinatorError { throw coordinatorError }
        return try outcome.get()
    }

    /// A new file beside `url` holding `data`, named as a conflicted copy is
    /// named throughout the app — "Title (conflicted copy 2026-09-25).md", then
    /// "… 2026-09-25 2).md" and on — and **never over a file already there**:
    /// each name is tried with `create`, which refuses one. The editor keeps
    /// mine this way when a buffer holding a conflict is let go, and the cloud
    /// mirror keeps theirs when an upload finds the provider moved on; both
    /// used to write a same-day name blind, so one could replace the other.
    /// The date is the device's, Gregorian whatever the calendar in use.
    static func createConflictedCopy(beside url: URL, holding data: Data) throws -> URL {
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let stamp = Date().formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        for attempt in 1...100 {
            var candidate = folder.appendingPathComponent(
                attempt == 1 ? "\(base) (conflicted copy \(stamp))" : "\(base) (conflicted copy \(stamp) \(attempt))")
            if !url.pathExtension.isEmpty { candidate.appendPathExtension(url.pathExtension) }
            // Metadata only, so a name already taken is passed without
            // downloading anything; the exclusive rename is still what refuses
            // one.
            if FileManager.default.fileExists(atPath: candidate.path) { continue }
            do {
                try createAtomically(data, at: candidate)
                return candidate
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// `create`, and atomic: the bytes go to a hidden file beside `url` and are
    /// renamed into place only if nothing is there (`RENAME_EXCL`). A quit
    /// that ends the process mid-write — the drain has a deadline — leaves no
    /// half of a copy under the copy's name; `create` writes in place.
    private static func createAtomically(_ data: Data, at url: URL) throws {
        var coordinatorError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinatorError) { actualURL in
            let staging = actualURL.deletingLastPathComponent()
                .appendingPathComponent(".\(UUID().uuidString).hellonotes-staging")
            do {
                try data.write(to: staging)
                defer { try? FileManager.default.removeItem(at: staging) }
                if renamex_np(staging.path, actualURL.path, UInt32(RENAME_EXCL)) != 0 {
                    let code = errno
                    throw code == EEXIST
                        ? CocoaError(.fileWriteFileExists)
                        : CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
                }
            } catch { writeError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }
    }

    /// Coordinated *create* of a new file that must not already exist (daily
    /// notes, new-note creation). Fails if a file is already there, preserving
    /// the `.withoutOverwriting` guarantee callers relied on.
    static func create(_ data: Data, at url: URL) throws {
        var coordinatorError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinatorError) { actualURL in
            do { try data.write(to: actualURL, options: .withoutOverwriting) }
            catch { writeError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }
    }

    /// Coordinated **move** — a rename, or a move into another folder.
    ///
    /// Renaming was the one vault mutation that called `FileManager.moveItem`
    /// directly, outside coordination. Inside the app's own container that
    /// works, which is why every test and every simulator run passed; on a
    /// **File Provider** folder — iCloud Drive, or a vault another app syncs —
    /// an uncoordinated move races the provider, and a provider that has not
    /// been told can put the old name back. A rename a sync service quietly
    /// reverts is indistinguishable, from the person's side, from one the app
    /// never made.
    ///
    /// `item(at:willMoveTo:)` and `didMoveTo:` are the part that matters: they
    /// tell every other presenter to *follow* the file instead of losing it.
    static func move(from source: URL, to destination: URL) throws {
        var coordinatorError: NSError?
        var moveError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: source, options: .forMoving,
                               writingItemAt: destination, options: .forReplacing,
                               error: &coordinatorError) { from, to in
            coordinator.item(at: from, willMoveTo: to)
            do { try FileManager.default.moveItem(at: from, to: to) }
            catch { moveError = error }
            coordinator.item(at: from, didMoveTo: to)
        }
        if let coordinatorError { throw coordinatorError }
        if let moveError { throw moveError }
    }

    /// `data` written to a file of its own beside where it will go — the
    /// system's replacement directory for that volume, which nothing walks —
    /// for `putInPlace` to put there later. Off the main actor: the write is
    /// the size of the file.
    static func stage(_ data: Data, for destination: URL) throws -> URL {
        let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                 appropriateFor: destination, create: true)
        let staged = folder.appendingPathComponent(UUID().uuidString)
        try data.write(to: staged)
        return staged
    }

    /// Coordinated: the file at `destination` replaced by the `staged` one, in
    /// one rename — a download, put in place after its checks.
    static func putInPlace(_ staged: URL, at destination: URL) throws {
        var coordinatorError: NSError?
        var replaceError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: destination, options: .forReplacing,
                               error: &coordinatorError) { to in
            do { _ = try FileManager.default.replaceItemAt(to, withItemAt: staged) }
            catch { replaceError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let replaceError { throw replaceError }
    }

    /// Coordinated **copy** — duplicating a note. Same reasoning as `move`:
    /// the source may be a cloud file that has to be read through the
    /// coordinator, and the destination is a write another presenter must see.
    static func copy(from source: URL, to destination: URL) throws {
        var coordinatorError: NSError?
        var copyError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: source, options: [],
                               writingItemAt: destination, options: .forReplacing,
                               error: &coordinatorError) { from, to in
            do { try FileManager.default.copyItem(at: from, to: to) }
            catch { copyError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
    }

    // MARK: - Download / eviction (cloud items)

    /// Ask the system to download an online-only file in the background
    /// (materialize it). Returns without waiting; the collection's scan / file
    /// watcher reflects the new state once the download completes.
    static func download(at url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    /// Download an online-only file **and wait for it to arrive**.
    ///
    /// `download(at:)` returns immediately — `startDownloadingUbiquitousItem`
    /// has no completion handler — so every caller that needs the bytes has to
    /// poll for them. `FileViewerView` learned that the hard way (an attachment
    /// previewed as a blank page for as long as you looked at it) and the
    /// editor never learned it at all: it read the placeholder, got nothing,
    /// and called the note empty.
    ///
    /// The deadline is there so a provider that never finishes leaves the user
    /// with a message rather than a spinner with no end.
    ///
    /// **`@concurrent`, or it polls on the main actor.** A plain `async`
    /// function on this `nonisolated` enum inherits its caller's actor under
    /// approachable concurrency, and both callers are main-actor classes — so
    /// every metadata query to the provider, and the download request, ran on
    /// the main thread every 200 ms for up to a minute. Measured by a probe
    /// built with this target's flags: main thread before and after the sleep
    /// without the attribute, the cooperative pool with it.
    /// - Returns: whether the content is available now.
    @discardableResult
    @concurrent
    static func materialise(at url: URL, timeout: Duration = .seconds(60)) async -> Bool {
        if isMaterialized(at: url) { return true }
        try? download(at: url)
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return isMaterialized(at: url) }
            if isMaterialized(at: url) { return true }
        }
        return isMaterialized(at: url)
    }

    /// Ask the system to free an item's local copy back to online-only. This is
    /// **best-effort**: for a File Provider domain we don't own, the provider has
    /// the final say and may keep or re-download the file.
    static func evict(at url: URL) throws {
        try FileManager.default.evictUbiquitousItem(at: url)
    }
}
