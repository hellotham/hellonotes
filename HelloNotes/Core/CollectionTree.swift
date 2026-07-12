//
//  CollectionTree.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import Foundation

/// How notes are ordered within a folder.
enum SortOrder: String, CaseIterable, Identifiable, Hashable {
    case name = "Name"
    case modified = "Date Modified"
    var id: String { rawValue }
    var systemImage: String { self == .name ? "textformat" : "clock" }
}

/// A node in the collection's folder tree: either a folder (with `children`) or a
/// note (leaf). `id` is the item's path, stable across re-indexing.
struct CollectionTreeNode: Identifiable, Hashable {
    let id: String
    let name: String
    let note: Note?
    var file: CollectionFile? = nil
    var children: [CollectionTreeNode]?

    var isFolder: Bool { note == nil && file == nil }
}

/// Builds a folder tree from a flat note list by their paths relative to the
/// collection root. Folders come before notes; folders sort by name, notes by the
/// chosen order. `nonisolated` — pure and callable from any actor.
nonisolated enum CollectionTree {

    static func build(from notes: [Note], attachments: [CollectionFile] = [],
                      rootURL: URL, sort: SortOrder) -> [CollectionTreeNode] {
        let root = Folder()
        let rootDepth = rootURL.standardizedFileURL.pathComponents.count

        func folder(for fileURL: URL) -> Folder? {
            let components = fileURL.standardizedFileURL.pathComponents
            guard components.count > rootDepth else { return nil }
            var folder = root
            for dir in components[rootDepth...].dropLast() {
                folder = folder.child(named: String(dir))
            }
            return folder
        }

        for note in notes { folder(for: note.fileURL)?.notes.append(note) }
        for file in attachments { folder(for: file.url)?.files.append(file) }

        return nodes(from: root, path: "", sort: sort)
    }

    // MARK: - Private

    private final class Folder {
        var subfolders: [String: Folder] = [:]
        var notes: [Note] = []
        var files: [CollectionFile] = []

        func child(named name: String) -> Folder {
            if let existing = subfolders[name] { return existing }
            let created = Folder()
            subfolders[name] = created
            return created
        }
    }

    private static func nodes(from folder: Folder, path: String, sort: SortOrder) -> [CollectionTreeNode] {
        var result: [CollectionTreeNode] = []

        for name in folder.subfolders.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let childPath = "\(path)/\(name)"
            result.append(CollectionTreeNode(
                id: childPath,
                name: name,
                note: nil,
                children: nodes(from: folder.subfolders[name]!, path: childPath, sort: sort)
            ))
        }

        let sortedNotes: [Note]
        switch sort {
        case .name:
            sortedNotes = folder.notes.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .modified:
            sortedNotes = folder.notes.sorted { $0.lastModified > $1.lastModified }
        }
        for note in sortedNotes {
            result.append(CollectionTreeNode(id: note.fileURL.path, name: note.title, note: note, children: nil))
        }

        let sortedFiles = folder.files.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        for file in sortedFiles {
            result.append(CollectionTreeNode(id: file.url.path, name: file.name, note: nil, file: file, children: nil))
        }

        return result
    }
}
