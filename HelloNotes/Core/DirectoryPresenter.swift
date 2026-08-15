//
//  DirectoryPresenter.swift
//  HelloNotes
//
//  Created by Chris Tham on 15/8/2026.
//
//  Change detection on iOS, where there is no FSEvents.
//
//  Until now `FileWatcher` was `#if os(macOS)` and nothing replaced it, so an
//  iPad showing a vault edited on a Mac displayed stale content until the app was
//  relaunched — the file was different on disk and the app had no way to know.
//
//  `NSFilePresenter` is the portable answer: register as the presenter of the
//  collection's root and the coordination machinery reports changes to its
//  subitems, including the ones a File Provider (iCloud, Dropbox, …) streams in
//  from another device. It is coarser than FSEvents — no flags, no per-file
//  event list — so it maps onto the same debounce as an ordinary change and
//  nothing more is claimed of it.
//

import Foundation

/// Watches a directory through the file-coordination system.
///
/// Used on iOS; on macOS `FileWatcher` remains the better instrument, because
/// FSEvents reports the things a presenter cannot — a moved root, an unmounted
/// volume, a dropped batch.
final class DirectoryPresenter: NSObject, NSFilePresenter, @unchecked Sendable {

    private let root: URL
    private let onChange: @Sendable () -> Void
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

    init(root: URL, onChange: @escaping @Sendable () -> Void) {
        self.root = root
        self.onChange = onChange
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
    func presentedSubitemDidChange(at url: URL) { onChange() }

    /// The folder itself changed (contents replaced wholesale).
    func presentedItemDidChange() { onChange() }

    func presentedSubitemDidAppear(at url: URL) { onChange() }

    func accommodatePresentedSubitemDeletion(at url: URL) async throws { onChange() }
}
