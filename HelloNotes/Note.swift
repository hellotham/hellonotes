//
//  Note.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import Foundation
import UniformTypeIdentifiers

/// A lightweight value type representing a single Markdown file on disk.
///
/// Identity is the file's URL: a note *is* its file, so the URL is stable
/// across re-indexing (unlike a random `UUID`, which would break list
/// selection every time the collection is rescanned).
nonisolated struct Note: Identifiable, Hashable {
    var id: URL { fileURL }
    var title: String
    var fileURL: URL
    var lastModified: Date
    /// File size in bytes, captured at scan time. Together with `lastModified`
    /// it fingerprints the content so the index cache can tell whether a note
    /// changed without reading it.
    var fileSize: Int
    /// True when the note lives in a cloud (File Provider) folder and its
    /// content is *not* downloaded locally — "online-only." Captured at scan
    /// time (it's free — the scan already reads resource values). Drives the
    /// cloud badge and gates content indexing (see `FileIO.isMaterialized`).
    var isOnlineOnly: Bool

    init(title: String, fileURL: URL, lastModified: Date, fileSize: Int = 0, isOnlineOnly: Bool = false) {
        self.title = title
        self.fileURL = fileURL
        self.lastModified = lastModified
        self.fileSize = fileSize
        self.isOnlineOnly = isOnlineOnly
    }
}

extension Note {
    /// Newest first — and, among notes saved in the same second, by title and
    /// then path, so the order is the same on every run and every device.
    ///
    /// Anything written, copied or checked out in one batch shares a date, and
    /// a date alone left those notes in whatever order the sort was handed —
    /// a dictionary's, which changes with the process's hash seed. The Mac and
    /// the iPad listed the same sample collection in two different orders
    /// (`scripts/window-parity.sh`), and so could one Mac on two launches.
    nonisolated static func newestFirst(_ a: Note, _ b: Note) -> Bool {
        if a.lastModified != b.lastModified { return a.lastModified > b.lastModified }
        let byTitle = a.title.localizedStandardCompare(b.title)
        if byTitle != .orderedSame { return byTitle == .orderedAscending }
        return a.fileURL.path < b.fileURL.path
    }
}
