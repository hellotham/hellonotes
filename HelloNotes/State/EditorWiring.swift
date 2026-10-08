//
//  EditorWiring.swift
//  HelloNotes
//
//  What an editor is told about the collection its note lives in — one
//  definition, for a tab and a note window alike.
//
//  It was written for tabs only. `ContentView.wireTabs` gave `EditorTabs` five
//  closures, which it set on each editor it made or called before loading one;
//  a note window (`NoteWindowView`) made a bare `EditorModel` and opened the
//  note itself, and got none of them. So a cloud note still a placeholder in
//  its collection's cache opened *empty* in a note window — nothing fetched its
//  bytes first — and what was typed there was written over the placeholder,
//  never uploaded, and replaced at the next download; its saves were never
//  registered as the app's own writes (the watcher took them for changes made
//  elsewhere), never indexed, and a save into a folder that had gone was not
//  refused. Both now wire an editor here, and cannot drift apart again.
//

import Foundation

@MainActor
struct EditorWiring {
    /// The open collection holding a file, if any.
    let collection: @MainActor (URL) -> Collection?

    init(collection: @escaping @MainActor (URL) -> Collection?) {
        self.collection = collection
    }

    /// Through the library: the collection whose folder holds the file.
    init(library: Library) {
        self.init { [weak library] url in library?.collection(containing: url) }
    }

    /// An editor told nothing — what `EditorTabs` holds until the shell wires it.
    static var unwired: EditorWiring { EditorWiring { _ in nil } }

    /// Tell `editor` about the collection its notes live in: a cloud note's
    /// bytes are fetched before it is read (`Collection.hydrateIfNeeded`), on
    /// every open; a save reaches the collection (`Collection.noteDidSave` —
    /// registered as the app's own write, indexed, and uploaded on a cloud
    /// collection); a note that finishes downloading loses its cloud badge; a
    /// write into a collection whose folder has gone is refused, and the
    /// buffer keeps the edit; a cloud mirror's stand-in is never taken for
    /// a note's text; and a file the editor puts beside a note — a pasted
    /// picture — reaches the collection, and on a cloud collection the provider.
    func wire(_ editor: EditorModel) {
        let collection = self.collection
        editor.prepareToOpen = { url in await collection(url)?.hydrateIfNeeded(url) }
        editor.onSaved = { url, text in collection(url)?.noteDidSave(url, text: text) }
        editor.onBecameAvailable = { url in collection(url)?.noteBecameAvailable(url) }
        editor.onFileMade = { url in collection(url)?.fileMadeHere(url) }
        editor.saveBlockedReason = { url in Self.saveBlockedReason(for: url, in: collection(url)) }
        editor.isPlaceholder = { url in collection(url)?.isPlaceholder(at: url) ?? false }
    }

    /// Why a note in `collection` cannot be written now, or `nil` if it can.
    static func saveBlockedReason(for url: URL, in collection: Collection?) -> String? {
        guard let collection, case .unavailable(let reason) = collection.state else { return nil }
        let title = url.deletingPathExtension().lastPathComponent
        return "Can’t save “\(title)” — \(reason.explanation) Your changes are kept here until it’s back."
    }

    /// Open `note` in a wired `editor`: its identity at once (`willOpen`), so
    /// whatever shows the editor can say it is downloading; then `shown`, where
    /// a caller puts it on screen; then the note, fetched first if its
    /// collection is a cloud mirror still holding a placeholder
    /// (`EditorModel.prepareToOpen`).
    func open(_ note: Note, in editor: EditorModel, shown: () -> Void = {}) async {
        editor.willOpen(note)
        shown()
        await editor.open(note)
    }
}
