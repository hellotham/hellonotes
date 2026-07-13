//
//  BuildInfo.swift
//  HelloNotes
//
//  Created by Chris Tham on 13/7/2026.
//

import Foundation

/// Build metadata for the splash / about screen. The marketing version comes
/// from the target's `MARKETING_VERSION`; the git commit and build date are
/// stamped into the built product's Info.plist by the "Stamp Build Info"
/// build phase (so a source checkout always describes exactly what it built).
enum BuildInfo {
    private static func info(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    static var version: String { info("CFBundleShortVersionString") ?? "1.0" }
    static var commit: String { info("HNGitCommit") ?? "dev" }
    static var buildDate: String { info("HNBuildDate") ?? "" }

    /// "Version 1.0 (91c75ba)"
    static var versionLine: String { "Version \(version) (\(commit))" }

    /// The year the app was built, for the copyright line.
    static var copyrightYear: String {
        if let year = buildDate.split(separator: " ").last, year.count == 4 {
            return String(year)
        }
        return Calendar.current.component(.year, from: .now).formatted(.number.grouping(.never))
    }
}
