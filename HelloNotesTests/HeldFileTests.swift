//
//  HeldFileTests.swift
//  HelloNotesTests
//
//  A file its provider holds holds a lane, never a thread of the pool — and
//  never another file's lane.
//
//  A coordinated read or write waits for as long as another process holds the
//  file — a cloud provider writing it, another app saving it. On the
//  concurrency pool, which has a thread a core, each such wait held a thread;
//  and every sleeping task in the process wakes through the pool, the main
//  actor's too. So with as many files held as the pool has threads, and a
//  wait on each, nothing else ran: CI's three-core runner showed it with
//  three loading notes (implemented.md §51.62), and the app's saves, looks at
//  the disk, appends and searches all waited the same way (§51.63). Moved onto
//  lanes, a held file then held up whatever else shared its lane — so an
//  editor asks on a lane of its own, and loops over many files on lanes of
//  theirs.
//

import Foundation
import Synchronization
import Testing
@testable import HelloNotes

/// One test at a time: the first two hold more files than the pool has
/// threads, and run side by side one's breakers freed the pool for the other —
/// under the negative control, the save test passed on the look test's
/// release.
@Suite(.serialized) @MainActor
struct HeldFileTests {

    /// **Saves waiting on held files hold no thread of the pool.** Each note
    /// is loaded and typed into, its file held, and saved: the save waits on
    /// its lane for the file to be let go. Meanwhile a task that sleeps keeps
    /// waking. Written on the pool (`offMain`), each save held a thread until
    /// its file was let go, and with more held than there are threads nothing
    /// woke until the breaker let them go.
    @Test(.timeLimit(.minutes(2)))
    func savesWaitingOnHeldFilesHoldNoThreadOfThePool() async throws {
        try await whileHeld(typing: true, { editor in await editor.save() }, then: { editor in
            let url = try #require(editor.note?.fileURL)
            #expect(try String(contentsOf: url, encoding: .utf8).hasSuffix("Typed while it was held.\n"),
                    "the save did not write once the file was let go")
            #expect(!editor.isDirty)
        })
    }

    /// **Looks at the disk waiting on held files hold no thread of the pool**
    /// — the editor's, when the folder says a note changed
    /// (`EditorModel.reconcileWithDisk`), which reads the file to compare.
    @Test(.timeLimit(.minutes(2)))
    func looksAtHeldFilesHoldNoThreadOfThePool() async throws {
        try await whileHeld(typing: false, { editor in await editor.reconcileWithDisk() }, then: { editor in
            #expect(!editor.hasConflict, "an unchanged note was taken for a change")
        })
    }

    /// **A save never waits behind another file's hold.** The other file is on
    /// the app's lane this note's path falls on, held, with a read waiting on
    /// it — and the save goes, on the editor's own lane. On the app's lanes it
    /// queued behind the other file for as long as that file's provider held
    /// it, and at quit, past the five seconds a flush is given, it was lost
    /// (implemented.md §51.63).
    @Test(.timeLimit(.minutes(1)))
    func aSaveNeverWaitsBehindAnotherFilesHold() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (mine, other) = try twoFilesOnOneLane(in: folder, lanes: FileIO.ProviderCalls.live)
        let editor = EditorModel()
        await editor.open(Note(title: "Mine", fileURL: mine, lastModified: Date(), fileSize: 8))
        try #require(editor.isLoaded)

        let hold = ProviderHold(other, breaker: .seconds(50))
        defer { hold.release() }
        let reading = Task { await FileIO.onLane(for: other) { try? FileIO.readString(at: other) } }
        try await waitUntilBusy(FileIO.ProviderCalls.live.lane(for: other))

        editor.text += "Typed beside a held file.\n"
        try await finishes("the save waited behind another file's hold") { await editor.save() }
        #expect(!hold.isLetGo, "the save went only once the other file was let go")
        hold.release()
        _ = await reading.value
        #expect(try String(contentsOf: mine, encoding: .utf8).hasSuffix("Typed beside a held file.\n"))
    }

    /// **A scan waiting on a held file holds up no one-file operation** — a
    /// rename, an append, an open — of another file on the lane it would
    /// share. The scans ask on lanes of their own; on one set for everything,
    /// one file in sixteen waited behind whatever a background scan was
    /// waiting on (implemented.md §51.63).
    @Test(.timeLimit(.minutes(1)))
    func aScanWaitingOnAHeldFileHoldsUpNoOneFileOperation() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // On the same lane in either set: the two are the same size and hash
        // the same way.
        let (mine, other) = try twoFilesOnOneLane(in: folder, lanes: FileIO.ProviderCalls.live)

        let hold = ProviderHold(other, breaker: .seconds(50))
        defer { hold.release() }
        let scanning = Task { await FileIO.onScanLane(for: other) { try? FileIO.readString(at: other) } }
        try await waitUntilBusy(FileIO.ProviderCalls.scans.lane(for: other))

        try await finishes("a one-file read waited behind a scan of another file") {
            _ = await FileIO.onLane(for: mine) { try? FileIO.readString(at: mine) }
        }
        #expect(!hold.isLetGo, "the read went only once the scan's file was let go")
        hold.release()
        _ = await scanning.value
    }

    // MARK: - Helpers

    /// Open an editor on each of more files than the pool has threads, hold
    /// every file, start `step` on each, and see whether a task that sleeps
    /// off the main actor goes on waking while every step waits; then let the
    /// files go, and `check` each editor once its step is done. Each editor
    /// asks on a lane of its own (`EditorModel.provider`), so the test holds
    /// none of the app's.
    private func whileHeld(typing: Bool,
                           _ step: @escaping @MainActor (EditorModel) async -> Void,
                           then check: (EditorModel) throws -> Void) async throws {
        let count = ProcessInfo.processInfo.activeProcessorCount + 2
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        var editors: [EditorModel] = []
        for i in 0..<count {
            let body = "# Note \(i)\n"
            let url = folder.appending(path: "Note \(i).md")
            try Data(body.utf8).write(to: url)
            let editor = EditorModel()
            await editor.open(Note(title: "Note \(i)", fileURL: url, lastModified: Date(), fileSize: body.utf8.count))
            try #require(editor.isLoaded && editor.text == body, "note \(i) did not open")
            if typing { editor.text += "Typed while it was held.\n" }
            editors.append(editor)
        }

        // Held, with a breaker the stopped process cannot hold up.
        let holds = try editors.map { ProviderHold(try #require($0.note?.fileURL), breaker: .seconds(60)) }
        defer { holds.forEach { $0.release() } }
        let steps = editors.map { editor in Task { @MainActor in await step(editor) } }

        // A task that sleeps, off the main actor: every wake-up goes through the pool.
        let ticks = Counter()
        let ticker = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                ticks.add()
            }
        }
        defer { ticker.cancel() }
        let from = ticks.value
        var patience = Waits.Patience(.seconds(30))
        while ticks.value < from + 20, patience.lasts { try await Task.sleep(for: .milliseconds(10)) }

        let woke = ticks.value - from
        let stillHeld = holds.filter { !$0.isLetGo }.count
        #expect(woke >= 20 && stillHeld == count,
                "the process stopped while \(count) files were held: \(woke) wake-ups, \(stillHeld) files still held")
        // The premise, while the files are still held — after a stop the
        // breaker has let them go: every step is on its file's lane, waiting.
        // A marker put on each lane after it cannot run until the file is let
        // go; a step that never reached its lane lets its marker run, and
        // would pass this test whatever held the pool.
        if stillHeld == count {
            let markers = Counter()
            for editor in editors {
                guard let url = editor.note?.fileURL else { continue }
                editor.provider.lane(for: url).async { markers.add() }
            }
            var grace = Waits.Patience(.milliseconds(300))
            while markers.value == 0, grace.lasts { try await Task.sleep(for: .milliseconds(10)) }
            #expect(markers.value == 0, "the premise: \(markers.value) of \(count) steps were not waiting on their files")
        }

        holds.forEach { $0.release() }
        for step in steps { await step.value }
        for editor in editors { try check(editor) }
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "hn-held-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Two notes whose paths fall on one lane of `lanes` — the second found by
    /// trying names, since a path's hash is the process's own.
    private func twoFilesOnOneLane(in folder: URL, lanes: FileIO.ProviderCalls) throws -> (URL, URL) {
        let mine = folder.appending(path: "Mine.md")
        try Data("# Mine\n".utf8).write(to: mine)
        for i in 0..<1_000 {
            let other = folder.appending(path: "Other \(i).md")
            guard lanes.lane(for: other) === lanes.lane(for: mine) else { continue }
            try Data("# Other\n".utf8).write(to: other)
            return (mine, other)
        }
        throw CocoaError(.fileNoSuchFile)
    }

    /// Wait until `lane` is busy — a marker put on it does not run — which a
    /// body waiting on a held file makes it.
    private func waitUntilBusy(_ lane: DispatchQueue, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        var patience = Waits.Patience(.seconds(10))
        while patience.lasts {
            let ran = Counter()
            lane.async { ran.add() }
            try await Task.sleep(for: .milliseconds(50))
            if ran.value == 0 { return }
        }
        Issue.record("the lane never waited on the held file, so this tests nothing", sourceLocation: sourceLocation)
    }

    /// Run `step` and wait for it with the test's patience, counted in looks.
    private func finishes(_ why: Comment, _ step: @escaping @MainActor () async -> Void,
                          sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let done = Counter()
        Task { @MainActor in
            await step()
            done.add()
        }
        var patience = Waits.Patience(.seconds(10))
        while done.value == 0, patience.lasts { try await Task.sleep(for: .milliseconds(10)) }
        #expect(done.value == 1, why, sourceLocation: sourceLocation)
    }

    /// A count kept across tasks and lanes — a `Mutex` is not copyable, so a
    /// closure cannot capture one itself.
    private final class Counter: Sendable {
        private let count = Mutex(0)
        func add() { count.withLock { $0 += 1 } }
        var value: Int { count.withLock { $0 } }
    }
}
