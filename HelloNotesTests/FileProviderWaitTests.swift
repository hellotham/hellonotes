//
//  FileProviderWaitTests.swift
//  HelloNotesTests
//
//  `FileIO.waitForDownload` against stand-in providers: one that answers
//  slowly, one that never answers, and many waits on silent ones at once —
//  each a finding of the review of the first version, measured there and held
//  here (docs/implemented.md §51.52).
//

import Foundation
import Testing
@testable import HelloNotes

@Suite
struct FileProviderWaitTests {

    private static func file(_ name: String = UUID().uuidString) -> URL {
        URL(fileURLWithPath: "/tmp/file-provider-wait-tests/\(name).md")
    }

    /// **The wait reads the file as it is now.** `URL.resourceValues` answers
    /// from a cache on the URL that only the main run loop clears, and the
    /// wait asks on a lane: the same URL reported its first answer back at
    /// every look for the whole minute — a note that had downloaded in a
    /// second was "not downloaded" at the deadline, and Try Again, with the
    /// same URL, the same. The premise is held too, so the day Foundation
    /// changes it the reason for the fresh read is still written down.
    @Test func theWaitReadsTheFileAsItIsNow() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "fresh-values-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "note.md")
        try Data("one".utf8).write(to: file)
        let lane = DispatchQueue(label: "fresh-values-lane")
        let (cached, fresh): ([Int], [Int]) = await withCheckedContinuation { continuation in
            lane.async {
                var cached: [Int] = [], fresh: [Int] = []
                func size(_ values: URLResourceValues?) -> Int { values?.fileSize ?? -1 }
                cached.append(size(try? file.resourceValues(forKeys: [.fileSizeKey])))
                fresh.append(size(try? FileIO.currentResourceValues(at: file, keys: [.fileSizeKey])))
                try? Data(String(repeating: "x", count: 50).utf8).write(to: file)
                lane.asyncAfter(deadline: .now() + .milliseconds(200)) {
                    cached.append(size(try? file.resourceValues(forKeys: [.fileSizeKey])))
                    fresh.append(size(try? FileIO.currentResourceValues(at: file, keys: [.fileSizeKey])))
                    continuation.resume(returning: (cached, fresh))
                }
            }
        }
        #expect(fresh == [3, 50], "the fresh read did not see the file grow: \(fresh)")
        #expect(cached == [3, 3], "the premise: a reused URL on a lane answers from its cache — \(cached)")
    }

    /// **A provider that answers slowly is "not yet", not "no answer".** The
    /// first version anchored its timer before the first question and its
    /// own deadline after two, on two clocks, and called a provider that had
    /// answered every question silent — the very case the message is there to
    /// tell apart (review finding 3).
    @Test func aSlowButAnsweringProviderIsNotYet() async {
        let provider = StandInProvider(firstAnswerTakes: 1.5)
        let wait = await FileIO.waitForDownload(at: Self.file(), timeout: .seconds(2), using: provider.calls)
        #expect(wait == .notYet, "a provider that answered every question was called silent: \(wait)")
        #expect(provider.questionCount > 1)
        #expect(provider.askCount == 1)
        #expect(provider.mainThreadCalls == 0)
    }

    /// One that never answers is "no answer", by its deadline (and a second).
    @Test func aSilentProviderIsNoAnswerByTheDeadline() async {
        let provider = StandInProvider(silent: true)
        defer { provider.release() }
        let started = ContinuousClock.now
        let wait = await FileIO.waitForDownload(at: Self.file(), timeout: .milliseconds(500), using: provider.calls)
        #expect(wait == .noAnswer)
        // Generous: the point is that it comes back at all.
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    /// **A wait cancelled before it begins asks nothing** — no question, and
    /// no download nobody is waiting for (review finding 7).
    @Test func aWaitCancelledBeforeItBeginsAsksNothing() async throws {
        let provider = StandInProvider()
        let waiting = Task {
            try? await Task.sleep(for: .seconds(1))   // cancelled during this
            return await FileIO.waitForDownload(at: Self.file(), timeout: .seconds(5), using: provider.calls)
        }
        waiting.cancel()
        let wait = await waiting.value
        // Past where a question would have been put.
        try await Task.sleep(for: .milliseconds(300))
        #expect(wait == .notYet)
        #expect(provider.questionCount == 0 && provider.askCount == 0,
                "asked \(provider.questionCount) questions and \(provider.askCount) downloads")
    }

    /// **Many waits on silent providers are all answered by their deadline**,
    /// and the rest of the process goes on meanwhile. The first version put
    /// every question on a concurrent queue and its timers on GCD's shared
    /// one: a hundred waits on a silent provider were answered by nobody,
    /// and unrelated work stopped with them (review findings 1 and 6). Now a
    /// file's questions share a lane, the lanes are sixteen, and the timers
    /// have a queue of their own.
    @Test func manySilentWaitsAreAllAnsweredAndNothingElseStops() async {
        let provider = StandInProvider(silent: true)
        defer { provider.release() }
        let started = ContinuousClock.now
        // A hundred for one file — Try Again, over and over — and a hundred
        // for as many files, which is every lane held.
        let answers = await withTaskGroup(of: FileIO.DownloadWait.self) { group in
            let one = Self.file()
            for _ in 0..<100 {
                group.addTask { await FileIO.waitForDownload(at: one, timeout: .milliseconds(500), using: provider.calls) }
            }
            for _ in 0..<100 {
                group.addTask {
                    await FileIO.waitForDownload(at: Self.file(), timeout: .milliseconds(500), using: provider.calls)
                }
            }
            // And something unrelated, on GCD's shared queue, meanwhile.
            group.addTask {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async { continuation.resume() }
                }
                return .arrived
            }
            var all: [FileIO.DownloadWait] = []
            for await answer in group { all.append(answer) }
            return all
        }
        #expect(answers.count == 201)
        #expect(answers.filter { $0 == .noAnswer }.count == 200, "not every wait was answered no-answer")
        #expect(ContinuousClock.now - started < .seconds(10), "the waits were answered late")
        // A file's questions wait behind its first: at most one question a
        // lane, sixteen in all, however many waits.
        #expect(provider.questionCount <= 16, "\(provider.questionCount) questions held threads at once")
    }
}
