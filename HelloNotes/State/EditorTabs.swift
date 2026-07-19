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

    /// The notes currently open in tabs, in tab order.
    var openNotes: [Note] { editors.compactMap(\.note) }

    /// Sum of every tab's save revision — bumps whenever any tab saves, so the
    /// shell can refresh derived data (links, search) after edits.
    var totalSavedRevision: Int { editors.reduce(0) { $0 + $1.savedRevision } }

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
            await model.open(note)
            if let self {
                self.editors.append(model)
                self.openTasks[note.id] = nil
            }
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
    func prune(keeping ids: Set<Note.ID>) {
        editors.removeAll { editor in
            guard let id = editor.note?.id else { return true }
            return !ids.contains(id)
        }
    }
}
