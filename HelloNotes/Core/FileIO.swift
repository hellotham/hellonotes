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
    /// demand before returning its bytes. `options` as `Data(contentsOf:)`
    /// takes them — a PDF is read `.mappedIfSafe` (`FilePDFView`).
    static func readData(at url: URL, options: Data.ReadingOptions = []) throws -> Data {
        var coordinatorError: NSError?
        var result: Result<Data, Error>?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        // `options: []` = a normal read intent, which materializes the file.
        // (`.immediatelyAvailableMetadataOnly` would *avoid* materialization —
        // the opposite of what a content read wants.)
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { actualURL in
            result = Result { try Data(contentsOf: actualURL, options: options) }
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
        guard let values = try? currentResourceValues(at: url, keys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]),
            values.isUbiquitousItem == true,
            let status = values.ubiquitousItemDownloadingStatus
        else { return true }   // not a cloud item, or status unknown → treat as available
        return status != .notDownloaded
    }

    /// Whether the **newest** version of a file is here: stricter than
    /// `isMaterialized`, which counts an older copy on the device as here. A
    /// file that is not a cloud item, or whose state cannot be read, is
    /// current. What a preview waits for — nothing refreshes one when a newer
    /// version lands (`AttachmentBytes`).
    static func isCurrent(at url: URL) -> Bool {
        if let probe = materialisedProbes.withLock({ $0[url.path] }) { probe(Thread.isMainThread) }
        guard let values = try? currentResourceValues(at: url, keys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]),
            values.isUbiquitousItem == true
        else { return true }
        return values.ubiquitousItemDownloadingStatus == .current
    }

    /// A file's resource values **as they are now**.
    ///
    /// `URL.resourceValues(forKeys:)` answers from a cache kept on the URL,
    /// and only a turn of the main run loop clears it — which a GCD lane
    /// never has. So the download wait, asking the same URL every 200 ms on
    /// its lane (`DownloadWaiter`), read its first answer back for the whole
    /// minute: "not downloaded" at the first look was "not downloaded" at the
    /// three-hundredth, whatever had arrived, and the note's URL, kept from
    /// the walk, carried the walk's answer into the editor and into Try
    /// Again. Probed: one instance reported 3 bytes at six looks while the
    /// file held 50 (`theWaitReadsTheFileAsItIsNow`). A question about *now*
    /// is asked of a URL with no memory.
    static func currentResourceValues(at url: URL, keys: Set<URLResourceKey>) throws -> URLResourceValues {
        var asked = url
        asked.removeAllCachedResourceValues()
        return try asked.resourceValues(forKeys: keys)
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
        // Failed until the block runs: a coordinator that neither ran it nor
        // said why has written nothing (implemented.md §51.64).
        var writeError: Error? = CocoaError(.fileWriteUnknown)   // until the block runs
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { actualURL in
            writeError = nil
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
        var writeError: Error? = CocoaError(.fileWriteUnknown)   // until the block runs
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinatorError) { actualURL in
            writeError = nil
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
        var writeError: Error? = CocoaError(.fileWriteUnknown)   // until the block runs
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinatorError) { actualURL in
            writeError = nil
            do { try data.write(to: actualURL, options: .withoutOverwriting) }
            catch { writeError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }
    }

    /// Coordinated **folder** creation, and any folder it sits in that is not
    /// there yet. `FileManager.createDirectory` made folders in the vault
    /// behind every presenter's back — a provider's among them — where a
    /// coordinated write on the new folder's URL tells the presenters of the
    /// one it is made in (implemented.md §51.64). `withIntermediateDirectories:
    /// false` fails if the folder is already there, which a caller finding a
    /// free name relies on.
    ///
    /// **A folder that is there is left alone, uncoordinated**, as
    /// `FileManager` leaves it. A coordinated write on it is a change to it for
    /// every presenter of it — on iOS the collection's own, which took a daily
    /// note's folder, or a pasted picture's, for news — when nothing changes.
    /// (It waits for nothing held inside it: a write on a folder does not wait
    /// for a file in it, probed, where a delete of the folder does.)
    static func createDirectory(at url: URL, withIntermediateDirectories: Bool = true) throws {
        if withIntermediateDirectories {
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue { return }
        }
        var coordinatorError: NSError?
        var made: Result<Void, Error> = .failure(CocoaError(.fileWriteUnknown))
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinatorError) { actualURL in
            made = Result {
                try FileManager.default.createDirectory(at: actualURL,
                                                        withIntermediateDirectories: withIntermediateDirectories)
            }
        }
        if let coordinatorError { throw coordinatorError }
        try made.get()
    }

    /// Coordinated **trash** — `Trash.item`, which decides between the Trash
    /// and a delete for the platform, inside a coordinated write for deleting:
    /// a provider is told the item is going rather than finding it gone, and a
    /// presenter of it is asked to let go (`accommodatePresentedItemDeletion`).
    /// It was called bare, on the pool (implemented.md §51.64).
    @discardableResult
    static func trash(at url: URL) throws -> Trash.Outcome {
        var coordinatorError: NSError?
        var outcome: Result<Trash.Outcome, Error> = .failure(CocoaError(.fileWriteUnknown))
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinatorError) { actualURL in
            outcome = Result { try Trash.item(at: actualURL) }
        }
        if let coordinatorError { throw coordinatorError }
        return try outcome.get()
    }

    /// Coordinated **delete**, for what the app made and takes back — a new
    /// repository's folder after a create or a clone that failed, the
    /// self-test's scratch note — and never for what the person made, which
    /// goes to the Trash (`trash`). They were `FileManager.removeItem`, bare,
    /// in folders a cloud provider may keep (implemented.md §51.64).
    static func remove(at url: URL) throws {
        var coordinatorError: NSError?
        var removed: Result<Void, Error> = .failure(CocoaError(.fileWriteUnknown))
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinatorError) { actualURL in
            removed = Result { try FileManager.default.removeItem(at: actualURL) }
        }
        if let coordinatorError { throw coordinatorError }
        try removed.get()
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
        var moveError: Error? = CocoaError(.fileWriteUnknown)   // until the block runs
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: source, options: .forMoving,
                               writingItemAt: destination, options: .forReplacing,
                               error: &coordinatorError) { from, to in
            moveError = nil
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
        var replaceError: Error? = CocoaError(.fileWriteUnknown)   // until the block runs
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: destination, options: .forReplacing,
                               error: &coordinatorError) { to in
            replaceError = nil
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
        var copyError: Error? = CocoaError(.fileWriteUnknown)   // until the block runs
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: source, options: [],
                               writingItemAt: destination, options: .forReplacing,
                               error: &coordinatorError) { from, to in
            copyError = nil
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
    /// with a message rather than a spinner with no end — `waitForDownload`
    /// says which of the two ways it was not there.
    /// - Returns: whether the content is available now.
    @discardableResult
    static func materialise(at url: URL, timeout: Duration = .seconds(60)) async -> Bool {
        await waitForDownload(at: url, timeout: timeout) == .arrived
    }

    /// What waiting for a cloud file's bytes came to.
    enum DownloadWait: Sendable, Equatable {
        /// Here — or here all along.
        case arrived
        /// Asked for, and the provider still saying "not here" at the deadline.
        case notYet
        /// No answer from the provider by the deadline: a question to it had
        /// not come back, or could not be asked.
        case noAnswer
    }

    /// How much of a cloud file has to be here.
    enum DownloadNeed: Sendable, Equatable {
        /// Content to read. An older version on the device will do: a note
        /// opens from it, and a newer one is taken as any change on disk is
        /// (`EditorModel.reconcileWithDisk`).
        case content
        /// The newest version — what a preview waits for (`isCurrent`).
        case latest
    }

    /// The questions a wait puts to the file provider, and where it puts
    /// them: the real ones, or a test's stand-in for a provider that is slow,
    /// silent or absent.
    struct ProviderCalls: Sendable {
        /// Whether the file is here, as far as the need asks.
        var isHere: @Sendable (_ url: URL, _ need: DownloadNeed) -> Bool
        /// Ask for it to be downloaded.
        var askFor: @Sendable (_ url: URL) -> Void
        /// Where the questions are asked — one file's on one lane, in turn. A
        /// stand-in brings lanes of its own, so a provider a test holds silent
        /// holds up no one else's questions.
        var lanes: [DispatchQueue] = FileIO.sharedLanes

        static let live = ProviderCalls(
            isHere: { url, need in need == .latest ? FileIO.isCurrent(at: url) : FileIO.isMaterialized(at: url) },
            askFor: { url in try? FileIO.download(at: url) })

        /// The live calls, asked on the scans' lanes (`FileIO.onScanLane`).
        static let scans = ProviderCalls(isHere: live.isHere, askFor: live.askFor, lanes: FileIO.scanLanes)

        /// The live calls, asked on a lane of their own — an editor's, so its
        /// note's open, save, Keep Mine and look at the disk never wait behind
        /// another file's held I/O, and a save at quit is not lost behind one
        /// (implemented.md §51.63).
        static func ownLane(_ label: String) -> ProviderCalls {
            ProviderCalls(isHere: live.isHere, askFor: live.askFor,
                          lanes: [DispatchQueue(label: label, qos: .userInitiated)])
        }

        /// Sixteen serial queues: a silent provider holds at most one a file,
        /// and sixteen in all.
        static func makeLanes(_ label: String, qos: DispatchQoS = .userInitiated) -> [DispatchQueue] {
            (0..<16).map { DispatchQueue(label: "\(label).\($0)", qos: qos) }
        }

        func lane(for url: URL) -> DispatchQueue {
            lanes[Int(UInt(bitPattern: url.path.hashValue) % UInt(lanes.count))]
        }

        /// Do `body` — a synchronous call the file's provider can hold up: a
        /// coordinated read, write, move or copy, or a question to the provider
        /// — on the file's lane, and wait for it without holding a thread of
        /// the concurrency pool. On the pool, a read of a file its provider held
        /// kept one of the pool's few threads for the whole wait, and every
        /// sleeping task wakes through the pool — the main actor's too — so
        /// three at once stopped every task in the process on CI's three-core
        /// runner until a hold let go (implemented.md §51.62, §51.63). Throws
        /// what `body` throws, and nothing when it throws nothing.
        func onLane<T: Sendable, E: Error>(for url: URL,
                                           _ body: @escaping @Sendable () throws(E) -> T) async throws(E) -> T {
            let result: Result<T, E> = await withCheckedContinuation { continuation in
                lane(for: url).async { continuation.resume(returning: Result { () throws(E) -> T in try body() }) }
            }
            return try result.get()
        }
    }

    /// `materialise`, saying how it ended — and **ended by its deadline,
    /// whatever the provider does** (implemented.md §51.51, §51.52).
    ///
    /// Asking whether a file has come and asking for it are synchronous calls
    /// to the file provider, and one that never comes back is a thread held
    /// for good. The wait polled on the concurrency pool and read its clock
    /// between questions, so one such call held the "Downloading … from the
    /// cloud" banner up for good on an iPad. Each of these was then measured:
    /// - **Questions go on lanes of their own** — sixteen serial queues, one
    ///   file always on the same one. On the pool each held one of its few
    ///   threads; on a concurrent queue every Try Again took another of GCD's
    ///   capped threads, and at the cap nothing in the process ran. Now a
    ///   silent provider holds at most a lane per file, sixteen in all, and
    ///   nothing is held between questions: the next is scheduled, not slept
    ///   for.
    /// - **The deadline is a timer on a queue of its own** (`deadlines`),
    ///   which no question can hold up: on GCD's shared queue it waited behind
    ///   the very calls it was there to outlast. One monotonic deadline is
    ///   read by both sides.
    /// - **Which way it ended is true.** The questions say "not yet" at the
    ///   deadline while the provider is answering; only a question still out
    ///   a second past it — or never put, its lane held by another file's — is
    ///   "no answer". And once answered, nothing more is asked.
    static func waitForDownload(at url: URL, timeout: Duration = .seconds(60),
                                needing need: DownloadNeed = .content,
                                using provider: ProviderCalls = .live) async -> DownloadWait {
        let wait = DownloadWaiter(url: url, need: need, provider: provider, timeout: timeout)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { wait.start($0) }
        } onCancel: {
            wait.give(.notYet)
        }
    }

    /// The bytes of a file a note shows — a picture it embeds, or one its HTML
    /// points at: waited for if its provider has it online-only, with the
    /// deadline a download is given anywhere (`waitForDownload`), then read
    /// under coordination — the questions and the read on the scans' lanes,
    /// where the transclusions drawn beside it are read. A coordinated read of
    /// a file not here yet downloads it inside the read, and held its lane for
    /// as long as that took, with no end (implemented.md §51.64). `nil` when
    /// it is not here by then, or cannot be read; a file that is not there at
    /// all is not waited for (`isMaterialized`).
    static func embeddedData(at url: URL) async -> Data? {
        guard await waitForDownload(at: url, using: .scans) == .arrived else { return nil }
        return await onScanLane(for: url) { try? FileIO.readData(at: url) }
    }

    /// Where the app asks about one file at a time (`ProviderCalls.lanes`).
    static let sharedLanes = ProviderCalls.makeLanes("com.hellotham.HelloNotes.file-provider")
    /// Where loops over many files ask (`onScanLane`): lanes of their own, at
    /// utility priority, so a file a background scan waits on holds up no one
    /// else's open, save, rename or append.
    static let scanLanes = ProviderCalls.makeLanes("com.hellotham.HelloNotes.scans", qos: .utility)

    /// `ProviderCalls.onLane` on the app's own lanes, for one file at a time —
    /// a rename, an append, a new note, an export — from code with no
    /// stand-in provider to ask. A coordinated `FileIO` call goes through
    /// here, through an editor's `provider` (a lane of the editor's own), or
    /// through `onScanLane`; never `offMain`, whose synchronous body holds a
    /// thread of the pool for the whole wait (implemented.md §51.63). Folders
    /// are made and items deleted through `FileIO` as well (`createDirectory`,
    /// `trash`, `remove`), and a collection looks at its own folder on a lane
    /// of its own (`Collection.onRootLane`, §51.64). Not through any of them,
    /// by design: the walk's listings (`ResumableTreeWalk`).
    static func onLane<T: Sendable, E: Error>(for url: URL,
                                              _ body: @escaping @Sendable () throws(E) -> T) async throws(E) -> T {
        try await ProviderCalls.live.onLane(for: url, body)
    }

    /// `onLane` for a loop over many files — the search index, a rebuild, the
    /// Assistant's exact-text search — and for work in the background, on the
    /// scans' own lanes. On one set of lanes for everything, a file a scan
    /// waited on held up every other file on its lane — an open, a save, a
    /// rename — one file in sixteen (implemented.md §51.63).
    static func onScanLane<T: Sendable, E: Error>(for url: URL,
                                                  _ body: @escaping @Sendable () throws(E) -> T) async throws(E) -> T {
        try await ProviderCalls.scans.onLane(for: url, body)
    }

    /// Where deadlines are kept. Serial, so it is given a thread even when
    /// GCD's shared pool is full of calls that have not come back.
    static let deadlines = DispatchQueue(label: "com.hellotham.HelloNotes.deadlines", qos: .userInitiated)

    /// Ask the system to free an item's local copy back to online-only. This is
    /// **best-effort**: for a File Provider domain we don't own, the provider has
    /// the final say and may keep or re-download the file.
    static func evict(at url: URL) throws {
        try FileManager.default.evictUbiquitousItem(at: url)
    }
}

/// One wait for one file's download (`FileIO.waitForDownload`).
nonisolated private final class DownloadWaiter: @unchecked Sendable {
    private let url: URL
    private let need: FileIO.DownloadNeed
    private let provider: FileIO.ProviderCalls
    private let deadline: DispatchTime
    private let answer = OneAnswer<FileIO.DownloadWait>()

    init(url: URL, need: FileIO.DownloadNeed, provider: FileIO.ProviderCalls, timeout: Duration) {
        self.url = url
        self.need = need
        self.provider = provider
        deadline = .now() + timeout.dispatchInterval
    }

    func start(_ continuation: CheckedContinuation<FileIO.DownloadWait, Never>) {
        // Answered already — cancelled before it began — and nothing is asked.
        guard answer.expect(continuation) else { return }
        FileIO.deadlines.asyncAfter(deadline: deadline + .seconds(1)) { [self] in answer.give(.noAnswer) }
        provider.lane(for: url).async { [self] in look(first: true) }
    }

    func give(_ value: FileIO.DownloadWait) { answer.give(value) }

    /// One look — the first time, the request too — and the next one
    /// scheduled, not slept for.
    private func look(first: Bool) {
        guard !answer.isGiven else { return }
        if provider.isHere(url, need) { answer.give(.arrived); return }
        if first {
            guard !answer.isGiven else { return }
            provider.askFor(url)
        }
        let now = DispatchTime.now()
        guard now < deadline else { answer.give(.notYet); return }
        guard !answer.isGiven else { return }
        provider.lane(for: url).asyncAfter(deadline: min(now + .milliseconds(200), deadline)) { [self] in
            look(first: false)
        }
    }
}
