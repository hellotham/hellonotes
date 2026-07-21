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

enum FileIO {

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
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]),
            values.isUbiquitousItem == true,
            let status = values.ubiquitousItemDownloadingStatus
        else { return true }   // not a cloud item, or status unknown → treat as available
        return status != .notDownloaded
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

    // MARK: - Download / eviction (cloud items)

    /// Ask the system to download an online-only file in the background
    /// (materialize it). Returns without waiting; the collection's scan / file
    /// watcher reflects the new state once the download completes.
    static func download(at url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    /// Ask the system to free an item's local copy back to online-only. This is
    /// **best-effort**: for a File Provider domain we don't own, the provider has
    /// the final say and may keep or re-download the file.
    static func evict(at url: URL) throws {
        try FileManager.default.evictUbiquitousItem(at: url)
    }
}
