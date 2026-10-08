//
//  ScratchDefaults.swift
//  HelloNotesTests
//
//  A test's own defaults suite, kept out of the person's preferences and gone
//  when the test ends (implemented.md §51.31).
//
//  The hosted tests run inside the app's sandbox, so a suite made the usual
//  way — `UserDefaults(suiteName: "name")` — is `Library/Preferences/name.plist`
//  in the person's own container, beside com.hellotham.HelloNotes.plist. Five
//  kinds of test made one per run under a new UUID and at most cleared its
//  domain, which empties the file and keeps it: by 29 September 2026 the Mac's
//  container held 741 of them, and the iPad simulator's 47.
//
//  Deleting the file does not settle it. cfprefsd writes a domain when it
//  chooses — at once, or seconds later under load, and was seen writing
//  cleared domains *minutes* after their files had been deleted — and a file
//  deleted before that write is written again by it. Measured in the test host
//  on both platforms, every way round: clearing then deleting, waiting then
//  deleting, synchronising first or after.
//
//  So a scratch suite is named by a path: `UserDefaults(suiteName:)` given an
//  absolute path keeps the domain's plist at that path. Each test's suites
//  live in a folder of its own in the temporary directory, and the folder is
//  deleted when the test ends — a late write finds no folder to land in, and
//  cfprefsd does not make one (watched for 12s on both platforms). Nothing
//  reaches Library/Preferences at all.
//
//  The folder is named for the test, not for the run, so a test that dies
//  before its cleanup leaves one folder, which its next run clears — rather
//  than every crashed run leaving another under a new UUID.
//

import Foundation
import Synchronization
import Testing

/// `@Test(.scratchDefaults)` on a test, then `ScratchDefaults.suite()` in it —
/// or in a helper it calls; the suite is found by the task, not passed down.
struct ScratchDefaults: TestTrait, TestScoping {

    /// A suite of the running test's own, empty the first time it is asked
    /// for. `label` tells two apart in one test; asked again, the same label is
    /// the same suite.
    static func suite(_ label: String = "defaults") -> UserDefaults {
        guard let scope = Scope.current else {
            Issue.record("ScratchDefaults.suite() is for a test marked .scratchDefaults")
            // Still a path, so nothing reaches Library/Preferences.
            return Scope(tag: "hn-defaults.unscoped").suite(label)
        }
        return scope.suite(label)
    }

    /// The running test as a name: its suite's and its own, `()` dropped.
    static func tag(for test: Test) -> String {
        let name = test.id.nameComponents.joined(separator: ".").replacingOccurrences(of: "()", with: "")
        let kept = name.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" ? Character(scalar) : "_"
        }
        return "hn-defaults." + String(kept)
    }

    // `@concurrent`, the method and its closure, as the Testing module's own
    // requirement is: this target builds with approachable concurrency, which
    // makes a plain `async` function `nonisolated(nonsending)` — and a witness
    // that does not match, with nothing to say which part.
    @concurrent
    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @concurrent @Sendable () async throws -> Void) async throws {
        let tag = Self.claim(Self.tag(for: test))
        defer { Self.release(tag) }
        let scope = Scope(tag: tag)
        defer { scope.end() }
        try await Scope.$current.withValue(scope) { try await function() }
    }

    // MARK: - Claims

    /// Tags whose folders a running test holds. The cases of a parameterized
    /// test run at once under one test's name; the second takes `-2`.
    private static let claimed = Mutex<Set<String>>([])

    private static func claim(_ tag: String) -> String {
        claimed.withLock { claimed in
            var candidate = tag, next = 2
            while claimed.contains(candidate) {
                candidate = "\(tag)-\(next)"
                next += 1
            }
            claimed.insert(candidate)
            return candidate
        }
    }

    private static func release(_ tag: String) {
        _ = claimed.withLock { $0.remove(tag) }
    }

    // MARK: - A test's suites

    /// The suites one test has made, in a folder of the test's own.
    final class Scope: @unchecked Sendable {
        @TaskLocal static var current: Scope?

        let tag: String
        let folder: URL
        private let made = Mutex<[String: UserDefaults]>([:])

        init(tag: String) {
            self.tag = tag
            folder = FileManager.default.temporaryDirectory.appendingPathComponent(tag, isDirectory: true)
            // What a run that died left here goes first: the domains it wrote,
            // which cfprefsd may still hold, then the folder.
            Self.clearDomains(in: folder)
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        /// The suite's name — an absolute path, so its plist is kept there.
        func name(_ label: String) -> String {
            folder.appendingPathComponent(label).path
        }

        func suite(_ label: String) -> UserDefaults {
            made.withLock { made in
                if let defaults = made[label] { return defaults }
                let name = name(label)
                let defaults = UserDefaults(suiteName: name)!
                // cfprefsd keeps a domain for as long as it likes: one of this
                // name may still hold the values of the last run to use it,
                // whether or not its file survived.
                defaults.removePersistentDomain(forName: name)
                made[label] = defaults
                return defaults
            }
        }

        /// The test is over: its domains are emptied — so cfprefsd holds
        /// nothing of them — and its folder goes, file and all.
        func end() {
            for label in made.withLock({ Array($0.keys) }) {
                UserDefaults(suiteName: name(label))?.removePersistentDomain(forName: name(label))
            }
            try? FileManager.default.removeItem(at: folder)
            if FileManager.default.fileExists(atPath: folder.path) {
                Issue.record("\(tag)'s defaults are still in \(folder.path)")
            }
        }

        /// Empty every domain whose plist is in `folder`.
        private static func clearDomains(in folder: URL) {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for file in files where file.hasSuffix(".plist") {
                let name = folder.appendingPathComponent(String(file.dropLast(".plist".count))).path
                UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            }
        }
    }
}

extension Trait where Self == ScratchDefaults {
    /// Defaults suites of the test's own, kept out of the person's
    /// preferences: `ScratchDefaults.suite()`.
    static var scratchDefaults: Self { Self() }
}
