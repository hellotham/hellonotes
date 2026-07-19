//
//  EditorModel.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import Foundation
import Observation

/// Owns the currently-open note's editing buffer and persists edits back to
/// disk. The file system is the source of truth: this model loads a note's
/// text, tracks whether the buffer diverges from what's on disk, and writes
/// changes atomically after a short debounce so no keystroke is ever lost.
@MainActor
@Observable
final class EditorModel {
    /// The note currently loaded in the editor, if any.
    private(set) var note: Note?

    /// Whether the buffer has unsaved changes relative to the last write.
    private(set) var isDirty = false

    /// The most recent save failure, surfaced to the UI (nil when healthy).
    private(set) var saveError: String?

    /// Increments after every successful write. Observers (e.g. the link graph)
    /// use it to know a note's contents changed on disk.
    private(set) var savedRevision = 0

    /// True when the open note changed on disk *and* we have unsaved edits, so
    /// the user must choose whether to keep their version or reload.
    private(set) var hasConflict = false

    /// Called after each successful save with the note's URL and saved text, so
    /// the owning collection can mark the write as its own (suppressing the file
    /// watcher) and patch its index from memory without re-reading the vault.
    var onSaved: (@MainActor (URL, String) -> Void)?

    /// Called at the start of every flush, before the buffer is persisted.
    /// The new-editor host uses this to push its document's latest text into
    /// `text` first, so a flush on note switch / quit never saves a snapshot
    /// that trails the editor by a debounce interval.
    var willFlush: (@MainActor () -> Void)?

    /// Increments whenever the buffer is *loaded* (note open, external
    /// reload, conflict resolution) — never on ordinary saves. Editors that
    /// own their own buffer key their rebuild on this.
    private(set) var loadRevision = 0

    /// The external on-disk version captured when a conflict was detected.
    private var conflictDiskText: String?

    /// The live editing buffer bound to the text view. Mutations schedule a
    /// debounced save — except while we are programmatically replacing the
    /// text during a load, which must not mark the buffer dirty.
    var text: String = "" {
        didSet {
            guard !isReplacingText else { return }
            isDirty = (text != lastSavedText)
            scheduleSave()
        }
    }

    private var lastSavedText = ""
    private var isReplacingText = false
    private var saveTask: Task<Void, Never>?
    /// The most recent write, so a new save chains after it instead of racing
    /// it at the filesystem (see `save()`).
    private var writeInFlight: Task<Void, Never>?

    private static let debounce: Duration = .milliseconds(600)

    /// Load a note into the editor, flushing any pending save for the
    /// previous note first so switching notes never drops changes. Pass `nil`
    /// to clear the editor.
    func open(_ note: Note?) async {
        await flush()

        self.note = note
        saveError = nil
        hasConflict = false
        conflictDiskText = nil

        let loaded: String
        if let url = note?.fileURL {
            // Read off the main actor so opening a large note never stalls the UI.
            loaded = await Task.detached(priority: .userInitiated) {
                (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }.value
        } else {
            loaded = ""
        }

        replaceText(loaded)
        lastSavedText = loaded
        isDirty = false
    }

    /// Cancel the pending debounce and persist immediately. Call on note
    /// switch, window resignation, and app termination.
    func flush() async {
        willFlush?()
        saveTask?.cancel()
        saveTask = nil
        await save()
    }

    /// React to the collection changing on disk. If the open note's file changed
    /// externally and our buffer is clean, silently reload it. If the buffer
    /// has unsaved edits, raise a conflict for the user to resolve.
    func reconcileWithDisk() async {
        guard let url = note?.fileURL else { return }
        // Read off the main actor — an externally-changed large note shouldn't
        // stall the UI during reconciliation.
        guard let disk = await Task.detached(priority: .userInitiated, operation: {
            try? String(contentsOf: url, encoding: .utf8)
        }).value else { return }

        // Matches what we last wrote (includes our own saves) → nothing to do.
        guard disk != lastSavedText else {
            hasConflict = false
            conflictDiskText = nil
            return
        }

        if isDirty {
            conflictDiskText = disk
            hasConflict = true
        } else {
            replaceText(disk)
            lastSavedText = disk
            isDirty = false
        }
    }

    /// Resolve a conflict by discarding local edits and loading the disk copy.
    func resolveConflictReloading() {
        guard let disk = conflictDiskText else { return }
        replaceText(disk)
        lastSavedText = disk
        isDirty = false
        hasConflict = false
        conflictDiskText = nil
    }

    /// Resolve a conflict by keeping local edits and overwriting the disk copy.
    func resolveConflictKeepingMine() async {
        hasConflict = false
        conflictDiskText = nil
        await save()
    }

    /// Persist the buffer if it diverges from disk. Safe to call repeatedly.
    ///
    /// Writes are *serialized*: a new save waits for any in-flight write to
    /// finish before starting its own. `cancel()` cannot stop a `save()` that
    /// is already past its guard and awaiting the detached write, so without
    /// this chaining two atomic writes could race — and atomic rename ordering
    /// is unspecified, so an older write could land last and persist stale
    /// text. That window matters most on `flush()` at app termination, where
    /// there is no later save to converge the buffer back to disk.
    func save() async {
        guard note?.fileURL != nil else { return }
        // Fast path: nothing to persist → don't allocate a Task or touch the
        // write chain. (performSave re-checks after the await, so a change that
        // lands while a prior write is in flight is still caught.)
        guard text != lastSavedText else { return }
        let previous = writeInFlight
        let task = Task { [weak self] in
            await previous?.value
            await self?.performSave()
        }
        writeInFlight = task
        await task.value
    }

    /// The actual snapshot-and-write step, run serially by `save()`. Because it
    /// only runs after the previous write completes, it reads the *current*
    /// `text` (and the already-advanced `lastSavedText`), so the final on-disk
    /// state always matches the latest buffer.
    private func performSave() async {
        guard let url = note?.fileURL else { return }
        let snapshot = text
        guard snapshot != lastSavedText else { return }

        do {
            let data = Data(snapshot.utf8)
            // Atomic write (temp file + rename) so a crash mid-write can never
            // leave a truncated note on disk. Offloaded so large notes don't
            // stall the main actor.
            try await Task.detached(priority: .utility) {
                try data.write(to: url, options: .atomic)
            }.value
            lastSavedText = snapshot
            isDirty = (text != lastSavedText)
            saveError = nil
            savedRevision += 1
            onSaved?(url, snapshot)
        } catch {
            saveError = error.localizedDescription
        }
    }

    // MARK: - Private

    private func replaceText(_ newValue: String) {
        isReplacingText = true
        text = newValue
        isReplacingText = false
        loadRevision += 1
    }

    private func scheduleSave() {
        saveTask?.cancel()
        guard note != nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: EditorModel.debounce)
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }
}
