//
//  RepoFile.swift
//  HelloNotesTests
//
//  Where a test reads the repository's own files — the app's sources, the
//  sample vault, the bundled notes, the project file (implemented.md §51.68).
//
//  Each test found them through its own `#filePath`, so it read the checkout,
//  and the checkout here is on an external disk, which macOS guards: an app
//  reads a removable volume once someone has said it may, and the answer is
//  kept for the build that was allowed. The CI-style run is unsigned and the
//  plain one signed — two different apps, to that guard — so the first run
//  after the other kind asked again, and every test that read a file waited
//  for the answer. On 26 October 2026 sixteen waited at once, which was every
//  thread of the concurrency pool, and the rest of the suite waited behind
//  them: fifty-eight minutes, until someone came back to the Mac and clicked.
//
//  `run-tests.sh` copies what the tests read to the start-up disk and says
//  where (`TEST_RUNNER_HN_REPO`), so nothing it runs reads the external disk.
//  Run any other way — ⌘U in Xcode, CI's own `xcodebuild` — `HN_REPO` is
//  unset and the checkout is read, as before. A test that reads a part of the
//  repository the copy leaves out finds it missing under `run-tests.sh`: add
//  the part to the script's list.
//

import Foundation

nonisolated enum RepoFile {
    /// The repository's root: `run-tests.sh`'s copy, or the checkout.
    static let root: URL = {
        if let copy = ProcessInfo.processInfo.environment["HN_REPO"], !copy.isEmpty {
            return URL(filePath: copy, directoryHint: .isDirectory)
        }
        return URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }()

    /// `path`, relative to the repository's root.
    static func url(_ path: String) -> URL { root.appending(path: path) }
}
