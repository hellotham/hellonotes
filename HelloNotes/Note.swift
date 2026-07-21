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
