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

    init(title: String, fileURL: URL, lastModified: Date) {
        self.title = title
        self.fileURL = fileURL
        self.lastModified = lastModified
    }
}
