//
//  EditorTabs.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import Foundation
import Observation

/// Holds one `EditorModel` per open note so several notes can be edited in
/// tabs. The *active* tab is whichever editor matches the app's selected note
/// id (owned by the shell), so selection and tabs stay in sync.
@MainActor
@Observable
final class EditorTabs {
    private(set) var editors: [EditorModel] = []

    /// In-flight opens keyed by note id, so two near-simultaneous requests for
    /// the same note (double-click, or a programmatic open racing a selection)
    /// share one editor instead of each passing the pre-`await` existence check
    /// and appending a duplicate tab.
    private var openTasks: [Note.ID: Task<EditorModel, Never>] = [:]

    /// Routed to whichever collection owns the saved note, so it can suppress
    /// the file watcher for its own write and refresh its index incrementally.
    var onNoteSaved: (@MainActor (URL, String) -> Void)?

    /// A note finished downloading from the cloud — see
    /// `EditorModel.onBecameAvailable`.
    var onNoteBecameAvailable: (@MainActor (URL) -> Void)?

    /// Asked before every editor write: return a reason to refuse it. The shell
    /// blocks saves into a collection whose folder has gone missing.
    var saveBlocked: (@MainActor (URL) -> String?)?

    /// Called before a note is loaded, so a direct-API collection can fetch the
    /// real bytes for what is currently only a placeholder.
    var prepareToOpen: (@MainActor (URL) async -> Void)?

    /// The notes currently open in tabs, in tab order.
    var openNotes: [Note] { editors.compactMap(\.note) }

    /// Sum of every tab's save revision — bumps whenever any tab saves, so the
    /// shell can refresh derived data (links, search) after edits.
    var totalSavedRevision: Int { editors.reduce(0) { $0 + $1.savedRevision } }

    /// Sum of every tab's *load* revision, plus the number of tabs.
    ///
    /// A tab is appended only after its note has been read, so this is what
    /// changes when text first becomes available for a newly opened note.
    /// Anything deriving from an open note's text must name it: keying on
    /// `totalSavedRevision` alone means the derived value is computed against
    /// the empty placeholder editor and never recomputed, because opening a
    /// note saves nothing.
    var totalLoadRevision: Int {
        editors.reduce(editors.count) { $0 + $1.loadRevision }
    }

    /// The editor for `note`, opening a new tab (and loading it) if needed.
    @discardableResult
    func editor(for note: Note) async -> EditorModel {
        if let existing = editors.first(where: { $0.note?.id == note.id }) {
            return existing
        }
        if let inFlight = openTasks[note.id] {
            return await inFlight.value
        }
        let task = Task { [weak self] () -> EditorModel in
            let model = EditorModel()
            model.onSaved = { [weak self] url, text in self?.onNoteSaved?(url, text) }
            model.onBecameAvailable = { [weak self] url in self?.onNoteBecameAvailable?(url) }
            model.saveBlockedReason = { [weak self] url in self?.saveBlocked?(url) }
            // **The tab appears first, then it fills in.**
            //
            // It used to be appended only after `open` returned, and `open`
            // blocks in the file coordinator until a cloud file materialises —
            // so clicking a note that was not downloaded yet did *nothing at
            // all* for as long as the download took, and the only way to learn
            // it had worked was to click again afterwards. The editor knows how
            // to say it is downloading (`DownloadingBanner`); it just has to be
            // on screen to say it.
            model.willOpen(note)
            self?.editors.append(model)

            // Fetch the content *before* the editor reads the file, or it would
            // load a placeholder's emptiness as the note's text.
            await self?.prepareToOpen?(note.fileURL)
            await model.open(note)
            self?.openTasks[note.id] = nil
            return model
        }
        openTasks[note.id] = task
        return await task.value
    }

    func editor(withID id: Note.ID?) -> EditorModel? {
        guard let id else { return nil }
        return editors.first { $0.note?.id == id }
    }

    /// Close a tab, flushing its edits. Returns the id that should become active
    /// (a neighbouring tab), or nil if none remain.
    @discardableResult
    func close(_ id: Note.ID) async -> Note.ID? {
        guard let index = editors.firstIndex(where: { $0.note?.id == id }) else { return nil }
        await editors[index].flush()
        editors.remove(at: index)
        let neighbour = editors.indices.contains(index) ? editors[index] : editors.last
        return neighbour?.note?.id
    }

    func flushAll() async {
        for editor in editors { await editor.flush() }
    }

    func reconcileAll() async {
        for editor in editors { await editor.reconcileWithDisk() }
    }

    /// Drop tabs whose note no longer exists (deleted / renamed externally).
    ///
    /// **Never drops unsaved work.** This used to `removeAll` outright, while
    /// `close(_:)` two dozen lines up carefully awaited `flush()` — so the tidy-up
    /// path discarded what the deliberate path preserved. It runs from
    /// `.onChange(of: library.allNotes)`, and `Note` is `Hashable` over
    /// `lastModified`, so it fires on *any* mtime change to *any* note: a note
    /// that momentarily left the list took the user's pending keystrokes with it,
    /// silently, in a notes app.
    ///
    /// An editor with unsaved changes is now **kept** rather than flushed-and-
    /// dropped. A note missing from the list is usually a scan under-reporting,
    /// not a deletion, and the file it is editing is still on disk — the golden
    /// rule is that nothing outside the editor may close the file being typed
    /// into. A genuine deletion goes through `close(_:)`.
    func prune(keeping ids: Set<Note.ID>) {
        editors.removeAll { editor in
            guard let id = editor.note?.id else { return true }
            if ids.contains(id) { return false }
            return !editor.isDirty
        }
    }
}
