//
//  MainActorBudgetTests.swift
//  HelloNotesTests
//
//  Created by Chris Tham on 18/8/2026.
//

import Testing
import Foundation
@testable import HelloNotes

/// The golden rule, as a number.
///
/// > The main editor loop can never be blocked for any reason — folder scans,
/// > search, index rebuild, AI, anything.
///
/// A rule stated in prose is a rule that gets argued with. Twice now a fix was
/// justified by reasoning about which code runs on which thread, and twice the
/// reasoning was locally correct and the editor still froze. So the rule is
/// measured instead: a background task asks the main actor to answer, over and
/// over, while the app does its worst — and records how long it ever had to wait.
///
/// **These tests are expected to FAIL until the indexer work lands.** They are
/// the baseline, written first on purpose. A failure here is the bug, printed as
/// a number, and the number is what says whether a change helped.
@MainActor
struct MainActorBudgetTests {

    /// How long the main actor may ever take to answer. Six dropped frames.
    private static let budget: Duration = .milliseconds(100)

    /// Measures the worst delay the main actor ever imposes while `work` runs.
    ///
    /// The probe deliberately lives off the main actor and communicates through
    /// a lock rather than by hopping back — asking the main actor how blocked it
    /// is would queue behind the very blockage being measured, and report zero.
    private func worstMainActorLatency(
        while work: @MainActor () async -> Void
    ) async -> Duration {
        let recorder = LatencyRecorder()
        let probe = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                let asked = ContinuousClock.now
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                guard answered.wait(timeout: .now() + .seconds(60)) != .timedOut else {
                    recorder.record(.seconds(60))
                    return
                }
                recorder.record(ContinuousClock.now - asked)
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        await work()
        probe.cancel()
        return recorder.worst
    }

    /// A vault of `noteCount` notes spread over a directory tree.
    private func makeVault(noteCount: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hn-budget-\(UUID().uuidString)", isDirectory: true)
        let perFolder = 20
        for index in 0..<noteCount {
            let folder = root.appendingPathComponent("d\(index / perFolder)", isDirectory: true)
            if index % perFolder == 0 {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            try Data("# Note \(index)\n\nBody with [[Note \(index % 50)]] and #tag\(index % 30).\n".utf8)
                .write(to: folder.appendingPathComponent("Note \(index).md"))
        }
        return root
    }

    // MARK: - The measurements

    /// Scanning a realistic vault must not block the editor. This is the
    /// reported bug, expressed as an assertion.
    @Test func scanningALargeVaultNeverBlocksTheMainActor() async throws {
        let root = try makeVault(noteCount: 2_000)
        defer { try? FileManager.default.removeItem(at: root) }
        let collection = Collection(rootURL: root)

        let worst = await worstMainActorLatency {
            await collection.scanOffMain()
        }
        print("BUDGET scan(2000): worst main-actor latency \(worst)")
        #expect(worst < Self.budget,
                "a scan blocked the main actor for \(worst); the editor is unusable for that long")
    }

    /// Rebuilding the derived indexes must not block it either — `refreshDerived`
    /// creates a `Task { }` from a `@MainActor` context, which *inherits* the
    /// main actor, so the link-graph rebuild is main-thread work despite looking
    /// asynchronous.
    @Test func rebuildingDerivedIndexesNeverBlocksTheMainActor() async throws {
        let root = try makeVault(noteCount: 2_000)
        defer { try? FileManager.default.removeItem(at: root) }
        let collection = Collection(rootURL: root)
        await collection.scanOffMain()

        let worst = await worstMainActorLatency {
            collection.refreshDerived(force: true)
            // Give the rebuild time to actually run; the call itself returns
            // immediately and the work is what we are measuring.
            try? await Task.sleep(for: .seconds(3))
        }
        print("BUDGET refreshDerived(2000): worst main-actor latency \(worst)")
        #expect(worst < Self.budget,
                "an index rebuild blocked the main actor for \(worst)")
    }

    /// Creating a note is an O(1) change and must cost O(1) of the user's time.
    @Test func creatingANoteNeverBlocksTheMainActor() async throws {
        let root = try makeVault(noteCount: 2_000)
        defer { try? FileManager.default.removeItem(at: root) }
        let collection = Collection(rootURL: root)
        await collection.scanOffMain()

        let worst = await worstMainActorLatency {
            _ = await collection.createNote(title: "Budget Probe")
        }
        print("BUDGET createNote(2000): worst main-actor latency \(worst)")
        #expect(worst < Self.budget,
                "creating one note blocked the main actor for \(worst)")
    }

    /// Naming a note is a rename, and a new note opens with its title focused —
    /// so this is the path the user is on while typing.
    @Test func renamingANoteNeverBlocksTheMainActor() async throws {
        let root = try makeVault(noteCount: 2_000)
        defer { try? FileManager.default.removeItem(at: root) }
        let collection = Collection(rootURL: root)
        await collection.scanOffMain()
        let target = try #require(collection.note(titled: "Note 7"))

        let worst = await worstMainActorLatency {
            _ = await collection.renameNote(target, to: "Renamed While Typing")
        }
        print("BUDGET renameNote(2000): worst main-actor latency \(worst)")
        #expect(worst < Self.budget,
                "renaming one note blocked the main actor for \(worst)")
    }
}

/// Thread-safe worst-case accumulator for the probe.
private final class LatencyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration = .zero

    func record(_ latency: Duration) {
        lock.lock()
        if latency > value { value = latency }
        lock.unlock()
    }

    var worst: Duration {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
