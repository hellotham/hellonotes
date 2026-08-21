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
//  from another device. It is coarser than FSEvents — no flags, no batch —
//  so it maps onto the same debounce as an ordinary change and nothing more is
//  claimed of it.
//
//  It does, however, know *which* subitem changed, and it used to throw that
//  away: `onChange` took no argument, so `Collection` could not ask its
//  `hasExternalChanges(in:)` filter whether the change was one of its own
//  autosaves — and `FileIO.write` coordinates with `filePresenter: nil`, which
//  excludes no presenter, so every 600ms autosave came straight back to us as
//  news. One URL is the difference between deferring our own writes and
//  discarding them.
//

import Foundation

/// Watches a directory through the file-coordination system.
///
/// Used on iOS; on macOS `FileWatcher` remains the better instrument, because
/// FSEvents reports the things a presenter cannot — a moved root, an unmounted
/// volume, a dropped batch.
final class DirectoryPresenter: NSObject, NSFilePresenter, @unchecked Sendable {

    private let root: URL
    /// The subitem that changed, or `nil` when the folder changed wholesale and
    /// there is no one path to name.
    private let onChange: @Sendable (URL?) -> Void
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

    init(root: URL, onChange: @escaping @Sendable (URL?) -> Void) {
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
    func presentedSubitemDidChange(at url: URL) { onChange(url) }

    /// The folder itself changed (contents replaced wholesale). No single path
    /// describes it, so the caller gets `nil` and has to assume the worst.
    func presentedItemDidChange() { onChange(nil) }

    func presentedSubitemDidAppear(at url: URL) { onChange(url) }

    func accommodatePresentedSubitemDeletion(at url: URL) async throws { onChange(url) }
}
