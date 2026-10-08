//
//  EditorDocumentStore.swift
//  HelloNotes
//
//  Keeps built `EditorDocument`s alive across view churn.
//
//  Building a document parses and styles the whole note, so it is the one
//  expensive thing the editor does. It used to happen inside the editor host's
//  `.task(id:)`, which means it ran again whenever SwiftUI re-created that
//  view — on every tab switch, and on any change of shell arrangement (an iPad
//  rotating between the tall and wide layouts crosses that boundary every
//  time). Each rebuild also dropped the caret and the scroll position.
//
//  Owning documents above the shell makes that churn free: the view can come
//  and go, and the note it was showing is still parsed, styled, and scrolled
//  where the user left it.
//

import Foundation
import Observation
import MarkdownEditor

@MainActor
@Observable
final class EditorDocumentStore {
    /// A document is only valid for the theme it was built with — `theme` is
    /// immutable on `EditorDocument`, and the colours in it are
    /// appearance-specific. So the identity of a cached document is the note
    /// *plus* the presentation it was built for — *plus* the editor it was
    /// built for.
    struct Key: Hashable {
        let path: String
        /// The `EditorModel` whose buffer the document is the live copy of.
        ///
        /// A note open in two windows — a tab in one, Open in New Window in
        /// the other — has an editor in each, and this store is the app's. The
        /// key named the note alone, so the second window was handed the
        /// first's document and its load: settling it with its own buffer
        /// replaced what the first window had typed, and took the load, so the
        /// first window's end of editing carried into the second's buffer.
        let editor: String
        /// Rounded: the editor's font size is a scale times a base, and
        /// sub-point differences don't warrant a reparse.
        let fontSize: Int
        let isDark: Bool
        /// The accent the theme was built from, as a comparable token.
        ///
        /// The key named the appearance but not the accent, while
        /// `EditorTheme(fontSize:accent:)` takes both — so after changing the
        /// accent (or toggling Increase Contrast) this store handed back the
        /// document built with the old one, and links, wiki links, tags,
        /// footnotes, list markers and `==highlights==` kept the previous
        /// colour until the note fell out of the cache.
        let accent: String

        init(path: String, editor: String, fontSize: CGFloat, isDark: Bool, accent: String) {
            self.path = path
            self.editor = editor
            self.fontSize = Int(fontSize.rounded())
            self.isDark = isDark
            self.accent = accent
        }
    }

    /// Documents hold the whole note's text storage plus its parse state, so
    /// this is bounded — the point is to survive view churn and tab switching,
    /// not to hold a vault in memory.
    private let limit: Int

    @ObservationIgnored private var documents: [Key: EditorDocument] = [:]
    /// When each document last held the same text as the buffer it was shown
    /// for (`DocumentLoad`) — so coming back to a tab can know the two still
    /// agree without comparing the note with itself.
    @ObservationIgnored private var loads: [Key: DocumentLoad] = [:]
    /// Least-recently-used last.
    @ObservationIgnored private var recency: [Key] = []

    init(limit: Int = 8) {
        self.limit = limit
    }

    func document(for key: Key) -> EditorDocument? {
        guard let document = documents[key] else { return nil }
        touch(key)
        return document
    }

    /// The document an editor kept for its note before the note moved —
    /// renamed, or moved into another folder — taken under `key`, where the
    /// note is now. One editor holds one note, so a document of the same
    /// editor and presentation under another path is that note's. Found again,
    /// the tab keeps its caret and its undo; built again from the buffer, it
    /// lost both (tabs.md §2.5, item 13; implemented.md §51.36).
    func documentMoved(to key: Key) -> EditorDocument? {
        guard let old = documents.keys.first(where: {
            $0.editor == key.editor && $0.path != key.path && $0.fontSize == key.fontSize
                && $0.isDark == key.isDark && $0.accent == key.accent
        }), let document = documents.removeValue(forKey: old) else { return nil }
        documents[key] = document
        loads[key] = loads.removeValue(forKey: old)
        recency.removeAll { $0 == old }
        touch(key)
        return document
    }

    func insert(_ document: EditorDocument, for key: Key) {
        documents[key] = document
        loads[key] = nil
        touch(key)
        evictIfNeeded()
    }

    /// The last match recorded for the document at `key`, if it is still held.
    func load(for key: Key) -> DocumentLoad? {
        documents[key] == nil ? nil : loads[key]
    }

    func remember(_ load: DocumentLoad, for key: Key) {
        guard documents[key] != nil else { return }
        loads[key] = load
    }

    /// Forget every cached form of one note — it was closed, deleted, or
    /// reloaded in a way that could not be patched in place.
    func forget(path: String) {
        for key in documents.keys where key.path == path { drop(key) }
    }

    /// Forget everything. Called when the *set* of notes changes: a document's
    /// services capture which wiki-link targets exist, so after a note is added
    /// or renamed a cached document would colour `[[links]]` by a stale answer.
    func forgetAll() {
        for key in Array(documents.keys) { drop(key) }
    }

    /// Forget everything **except the note at `path`**.
    ///
    /// `forgetAll` discards the document the user is typing into, and a
    /// discarded document means a rebuilt `UITextView`, which means first
    /// responder is gone: the keyboard drops and the caret vanishes mid-note.
    /// It was called whenever the note *set* changed — including when the user
    /// created a note, so making one ejected them from the one they were in.
    ///
    /// The reason for forgetting is real but narrow: a document's services
    /// captured which wiki-link targets existed when it was built, so a new
    /// note can leave `[[links]]` coloured by a stale answer. That is a
    /// *styling* staleness in other documents, and it is worth a rebuild for
    /// them. It is not worth taking the keyboard away from the person typing.
    func forgetAll(except path: String?) {
        guard let path else { forgetAll(); return }
        for key in documents.keys where key.path != path { drop(key) }
    }

    /// Let go of one kept document — after carrying what was typed into it
    /// into its own buffer. A kept document can hold typing that never
    /// reached the model: nothing ends editing on a tab switch, so the tab you
    /// left may still be only here. Dropped as it was, that typing went with
    /// it; the model it belongs to is still open, in a tab.
    private func drop(_ key: Key) {
        if let document = documents[key], let load = loads[key], let model = load.model {
            load.carry(document, into: model)
        }
        documents[key] = nil
        loads[key] = nil
        recency.removeAll { $0 == key }
    }

    private func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func evictIfNeeded() {
        while recency.count > limit, let oldest = recency.first { drop(oldest) }
    }
}
