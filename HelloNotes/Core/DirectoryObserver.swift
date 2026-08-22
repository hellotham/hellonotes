//
//  DirectoryObserver.swift
//  HelloNotes
//
//  Noticing that a collection changed underneath us — one event, two mechanisms.
//
//  These were two files: `FileWatcher.swift`, gated to macOS, and
//  `DirectoryPresenter.swift`, ungated but used only on iOS. `Collection`
//  already had one `startObserving` / `stopObserving` pair over them, which was
//  the right shape — and underneath it two properties, two callbacks and two
//  handlers, which had drifted. The macOS handler refreshes Git status when
//  `.git` churns, because an external pull moves the branch and the change
//  count and the status bar would otherwise assert the old ones forever. The
//  iOS handler did not.
//
//  So the *event* is shared and the mechanisms are not. FSEvents genuinely
//  reports more than a file presenter can — which paths changed, a moved root,
//  an unmounted volume, a dropped batch — and that is a capability difference
//  rather than a divergence: the presenter never emits those cases, and the one
//  handler treats each as the rescan it always meant.
//

import Foundation
#if os(macOS)
import CoreServices
#endif

/// What an observer noticed.
///
/// A superset, deliberately. `FileWatcher` fills in every case and a presenter
/// only the first two — levelling both down to the coarser vocabulary would
/// throw away information the Mac can act on, and a dropped FSEvents batch
/// means something specific.
nonisolated enum DirectoryEvent: Equatable, Sendable {
    /// Ordinary changes to items inside the watched tree, by path.
    case itemsChanged([String])
    /// Something inside the tree changed and the mechanism cannot say what —
    /// a presenter's `presentedItemDidChange`, where no path list exists.
    case unspecifiedChange
    /// The watched root itself was renamed, moved, or deleted.
    case rootChanged
    /// The volume holding the watched root was unmounted.
    case unmounted
    /// The change list is incomplete. The only correct response is a full
    /// rescan, because there is no way to learn what was missed.
    case eventsDropped
}

#if os(macOS)
/// What FSEvents actually reported.
///
/// The stream carries more than "these paths changed", and the rest of it is
/// exactly the news a collection cannot afford to miss: that its root was moved
/// out from under it, that its volume went away, or that the kernel dropped
/// events and the index is now a guess. Discarding `eventFlags` meant every one
/// of those arrived as silence.

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
    private let onEvent: @Sendable (DirectoryEvent) -> Void
    /// A dedicated serial queue for the stream's callbacks, so `stop()` can
    /// drain any in-flight callback (see `stop()`).
    private let queue = DispatchQueue(label: "com.hellonotes.filewatcher", qos: .utility)

    init(onEvent: @escaping @Sendable (DirectoryEvent) -> Void) {
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

#else
/// Watches a directory through the file-coordination system.
///
/// Used on iOS; on macOS `FileWatcher` remains the better instrument, because
/// FSEvents reports the things a presenter cannot — a moved root, an unmounted
/// volume, a dropped batch.
final class DirectoryPresenter: NSObject, NSFilePresenter, @unchecked Sendable {

    private var root: URL
    /// What happened, in the same vocabulary `FileWatcher` speaks.
    ///
    /// This used to be `(URL?) -> Void` — a subitem or nothing — which is why
    /// `.rootChanged` was unreachable on iOS: the presenter had no way to say
    /// it, and the presenter callbacks that carry the news
    /// (`presentedItemDidMove(to:)`, `accommodatePresentedItemDeletion`) were
    /// not implemented either. Renaming or deleting an open collection's folder
    /// in the Files app left the sidebar rendering a tree that no longer
    /// existed, with the collection still `.ready`.
    private let onEvent: @Sendable (DirectoryEvent) -> Void
    private var isRegistered = false

    /// A private queue is required: the coordination system delivers callbacks
    /// here, and using `.main` risks re-entrancy against a coordinated read that
    /// is already blocking it.
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.hellonotes.directory-presenter"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    var presentedItemURL: URL? { root }

    init(root: URL, onEvent: @escaping @Sendable (DirectoryEvent) -> Void) {
        self.root = root
        self.onEvent = onEvent
        super.init()
    }

    func start() {
        guard !isRegistered else { return }
        isRegistered = true
        NSFileCoordinator.addFilePresenter(self)
    }

    func stop() {
        guard isRegistered else { return }
        isRegistered = false
        NSFileCoordinator.removeFilePresenter(self)
    }

    deinit { stop() }

    // MARK: NSFilePresenter

    /// Something inside the folder changed — a note edited on another device and
    /// streamed down, a file added in the Files app.
    func presentedSubitemDidChange(at url: URL) { onEvent(.itemsChanged([url.path])) }

    /// The folder itself changed (contents replaced wholesale). No single path
    /// describes it, so the caller has to assume the worst.
    func presentedItemDidChange() { onEvent(.unspecifiedChange) }

    func presentedSubitemDidAppear(at url: URL) { onEvent(.itemsChanged([url.path])) }

    func accommodatePresentedSubitemDeletion(at url: URL) async throws {
        onEvent(.itemsChanged([url.path]))
    }

    /// The watched folder was moved or renamed.
    ///
    /// `FileWatcher` gets this from `kFSEventStreamCreateFlagWatchRoot`, whose
    /// own comment says that without it "the stream stays silently alive after
    /// the folder is moved or deleted, and the collection goes on displaying a
    /// tree that no longer exists." This is the presenter's version of the same
    /// news, and it was simply not implemented.
    func presentedItemDidMove(to newURL: URL) {
        root = newURL
        onEvent(.rootChanged)
    }

    /// The watched folder is about to be deleted.
    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        onEvent(.rootChanged)
        completionHandler(nil)
    }
}
#endif
