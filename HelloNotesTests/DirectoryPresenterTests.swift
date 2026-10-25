//
//  DirectoryPresenterTests.swift
//  HelloNotesTests
//
//  The iOS folder watcher, driven on the Mac: `DirectoryPresenter` is only ever
//  run on iOS, and a callback it never implemented — a subitem moved under file
//  coordination — went unnoticed for its whole life. A rename made in the
//  Files app, or by Obsidian sharing the folder, was never heard: the sidebar
//  kept the old name until an unrelated change walked the folder.
//

import Foundation
import Synchronization
import Testing
@testable import HelloNotes

@Suite
struct DirectoryPresenterTests {

    /// What a presenter has reported, read from the test after the presenter's
    /// own queue has written it.
    private final class Heard: Sendable {
        private let events = Mutex<[DirectoryEvent]>([])
        func add(_ event: DirectoryEvent) { events.withLock { $0.append(event) } }
        var all: [DirectoryEvent] { events.withLock { $0 } }
        /// Every path any `.itemsChanged` carried.
        var paths: [String] {
            all.flatMap { event -> [String] in
                if case .itemsChanged(let paths) = event { return paths }
                return []
            }
        }
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "presenter-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Wait for `condition`, in looks (`Waits.Patience`), never seconds.
    private func eventually(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        var patience = Waits.Patience(timeout)
        while patience.lasts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// **A note renamed under file coordination is heard as one move, by
    /// both names, at once.** The move is the app's own `FileIO.move` — what
    /// the Files app and any coordinated mover do — made with a coordinator
    /// of its own, as another app's would be. Control: without
    /// `presentedSubitem(at:didMoveTo:)` the coordinator falls back to its
    /// other callbacks, which arrive about a second later, one name each.
    @Test func aSubitemMovedUnderCoordinationIsHeardByBothNames() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appending(path: "Untitled.md")
        let new = folder.appending(path: "Titled.md")
        try Data("# Untitled\n".utf8).write(to: old)

        let heard = Heard()
        let presenter = DirectoryPresenter(root: folder) { heard.add($0) }
        presenter.start()
        defer { presenter.stop() }

        try await offMain { try FileIO.move(from: old, to: new) }
        func oneEventWithBoth() -> Bool {
            heard.all.contains { event in
                guard case .itemsChanged(let paths) = event else { return false }
                let standardized = paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
                return standardized.contains(old.standardizedFileURL.path)
                    && standardized.contains(new.standardizedFileURL.path)
            }
        }
        let both = await eventually(.seconds(3)) { oneEventWithBoth() }
        #expect(both, "the move was not reported as one event by both names; heard: \(heard.all)")
    }

    /// And a change written under coordination is still heard, as it was.
    @Test func aSubitemChangedUnderCoordinationIsHeard() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let note = folder.appending(path: "Note.md")
        try Data("# Note\n".utf8).write(to: note)

        let heard = Heard()
        let presenter = DirectoryPresenter(root: folder) { heard.add($0) }
        presenter.start()
        defer { presenter.stop() }

        try await offMain { try FileIO.write(Data("# Note\n\nchanged\n".utf8), to: note) }
        let changed = await eventually {
            heard.paths.contains { URL(fileURLWithPath: $0).standardizedFileURL.path == note.standardizedFileURL.path }
                || heard.all.contains(.unspecifiedChange)
        }
        #expect(changed, "the write was not reported: \(heard.all)")
    }
}
