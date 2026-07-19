//
//  NavigationRouter.swift
//  HelloNotes
//
//  The single navigation entry point for out-of-view-tree callers: the
//  `hellonotes://` URL scheme, App Intents (Shortcuts / Siri / Spotlight
//  actions), the Services menu, and widgets. It resolves a `URLRouter.Destination`
//  against the open library and publishes a `pendingNoteSelection` that the
//  content view observes to update its selection (which lives in view `@State`).
//

import Foundation
import Observation

@MainActor
@Observable
final class NavigationRouter {
    /// App-wide instance so App Intents (which run outside the SwiftUI environment)
    /// can navigate. Set in `init`; the app holds the strong reference.
    static weak var shared: NavigationRouter?

    /// A query the content view should surface in search. Cleared once applied.
    var pendingSearch: String?
    /// Bumped to ask the UI to bring the window forward (deep link / intent).
    private(set) var activationTick = 0

    private let library: Library

    init(library: Library) {
        self.library = library
        NavigationRouter.shared = self
    }

    /// Handle a `hellonotes://` URL (from `onOpenURL`).
    func handle(_ url: URL) {
        guard let dest = URLRouter.destination(for: url) else { return }
        Task { await route(dest) }
    }

    /// Perform a navigation. Returns whether it resolved to a target.
    @discardableResult
    func route(_ dest: URLRouter.Destination) async -> Bool {
        activationTick &+= 1
        switch dest {
        case .note(let collection, let ref):
            return selectNote(collectionNamed: collection, ref: ref)
        case .collection(let name):
            guard let coll = collection(named: name) else { return false }
            library.focusedID = coll.id
            return true
        case .search(let query):
            pendingSearch = query
            return true
        case .newNote(let collection, let title):
            return await createNote(collectionNamed: collection, title: title)
        case .dailyNote:
            return await openDailyNote()
        }
    }

    // MARK: - Resolution

    /// A collection matched by root-folder name or by id (standardized path).
    func collection(named name: String) -> Collection? {
        if let byID = library.collections.first(where: { $0.id == name }) { return byID }
        return library.collections.first {
            $0.rootURL.lastPathComponent.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// The target collection for a create/daily action: the named one, else the
    /// currently-focused one.
    private func targetCollection(named name: String?) -> Collection? {
        if let name, let c = collection(named: name) { return c }
        return library.focused
    }

    @discardableResult
    func selectNote(collectionNamed name: String, ref: URLRouter.NoteRef) -> Bool {
        guard let coll = collection(named: name) else { return false }
        let note: Note?
        switch ref {
        case .path(let rel):
            let target = rel.hasSuffix(".md") ? rel : rel + ".md"
            note = coll.notes.first { coll.relativePath(of: $0).caseInsensitiveCompare(target) == .orderedSame }
                ?? coll.note(titled: (rel as NSString).deletingPathExtension)
        case .title(let title):
            note = coll.note(titled: title)
        }
        guard let note else { library.focusedID = coll.id; return false }
        library.focusedID = coll.id
        library.requestOpen(note.fileURL)   // reuses the existing open-note plumbing
        return true
    }

    /// Create a note from captured text (Services menu / share): the title is the
    /// first line, the body is the full text. Focuses + opens the new note.
    @discardableResult
    func captureNote(text: String, collectionNamed name: String? = nil) async -> Bool {
        guard let coll = targetCollection(named: name) else { return false }
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "Captured Note"
        let title = String(firstLine.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let note = await coll.createNote(title: title.isEmpty ? "Captured Note" : title) else { return false }
        await coll.append(text, to: note)
        library.focusedID = coll.id
        library.requestOpen(note.fileURL)
        return true
    }

    @discardableResult
    func createNote(collectionNamed name: String?, title: String?) async -> Bool {
        guard let coll = targetCollection(named: name) else { return false }
        let clean = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let note = await coll.createNote(title: clean.isEmpty ? "Untitled" : clean) else { return false }
        library.focusedID = coll.id
        library.requestOpen(note.fileURL)   // reuses the existing open-note plumbing
        return true
    }

    /// Open (creating if needed) today's daily note in the target collection,
    /// honoring the configured folder + date format.
    @discardableResult
    func openDailyNote(collectionNamed name: String? = nil, appending text: String? = nil) async -> Bool {
        guard let coll = targetCollection(named: name) else { return false }
        let folder = UserDefaults.standard.string(forKey: "dailyNoteFolder") ?? ""
        let format = UserDefaults.standard.string(forKey: "dailyDateFormat") ?? "yyyy-MM-dd"
        let dayName = TemplateExpander.dailyNoteName(for: .now, format: format)
        let rel = folder.isEmpty ? "\(dayName).md" : "\(folder)/\(dayName).md"
        guard let note = await coll.note(atRelativePath: rel, creatingWith: "# \(dayName)\n\n") else { return false }
        if let text, !text.isEmpty {
            await coll.append(text.hasSuffix("\n") ? text : text + "\n", to: note)
        }
        library.focusedID = coll.id
        library.requestOpen(note.fileURL)   // reuses the existing open-note plumbing
        return true
    }

    /// Notes matching `query` across the focused collection (for SearchNotesIntent).
    func searchNotes(_ query: String, limit: Int = 20) -> [(collection: Collection, note: Note)] {
        guard let coll = library.focused else { return [] }
        return coll.search.quickOpenResults(query: query, limit: limit)
            .compactMap { item in coll.notes.first { $0.fileURL == item.note.fileURL }.map { (coll, $0) } }
    }

    /// Every note across the open collections, as `(collectionName, relativePath,
    /// title)` — the shape App-Intents entity building needs.
    func openNotesForIntents() -> [(collectionName: String, relativePath: String, title: String)] {
        library.collections.flatMap { coll in
            coll.notes.map { (coll.rootURL.lastPathComponent, coll.relativePath(of: $0), $0.title) }
        }
    }
}
