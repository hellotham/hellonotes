//
//  ScratchDefaultsTests.swift
//  HelloNotesTests
//
//  A test's scratch defaults leave nothing in the person's preferences
//  (implemented.md §51.31). The hosted tests run inside the app's sandbox, so a
//  defaults suite made the usual way is a plist in the person's own container,
//  in Library/Preferences beside com.hellotham.HelloNotes.plist — and five kinds
//  of test left one there on every run, hundreds by 29 September 2026.
//

import Foundation
import Testing

@Suite struct ScratchDefaultsTests {

    /// The container's Library/Preferences — the person's own, since the tests
    /// run inside the app.
    private static var preferences: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences", isDirectory: true)
    }

    /// The files in `directory` whose names carry `tag`.
    private static func files(carrying tag: String, in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.contains(tag) }.sorted()
    }

    /// Those in Library/Preferences, and when each was last written.
    private static func written(carrying tag: String) -> [String: Date] {
        var written: [String: Date] = [:]
        for file in files(carrying: tag, in: preferences) {
            let path = preferences.appendingPathComponent(file).path
            written[file] = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
        return written
    }

    /// What has appeared in Library/Preferences carrying `tag` since `before`,
    /// or been written again: a name is fixed for its test, so what a run
    /// leaves may be a file an earlier run left, rewritten.
    private static func left(since before: [String: Date], carrying tag: String) -> [String] {
        written(carrying: tag).filter { before[$0.key] != $0.value }.keys.sorted()
    }

    /// `body` run as `.scratchDefaults` runs a test — in the trait's own scope,
    /// for the running test — and the tag its suites carry.
    private func asAScratchTest(_ body: @Sendable () async throws -> Void) async throws -> String {
        let test = try #require(Test.current)
        try await ScratchDefaults().provideScope(for: test, testCase: Test.Case.current, performing: body)
        return ScratchDefaults.tag(for: test)
    }

    /// Whether `file` exists within `limit` — cfprefsd writes when it chooses.
    private static func appears(_ file: URL, within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !FileManager.default.fileExists(atPath: file.path) {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// A test that used a scratch suite leaves nothing in Library/Preferences.
    ///
    /// Looked for two ways, because cfprefsd writes a domain when it chooses —
    /// a plain-named suite's plist was written ten seconds after its test had
    /// ended, when this looked only at Library/Preferences, and passed. So the
    /// suite's plist is also found where it is kept, in the test's own folder in
    /// the temporary directory, which only a suite named by a path can write to;
    /// and the folder is gone when the test is, and stays gone past cfprefsd's
    /// next flush.
    @Test func aScratchSuiteLeavesNothingInPreferences() async throws {
        let tag = ScratchDefaults.tag(for: try #require(Test.current))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(tag, isDirectory: true)
        let before = Self.written(carrying: tag)
        _ = try await asAScratchTest {
            let defaults = ScratchDefaults.suite("check")
            for value in 0..<5 { defaults.set(value, forKey: "k\(value)") }
            #expect(defaults.integer(forKey: "k4") == 4, "the suite does not keep what is written to it")
            #expect(await Self.appears(folder.appendingPathComponent("check.plist"), within: .seconds(15)),
                    "the suite's plist never reached its test's folder: its domain is kept somewhere else")
        }
        #expect(!FileManager.default.fileExists(atPath: folder.path), "the test's folder outlived it")
        #expect(Self.left(since: before, carrying: tag).isEmpty,
                "left in Library/Preferences: \(Self.left(since: before, carrying: tag))")
        try await Task.sleep(for: .seconds(3))
        #expect(!FileManager.default.fileExists(atPath: folder.path), "the test's folder came back")
        #expect(Self.left(since: before, carrying: tag).isEmpty,
                "written into Library/Preferences after the test: \(Self.left(since: before, carrying: tag))")
    }

    /// The control: clearing a suite's domain — all the tests ever did —
    /// empties its plist and leaves it, and the check sees it. Made in a folder
    /// of the control's own, not in Library/Preferences: a file there is the
    /// thing this suite exists to stop leaving, and none made there can be
    /// deleted for good.
    @Test func clearingADomainLeavesItsFileAndTheCheckSeesIt() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("hn-defaults.control", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = folder.appendingPathComponent("control").path
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.set(1, forKey: "k")
        defaults.removePersistentDomain(forName: name)

        // cfprefsd writes when it chooses.
        let deadline = ContinuousClock.now + .seconds(15)
        while Self.files(carrying: "control", in: folder).isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(Self.files(carrying: "control", in: folder) == ["control.plist"],
                "clearing the domain took its file with it, so the check has nothing to catch")
    }

    /// Named for the test, not the run: a test that dies before it is cleaned
    /// up leaves one suite of its own, and its next run starts without what
    /// that one held — rather than every run leaving another under a new UUID.
    @Test func aRunThatDiedLeavesOneSuiteAndTheNextStartsClean() async throws {
        let tag = ScratchDefaults.tag(for: try #require(Test.current))
        let before = Self.written(carrying: tag)
        // A run that died: written to, and never ended.
        let died = ScratchDefaults.Scope(tag: tag)
        died.suite("state").set("stale", forKey: "k")

        // Its next run: the same suite, with nothing of the last run in it.
        _ = try await asAScratchTest {
            #expect(ScratchDefaults.Scope.current?.name("state") == died.name("state"),
                    "the next run's suite is not the one the last run left")
            #expect(ScratchDefaults.suite("state").string(forKey: "k") == nil,
                    "the run began with what the run before it left")
        }
        #expect(Self.left(since: before, carrying: tag).isEmpty,
                "left in Library/Preferences: \(Self.left(since: before, carrying: tag))")
    }

    /// No test names a suite the usual way — by a name rather than a path —
    /// which keeps its plist in the person's Library/Preferences. Two opt-in
    /// evaluation suites still did after §51.31, and every Mac they ran on
    /// kept one (`HelloNotesEvaluations.plist`).
    @Test func noTestNamesASuiteThatLivesInPreferences() throws {
        let folder = URL(filePath: #filePath).deletingLastPathComponent()
        let sources = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".swift") && $0 != "ScratchDefaults.swift" && $0 != "ScratchDefaultsTests.swift" }
        #expect(sources.count > 50, "the scan read \(sources.count) test files")
        let naming = try sources.filter {
            Self.namesASuite(try String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8))
        }
        #expect(naming.isEmpty, "a suite named by a name, not a path, in: \(naming)")
        // The control: the scan sees the shape the evaluations used.
        #expect(Self.namesASuite("let defaults = UserDefaults(suiteName: " + "\"HelloNotesEvaluations\")!"))
    }

    private static func namesASuite(_ source: String) -> Bool {
        source.contains("UserDefaults(suiteName: \"")
    }
}
