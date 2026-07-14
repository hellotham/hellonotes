//
//  FileWatcher.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(macOS)
import Foundation
import CoreServices

/// Watches a directory subtree with FSEvents and invokes `onChange` with the
/// changed paths when the collection changes on disk (external edits, a
/// `git pull`, Finder operations). Events are coalesced by FSEvents' own
/// latency window. The changed paths let the caller ignore its own writes.
///
/// `@unchecked Sendable`: the FSEvents callback fires on a background dispatch
/// queue; `onChange` is `@Sendable` and expected to hop to the main actor
/// itself. Start/stop are only called from the main actor.
final class FileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable ([String]) -> Void

    init(onChange: @escaping @Sendable ([String]) -> Void) {
        self.onChange = onChange
    }

    /// Begin watching `url` (and its descendants). Replaces any current watch.
    func start(url: URL) {
        stop()

        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let paths = (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String]) ?? []
            Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue().onChange(paths)
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        // `UseCFTypes` makes `eventPaths` a `CFArray` of `CFString` we can read
        // as `[String]`; `FileEvents` reports per-file (not per-directory) paths.
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, // latency (seconds) — coalesces bursts
            flags
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    /// Stop watching and release the stream.
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
#endif
