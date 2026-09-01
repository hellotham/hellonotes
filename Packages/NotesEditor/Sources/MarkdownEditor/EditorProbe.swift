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

    // MARK: - The typing path

    /// Separate switch, separate file: the edit probe writes **one line per
    /// keystroke**, so mixing it into `hn-preview.log` would bury the thing
    /// `HN_PREVIEW_LOG` exists to show. Turn it on with `HN_EDIT_LOG=1`.
    ///
    ///     SIMCTL_CHILD_HN_EDIT_LOG=1 xcrun simctl launch <dev> com.hellotham.HelloNotes
    ///     cat <container>/Library/Caches/hn-edit.log
    ///
    /// It exists because "typing feels slow" and "the editor is doing work per
    /// keystroke" are different claims, and only the second one can be fixed.
    /// The document already times its own parse and restyle
    /// (`EditorDocument.lastEditMetrics`); until this, nothing ever read those
    /// numbers outside a unit test, so the on-device cost was inferred from
    /// sampled stacks instead of measured.
    public static let isEditLogEnabled: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["HN_EDIT_LOG"] != nil
        #else
        return false
        #endif
    }()

    /// Serial queue for edit-log writes.
    ///
    /// **The first version of this probe wrote the file on the calling thread**,
    /// which is the main actor, on every keystroke: open a handle, seek to end,
    /// write, close. It cost **225ms** in a sampled stack — an instrument that
    /// was, by a wide margin, the most expensive thing on the typing path it
    /// existed to measure. Formatting stays on the caller (it needs the values);
    /// the I/O does not.
    private static let editQueue = DispatchQueue(label: "com.hellotham.HelloNotes.editprobe",
                                                 qos: .utility)

    public static func logEdit(_ message: @autoclosure () -> String) {
        guard isEditLogEnabled, let url = editLogURL else { return }
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(message())\n"
        guard let data = line.data(using: .utf8) else { return }
        editQueue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    static let editLogURL: URL? = {
        (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true))?
            .appendingPathComponent("hn-edit.log")
    }()

    static let logURL: URL? = {
        (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true))?
            .appendingPathComponent("hn-preview.log")
    }()
}
