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

    /// What each tab's editor is told about the collection its note lives in —
    /// the same wiring a note window's editor gets (`EditorWiring`). Set by the
    /// shell, and asked when used rather than kept when a tab is made, so a
    /// tab opened before the shell sets it is wired the moment it does.
    var wiring = EditorWiring.unwired

    /// The notes currently open in tabs, in tab order.
    var openNotes: [Note] { editors.compactMap(\.note) }

    /// Sum of every tab's save revision — bumps whenever any tab saves, so the
    /// shell can refresh derived data (links, search) after edits.
    var totalSavedRevision: Int { editors.reduce(0) { $0 + $1.savedRevision } }

    /// Sum of every tab's *load* revision, plus the number of tabs.
    ///
    /// A tab is appended first and fills in once its note has been read
    /// (`editor(for:)`), so this is what changes when text first becomes
    /// available for a newly opened note.
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
            let wiring = EditorWiring { [weak self] url in self?.wiring.collection(url) }
            wiring.wire(model)
            // **The tab appears first, then it fills in.**
            //
            // It used to be appended only after `open` returned, and `open`
            // blocks in the file coordinator until a cloud file materialises —
            // so clicking a note that was not downloaded yet did *nothing at
            // all* for as long as the download took, and the only way to learn
            // it had worked was to click again afterwards. The editor knows how
            // to say it is downloading (`DownloadingBanner`); it just has to be
            // on screen to say it. The content is fetched after that and before
            // the editor reads the file (`EditorWiring.open`).
            await wiring.open(note, in: model, shown: { self?.editors.append(model) })
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
    ///
    /// The tab is found again after the flush, by the editor itself: the flush
    /// can take as long as a coordinated write does, and an index taken before
    /// it closed whichever tab had moved into that place — or trapped, once the
    /// same tab had been closed twice. And a tab whose conflict could not keep
    /// mine beside its note stays open, with its banner: closing it would drop
    /// mine. So does a tab whose save was refused — its folder gone, its note
    /// not loaded — and the edit kept in the buffer, as the banner promises:
    /// the tab was removed whatever the flush did, and the edit went with it
    /// (tabs.md §2.5, item 6; implemented.md §51.36).
    @discardableResult
    func close(_ id: Note.ID) async -> Note.ID? {
        guard let editor = editors.first(where: { $0.note?.id == id }) else { return nil }
        guard await editor.flush(), !(await editor.holdsUnsavedWork()) else { return id }
        guard let index = editors.firstIndex(where: { $0 === editor }) else { return nil }
        editors.remove(at: index)
        let neighbour = editors.indices.contains(index) ? editors[index] : editors.last
        return neighbour?.note?.id
    }

    /// Flush every tab — see `EditorModel.flush(lettingGo:)`: `false` when
    /// the tabs stay, as they do across a rename or a move.
    func flushAll(lettingGo: Bool = true) async {
        for editor in editors { await editor.flush(lettingGo: lettingGo) }
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
        // Typing an editor holds and has not carried is unsaved work, and
        // `isDirty` sees it only once carried.
        for editor in editors { editor.carryLiveEdits() }
        editors.removeAll { editor in
            guard let id = editor.note?.id else { return true }
            if ids.contains(id) { return false }
            // A conflict still to be chosen is unsaved work too, whatever the
            // count says.
            return !editor.isDirty && !editor.hasConflict
        }
    }
}
