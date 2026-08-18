//
//  FileWatcher.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(macOS)
import Foundation
import CoreServices

/// What FSEvents actually reported.
///
/// The stream carries more than "these paths changed", and the rest of it is
/// exactly the news a collection cannot afford to miss: that its root was moved
/// out from under it, that its volume went away, or that the kernel dropped
/// events and the index is now a guess. Discarding `eventFlags` meant every one
/// of those arrived as silence.
nonisolated enum FileWatcherEvent: Equatable, Sendable {
    /// Ordinary changes to items inside the watched tree.
    case itemsChanged([String])
    /// The watched root itself was renamed, moved, or deleted. Requires
    /// `kFSEventStreamCreateFlagWatchRoot`, without which it is never sent.
    case rootChanged
    /// The volume holding the watched root was unmounted.
    case unmounted
    /// FSEvents dropped events — its queue overflowed, or the kernel's did.
    /// It is telling us the change list is incomplete; the only correct
    /// response is a full rescan, because there is no way to learn what was
    /// missed. A big `git checkout` or a cloud sync burst can trigger this.
    case eventsDropped
}

/// Watches a directory subtree with FSEvents and invokes `onEvent` when the
/// collection changes on disk (external edits, a `git pull`, Finder operations).
/// Events are coalesced by FSEvents' own latency window. The changed paths let
/// the caller ignore its own writes.
///
/// `@unchecked Sendable`: the FSEvents callback fires on a background dispatch
/// queue; `onEvent` is `@Sendable` and expected to hop to the main actor
/// itself. Start/stop are only called from the main actor.
final class FileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let onEvent: @Sendable (FileWatcherEvent) -> Void
    /// A dedicated serial queue for the stream's callbacks, so `stop()` can
    /// drain any in-flight callback (see `stop()`).
    private let queue = DispatchQueue(label: "com.hellonotes.filewatcher", qos: .utility)

    init(onEvent: @escaping @Sendable (FileWatcherEvent) -> Void) {
        self.onEvent = onEvent
    }

    /// What one event's flags mean.
    ///
    /// Extracted from the C callback so the flag handling — the part that was
    /// missing entirely, and that decides whether a moved folder or a dropped
    /// batch is noticed at all — can be tested without an FSEvents stream.
    ///
    /// Order is deliberate. The first three describe the *watch* rather than any
    /// one file and each invalidates the whole batch, so they outrank the path
    /// list they arrive with. `eventsDropped` comes first because a batch that
    /// admits it is incomplete cannot be trusted to have told us the rest.
    enum FlagVerdict: Equatable { case eventsDropped, rootChanged, unmounted, item }

    static func verdict(for flags: FSEventStreamEventFlags) -> FlagVerdict {
        func carries(_ flag: Int) -> Bool { flags & FSEventStreamEventFlags(flag) != 0 }
        if carries(kFSEventStreamEventFlagMustScanSubDirs)
            || carries(kFSEventStreamEventFlagUserDropped)
            || carries(kFSEventStreamEventFlagKernelDropped) { return .eventsDropped }
        if carries(kFSEventStreamEventFlagRootChanged) { return .rootChanged }
        if carries(kFSEventStreamEventFlagUnmount) { return .unmounted }
        return .item
    }

    /// Begin watching `url` (and its descendants). Replaces any current watch.
    func start(url: URL) {
        stop()

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String]) ?? []

            var changed: [String] = []
            for index in 0..<numEvents {
                switch FileWatcher.verdict(for: eventFlags[index]) {
                case .item:
                    if index < paths.count { changed.append(paths[index]) }
                case .eventsDropped:
                    watcher.onEvent(.eventsDropped); return
                case .rootChanged:
                    watcher.onEvent(.rootChanged); return
                case .unmounted:
                    watcher.onEvent(.unmounted); return
                }
            }
            if !changed.isEmpty { watcher.onEvent(.itemsChanged(changed)) }
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
        // `WatchRoot` is what makes `RootChanged` arrive at all — without it the
        // stream stays silently alive after the folder is moved or deleted, and
        // the collection goes on displaying a tree that no longer exists.
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot
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
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// Stop watching and release the stream.
    ///
    /// The context passes `self` unretained, so a callback that FSEvents had
    /// already dispatched before `invalidate` would otherwise be free to run
    /// `onChange` (via `takeUnretainedValue()`) after `self` is deallocated —
    /// a use-after-free. Because callbacks run on our own serial `queue`, a
    /// synchronous barrier after `invalidate` waits for any in-flight callback
    /// to finish before we return (and, when called from `deinit`, before the
    /// object's memory is reclaimed).
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        queue.sync { }
    }

    deinit { stop() }
}
#endif
