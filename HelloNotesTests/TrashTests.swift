//
//  TrashTests.swift
//  HelloNotesTests
//
//  A test host's Trash is its own.
//
//  The hosted suite deletes notes and folders the way the app does, and on
//  the Mac each went to the Trash of the Mac running the suite — dozens a day,
//  each named as a test names what it deletes (implemented.md §51.65).
//

import Foundation
import Testing
@testable import HelloNotes

struct TrashTests {

    /// **What a test trashes goes to the test host's own Trash** — moved, as
    /// the Trash moves it, and said to be trashed — never to the Mac's.
    @Test func whatATestTrashesGoesToTheHostsOwnTrash() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "hn-trash-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let note = folder.appending(path: "Trashed \(UUID().uuidString).md")
        try Data("# Trashed\n".utf8).write(to: note)
        let inner = folder.appending(path: "Folder \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)

        #if os(macOS)
        let bin = try #require(Trash.testBin, "a test host on the Mac has no Trash of its own")
        #expect(try Trash.item(at: note) == .trashed)
        #expect(try Trash.item(at: inner) == .trashed)
        let binned = Set((FileManager.default.enumerator(at: bin, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.lastPathComponent }) ?? [])
        #expect(binned.contains(note.lastPathComponent),
                "a note a test trashed went somewhere other than the host's own Trash")
        #expect(binned.contains(inner.lastPathComponent),
                "a folder a test trashed went somewhere other than the host's own Trash")
        #else
        // An app's container has no Trash, and nothing a test deletes in the
        // simulator reaches the Mac's.
        #expect(Trash.testBin == nil)
        _ = try Trash.item(at: note)
        _ = try Trash.item(at: inner)
        #endif
        #expect(!FileManager.default.fileExists(atPath: note.path))
        #expect(!FileManager.default.fileExists(atPath: inner.path))
    }

    /// **Only `Trash.item` asks for the system Trash**, so the host's own
    /// catches everything a test deletes. Another caller would put what it
    /// deletes in the Mac's Trash again — and on iOS go without the fallback
    /// that makes a delete there a delete.
    @Test func onlyTrashItemAsksForTheSystemTrash() throws {
        let repo = RepoFile.root
        let call = ".trash" + "Item("     // in two parts, so this file does not find itself
        var callers: [String] = []
        for folder in ["HelloNotes", "HelloNotesTests", "Packages/NotesEditor/Sources"] {
            let files = FileManager.default
                .enumerator(at: repo.appending(path: folder), includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" } ?? []
            for file in files where file.lastPathComponent != "Trash.swift" {
                if let text = try? String(contentsOf: file, encoding: .utf8), text.contains(call) {
                    callers.append(file.lastPathComponent)
                }
            }
        }
        #expect(callers.isEmpty, "the system Trash is asked for by \(callers), not by `Trash.item` alone")
        // And `Trash.item` does ask for it: with no caller at all, this would
        // pass for nothing.
        let trash = try String(contentsOf: repo.appending(path: "HelloNotes/Core/Trash.swift"), encoding: .utf8)
        #expect(trash.contains(call), "`Trash.item` no longer asks for the system Trash")
    }
}
