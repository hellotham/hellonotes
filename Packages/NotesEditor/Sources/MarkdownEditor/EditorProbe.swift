//
//  EditorProbe.swift
//  MarkdownEditor
//
//  A plain file the editor and its host can both append a line to, for the
//  questions a screenshot cannot answer: whether a view was built, what size it
//  was offered, what width the shell said the pane was.
//
//  A file rather than `os_log` — readable from a terminal with `cat`, with none
//  of the unified log's level/predicate fragility, and with no need to look at
//  the screen. Debug builds only and off unless asked for, so an ordinary run
//  neither writes the file nor pays for the formatting. Same shape as the
//  editor's `hn-geom.log` probe.
//
//      HN_PREVIEW_LOG=1 scripts/relaunch-debug.sh
//      cat ~/Library/Containers/com.hellotham.HelloNotes/Data/Library/Caches/hn-preview.log
//

import Foundation

public enum EditorProbe {

    public static let isEnabled: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["HN_PREVIEW_LOG"] != nil
        #else
        return false
        #endif
    }()

    public static func log(_ message: @autoclosure () -> String) {
        guard isEnabled, let url = logURL else { return }
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(message())\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    static let logURL: URL? = {
        (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true))?
            .appendingPathComponent("hn-preview.log")
    }()
}
