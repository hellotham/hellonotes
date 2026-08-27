//
//  ConcurrentTreeWalkTests.swift
//  HelloNotesTests
//
//  Created by Chris Tham on 27/8/2026.
//

import Testing
import Foundation
@testable import HelloNotes

/// Overlapping the listings without changing what the walk means.
///
/// A cloud walk is latency-bound: `store.list` is a network round trip the app
/// spends idle, so N directories cost N latencies laid end to end. Fetching them
/// in a window is the fix, and the risk is entirely in what it might quietly
/// break — the order batches arrive in, the promise that `onBatch` is never
/// re-entered, and the checkpoint's meaning. Each of those is pinned here.
struct ConcurrentTreeWalkTests {

    // MARK: Fixtures

    /// Counts how many listings were genuinely in flight at once.
    private final class ListingProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 0
        private(set) var peak = 0
        private(set) var total = 0

        func begin() {
            lock.lock(); defer { lock.unlock() }
            current += 1; total += 1
            peak = max(peak, current)
        }
        func end() { lock.lock(); current -= 1; lock.unlock() }
    }

    /// A tree that exists only as arithmetic, so a listing's cost is exactly the
    /// delay asked for — which is what a network listing is.
    private struct SyntheticTree: TreeSource {
        var breadth = 4
        var depth = 2
        var notesPerDirectory = 3
        var concurrency = 1
        var delay: Duration = .zero
        let probe: ListingProbe

        var listingConcurrency: Int { concurrency }
        func unavailability() -> CollectionState.UnavailableReason? { nil }

        func children(of directory: String) async throws -> DirectoryListing {
            probe.begin()
            defer { probe.end() }
            if delay > .zero { try? await Task.sleep(for: delay) }

            let level = directory.isEmpty ? 0 : directory.split(separator: "/").count
            let base = URL(fileURLWithPath: "/tree").appending(path: directory)
            var listing = DirectoryListing()
            for n in 0..<notesPerDirectory {
                listing.children.append(TreeChild(url: base.appending(path: "Note\(n).md"),
                                                  isDirectory: false, isMarkdown: true))
            }
            if level < depth {
                for b in 0..<breadth {
                    listing.children.append(TreeChild(url: base.appending(path: "dir\(b)"),
                                                      isDirectory: true))
                }
            }
            return listing
        }
    }

    /// Records batch order and catches any re-entrant `onBatch`.
    private final class BatchLog {
        var directories: [String] = []
        var files: [String] = []
        var inside = false
        var overlapped = false

        func record(_ batch: WalkBatch) {
            if inside { overlapped = true }
            inside = true
            directories.append(batch.directory)
            files += batch.children.filter { !$0.isDirectory }.map(\.url.path)
            inside = false
        }
    }

    private static func walk(_ source: SyntheticTree,
                             resuming checkpoint: WalkCheckpoint? = nil)
        async -> (WalkResult, BatchLog) {
        let log = BatchLog()
        let result = await ResumableTreeWalk.run(source: source, resuming: checkpoint) { batch in
            log.record(batch)
        }
        return (result, log)
    }

    // MARK: Equivalence

    /// The only thing that must not change: the answer.
    @Test func aWindowedWalkSeesExactlyWhatASerialWalkSees() async {
        let (serial, serialLog) = await Self.walk(
            SyntheticTree(concurrency: 1, probe: ListingProbe()))
        let (windowed, windowedLog) = await Self.walk(
            SyntheticTree(concurrency: 6, probe: ListingProbe()))

        #expect(serial.isComplete)
        #expect(windowed.isComplete)
        #expect(windowedLog.directories == serialLog.directories)
        #expect(windowedLog.files == serialLog.files)
        #expect(windowed.progress.directoriesVisited == serial.progress.directoriesVisited)
        #expect(windowed.progress.itemsSeen == serial.progress.itemsSeen)
    }

    /// Breadth-first is a promise about the *order results arrive in*, and
    /// overlapping the fetches is precisely the change that could break it.
    @Test func batchesStillArriveBreadthFirst() async {
        let (_, log) = await Self.walk(
            SyntheticTree(breadth: 3, depth: 2, concurrency: 6, probe: ListingProbe()))
        let depths = log.directories.map { $0.isEmpty ? 0 : $0.split(separator: "/").count }
        #expect(depths == depths.sorted(), "a deeper directory was applied before a shallower one")
    }

    /// `onBatch` is not `@Sendable` and it mutates the caller's accumulator.
    /// Only the fetching may overlap.
    @Test func onBatchIsNeverReentered() async {
        let (_, log) = await Self.walk(
            SyntheticTree(breadth: 5, depth: 2, concurrency: 8,
                          delay: .milliseconds(1), probe: ListingProbe()))
        #expect(!log.overlapped)
    }

    // MARK: The point of the change

    @Test func listingsGenuinelyOverlap() async {
        let probe = ListingProbe()
        _ = await Self.walk(SyntheticTree(breadth: 6, depth: 2, concurrency: 6,
                                          delay: .milliseconds(5), probe: probe))
        #expect(probe.peak > 1, "listings never overlapped — the window is not working")
        #expect(probe.peak <= 6, "window exceeded its own bound: \(probe.peak)")
    }

    /// A source that has not thought about concurrency is untouched — which is
    /// what keeps the local scan behaving exactly as it always has.
    @Test func theDefaultIsSerial() async {
        let probe = ListingProbe()
        _ = await Self.walk(SyntheticTree(breadth: 4, depth: 2,
                                          delay: .milliseconds(2), probe: probe))
        #expect(probe.peak == 1)
    }

    /// The claim that motivated the work, measured rather than asserted. A tree
    /// of 21 directories at 20ms a listing is ~420ms serial; six at a time
    /// should be a large fraction faster. The bound is loose on purpose — this
    /// is a test of the shape, not a benchmark.
    @Test func overlappingIsSubstantiallyFasterWhenListingsAreSlow() async {
        func elapsed(_ concurrency: Int) async -> Duration {
            let clock = ContinuousClock()
            return await clock.measure {
                _ = await Self.walk(SyntheticTree(breadth: 4, depth: 2,
                                                  concurrency: concurrency,
                                                  delay: .milliseconds(20),
                                                  probe: ListingProbe()))
            }
        }
        let serial = await elapsed(1)
        let windowed = await elapsed(6)
        #expect(windowed < serial / 2,
                "windowed \(windowed) vs serial \(serial) — expected well under half")
    }

    // MARK: Resumption

    /// The invariant that makes the window safe: `head` still means *next to
    /// apply*, so a listing that is in flight is still inside
    /// `frontier[head...]` and a checkpoint taken mid-window loses nothing.
    @Test func cancellingMidWindowLosesNoDirectory() async {
        let probe = ListingProbe()
        let source = SyntheticTree(breadth: 4, depth: 2, concurrency: 6,
                                   delay: .milliseconds(3), probe: probe)

        let log = BatchLog()
        let task = Task {
            await ResumableTreeWalk.run(source: source) { batch in
                log.record(batch)
                // Stop well inside the tree, with listings still in flight.
                if log.directories.count >= 3 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let interrupted = await task.value

        #expect(!interrupted.isComplete)
        let checkpoint = try? #require(interrupted.checkpoint)
        guard let checkpoint else { return }

        let (resumed, resumedLog) = await Self.walk(source, resuming: checkpoint)
        #expect(resumed.isComplete)

        // Everything a single uninterrupted walk would have seen, seen across
        // the two halves — that is the whole promise of a checkpoint.
        let (_, wholeLog) = await Self.walk(
            SyntheticTree(breadth: 4, depth: 2, concurrency: 6, probe: ListingProbe()))
        let across = Set(log.directories).union(resumedLog.directories)
        #expect(across == Set(wholeLog.directories),
                "missing: \(Set(wholeLog.directories).subtracting(across))")
    }
}
