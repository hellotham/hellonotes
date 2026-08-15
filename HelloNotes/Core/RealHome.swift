//
//  RealHome.swift
//  HelloNotes
//
//  Created by Chris Tham on 15/8/2026.
//
//  The user's actual home directory, as opposed to the app's container.
//
//  Inside the sandbox both `NSHomeDirectory()` and
//  `FileManager.default.homeDirectoryForCurrentUser` return the *container*:
//
//      fileManager = /Users/me/Library/Containers/com.hellotham.HelloNotes/Data
//      nsHome      = /Users/me/Library/Containers/com.hellotham.HelloNotes/Data
//      getpwuid    = /Users/me
//
//  (Measured from inside the real sandboxed binary — the test host *is* the app,
//  so `SandboxHomeProbe` reports exactly what ships.)
//
//  That matters because the interesting folders live in the real home and not in
//  the container: `~/Library/CloudStorage/<Provider>` for the File-Provider
//  mounts, `~/Library/Mobile Documents/…` for iCloud. The sandbox forbids us
//  *reading* those paths — but an `NSOpenPanel` runs out of process, so it can
//  navigate to one perfectly well and the user's selection is what grants access.
//  A browse hint therefore only has to be *correct*, not readable.
//
//  Building such a hint from `homeDirectoryForCurrentUser` produces a container
//  path that has never existed, which is silently useless: the panel shrugs and
//  opens somewhere else, and the "we'll start you in the right place" nicety
//  quietly does nothing.
//

import Foundation

enum RealHome {

    /// The user's home directory, whether or not we are sandboxed.
    ///
    /// `getpwuid_r` reads the directory-services record rather than the
    /// sandbox-remapped value, so it is the one API that answers the question
    /// actually being asked.
    static let directory: URL = {
        var buffer = [CChar](repeating: 0, count: 4096)
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        if getpwuid_r(getuid(), &record, &buffer, buffer.count, &result) == 0,
           result != nil {
            let path = String(cString: record.pw_dir)
            if !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        // Falling back to the container is wrong, but it is at least a real
        // directory — better than a nil that every caller has to handle.
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }()

    /// Whether we are running inside a sandbox container (informational; the
    /// code above does not branch on it).
    ///
    /// `NSHomeDirectory()` rather than `homeDirectoryForCurrentUser`, which is
    /// unavailable on iOS — where the app is *always* containerised, so the two
    /// simply never agree.
    static var isSandboxed: Bool {
        NSHomeDirectory() != directory.path
    }

    static func path(_ components: String) -> URL {
        directory.appending(path: components, directoryHint: .isDirectory)
    }
}
