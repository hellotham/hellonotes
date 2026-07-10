//
//  Note.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import Foundation
import UniformTypeIdentifiers

/// A lightweight value type representing a single Markdown file on disk.
struct Note: Identifiable, Hashable {
    let id: UUID
    var title: String
    var fileURL: URL
    var lastModified: Date

    init(id: UUID = UUID(), title: String, fileURL: URL, lastModified: Date) {
        self.id = id
        self.title = title
        self.fileURL = fileURL
        self.lastModified = lastModified
    }
}
