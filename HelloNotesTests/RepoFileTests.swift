//
//  RepoFileTests.swift
//  HelloNotesTests
//

import Foundation
import Testing

struct RepoFileTests {
    /// A test reads the repository through `RepoFile`, so `run-tests.sh`'s
    /// copy is what it reads. Found through the test's own source path it is
    /// the checkout, and on an external disk that is a question macOS may hold
    /// the whole suite for until someone answers it (implemented.md §51.68).
    @Test func everyTestReadsTheRepositoryThroughRepoFile() throws {
        let folder = RepoFile.url("HelloNotesTests")
        let sources = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".swift") && $0 != "RepoFile.swift" }
        #expect(sources.count > 50, "the scan read \(sources.count) test files")
        let literal = "#file" + "Path"     // in two parts, so this file does not find itself
        let readers = try sources.filter {
            try String(contentsOf: folder.appending(path: $0), encoding: .utf8).contains(literal)
        }
        #expect(readers.isEmpty, "read the repository through RepoFile, not \(literal): \(readers)")
    }
}
