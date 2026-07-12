//
//  NoteRef.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//

import Foundation

/// Identifies a standalone note window. Deliberately a wrapper around the path
/// rather than a bare `URL`: SwiftUI/AppKit treat a `WindowGroup(for: URL.self)`
/// as a *file-document* scene, which pops an "Open" panel when macOS restores it
/// on launch. Using a non-URL `Codable` value avoids that document treatment.
struct NoteRef: Codable, Hashable {
    var path: String
    init(_ url: URL) { path = url.standardizedFileURL.path }
    var url: URL { URL(fileURLWithPath: path) }
}
