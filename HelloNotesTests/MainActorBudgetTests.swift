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
/// **Run this suite alone**, and never as part of the whole test run:
///
///     xcodebuild test -project HelloNotes.xcodeproj -scheme HelloNotes \
///       -destination 'platform=macOS' \
///       -only-testing:HelloNotesTests/MainActorBudgetTests
///
/// It is **skipped unless `HN_BUDGET_TESTS` is set**, because it cannot give a
/// true answer inside a full run and a suite that always fails is a suite
/// everyone learns to ignore:
///
///     HN_BUDGET_TESTS=1 ./scripts/run-tests.sh \
///       -only-testing:HelloNotesTests/MainActorBudgetTests
///
/// It measures main-thread CPU, and the main thread is shared. Swift Testing
/// runs tests concurrently and every test in this target is `@MainActor`, so a
/// measurement taken during a normal run also counts whatever *other* tests
/// were doing on the main thread at the time — which read as 3.4 seconds of CPU
/// for a test whose entire body is a two-second sleep. `.serialized` fixes the
/// contention inside this suite; running the suite by itself fixes the rest.
///
/// This is the fourth instrument for this measurement and the third to be caught
/// by its own control. The controls stay first in the file for that reason.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HN_BUDGET_TESTS"] != nil,
                             "measures main-thread CPU; set HN_BUDGET_TESTS=1 and run this suite alone"))
@MainActor
struct MainActorBudgetTests {

    /// How much main-thread CPU an operation may consume. 100ms is roughly six
    /// dropped frames — past "a person notices" and well short of "an ordinary
    /// layout pass".
    private static let budget: Double = 0.100

    /// How much CPU the **main thread** burns while `work` runs.
    ///
    /// Third instrument, and the first one that survives its own control.
    ///
    /// Two dispatch-latency probes came before it and both lied. The first ran
    /// on the cooperative pool and measured its own starvation by the walk's
    /// file I/O. The second used a real `Thread` — and still reported ~3s on a
    /// completely idle main actor, because inside a `@MainActor` test the
    /// harness parks the main thread instead of servicing its runloop, so
    /// nothing queued with `DispatchQueue.main.async` runs until the test's
    /// `await` returns. Latency is simply not measurable from in here.
    ///
    /// CPU time is, and it answers the question that actually matters: the rule
    /// is "the main thread does not do this work", and a thread that is not
    /// doing work does not burn CPU. It needs no runloop, no second thread and
    /// no assumptions about scheduling — and unlike latency it cannot be
    /// inflated by the harness.
    private func mainThreadCPU(
        while work: @MainActor () async -> Void
    ) async -> Double {
        let before = Self.mainThreadCPUSeconds()
        await work()
        return Self.mainThreadCPUSeconds() - before
    }

    /// Cumulative user+system CPU seconds for the calling thread. `@MainActor`
    /// callers therefore measure the main thread.
    private static func mainThreadCPUSeconds() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let port = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, port) }

        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
             + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
    }

    /// Retained only for reference; see `mainThreadCPU`.
    private func worstMainActorLatency(
        while work: @MainActor () async -> Void
    ) async -> Duration {
        let recorder = LatencyRecorder()
        // A dedicated `Thread`, **not** `Task.detached`.
        //
        // The first version of this probe used a detached task, which runs on
        // the cooperative pool — the same pool the walk saturates with blocking
        // file I/O. The probe was then starved *after* dispatching to main, so
        // the interval it measured included its own descheduling and had
        // nothing to do with the main actor. It reported 2.3s before a change
        // that moved work off the main actor, and 2.8s after: an instrument
        // measuring the wrong thing, and reporting no improvement because it
        // could not see one. A real thread cannot be starved by the pool.
        // (`MainActorWatchdog` uses a `Thread` for exactly this reason.)
        let probe = Thread {
            while !Thread.current.isCancelled {
                let asked = ContinuousClock.now
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                if answered.wait(timeout: .now() + .seconds(60)) == .timedOut {
                    recorder.record(.seconds(60))
                    return
                }
                recorder.record(ContinuousClock.now - asked)
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        probe.qualityOfService = .userInitiated
        probe.start()
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

    // MARK: - Controls, so the instrument is not the thing being measured

    /// The probe must report ~nothing when nothing is happening.
    ///
    /// Without this, every number below is unfalsifiable. The first version of
    /// this probe ran on the cooperative pool and reported seconds of "main
    /// actor latency" that were really its own starvation — a believable number,
    /// moving in a believable direction, and entirely wrong.
    @Test func theProbeReportsNothingWhenNothingBlocks() async {
        let cpu = await mainThreadCPU {
            try? await Task.sleep(for: .seconds(2))
        }
        print("CONTROL idle: main-thread CPU \(cpu)s")
        #expect(cpu < Self.budget, "the instrument reports \(cpu)s of CPU on an idle main thread")
    }

    /// The walk alone, with no `Collection` involved. If this blocks, the
    /// problem is in the walk or its source, not in what consumes it.
    @Test func theWalkAloneDoesNotBlockTheMainActor() async throws {
        let root = try makeVault(noteCount: 2_000)
        defer { try? FileManager.default.removeItem(at: root) }

        let cpu = await mainThreadCPU {
            let source = LocalTreeSource(root: root)
            _ = await Task.detached(priority: .userInitiated) {
                await ResumableTreeWalk.run(source: source) { _ in }
            }.value
        }
        print("CONTROL walk-only(2000): main-thread CPU \(cpu)s")
        #expect(cpu < Self.budget,
                "the walk burned \(cpu)s of main-thread CPU with no Collection involved")
    }

    // MARK: - The measurements

    /// Scanning a realistic vault must not block the editor. This is the
    /// reported bug, expressed as an assertion.
    @Test func scanningALargeVaultNeverBlocksTheMainActor() async throws {
        let root = try makeVault(noteCount: 2_000)
        defer { try? FileManager.default.removeItem(at: root) }
        let collection = Collection(rootURL: root)

        let cpu = await mainThreadCPU {
            await collection.scanOffMain()
        }
        print("BUDGET scan(2000): main-thread CPU \(cpu)s")
        #expect(cpu < Self.budget,
                "a scan burned \(cpu)s of main-thread CPU; the editor is unusable for that long")
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

        let cpu = await mainThreadCPU {
            collection.refreshDerived(force: true)
            // Give the rebuild time to actually run; the call itself returns
            // immediately and the work is what we are measuring.
            try? await Task.sleep(for: .seconds(3))
        }
        print("BUDGET refreshDerived(2000): main-thread CPU \(cpu)s")
        #expect(cpu < Self.budget, "an index rebuild burned \(cpu)s of main-thread CPU")
    }

    /// Creating a note is an O(1) change and must cost O(1) of the user's time.
    @Test func creatingANoteNeverBlocksTheMainActor() async throws {
        let root = try makeVault(noteCount: 2_000)
        defer { try? FileManager.default.removeItem(at: root) }
        let collection = Collection(rootURL: root)
        await collection.scanOffMain()

        let cpu = await mainThreadCPU {
            _ = await collection.createNote(title: "Budget Probe")
        }
        print("BUDGET createNote(2000): main-thread CPU \(cpu)s")
        #expect(cpu < Self.budget, "creating one note burned \(cpu)s of main-thread CPU")
    }

    /// Naming a note is a rename, and a new note opens with its title focused —
    /// so this is the path the user is on while typing.
    @Test func renamingANoteNeverBlocksTheMainActor() async throws {
        let root = try makeVault(noteCount: 2_000)
        defer { try? FileManager.default.removeItem(at: root) }
        let collection = Collection(rootURL: root)
        await collection.scanOffMain()
        let target = try #require(collection.note(titled: "Note 7"))

        let cpu = await mainThreadCPU {
            _ = await collection.renameNote(target, to: "Renamed While Typing")
        }
        print("BUDGET renameNote(2000): main-thread CPU \(cpu)s")
        #expect(cpu < Self.budget, "renaming one note burned \(cpu)s of main-thread CPU")
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
