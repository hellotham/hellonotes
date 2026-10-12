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

import AppIntents
import CoreSpotlight
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

    /// A destination that named nothing *yet* — it arrived while the library
    /// was still coming back — with when it arrived. See `hold`.
    @ObservationIgnored private var held: (destination: URLRouter.Destination, since: ContinuousClock.Instant)?
    /// How long a held destination is still what the person asked for.
    @ObservationIgnored private let holdsFor: Duration

    init(library: Library, holdsFor: Duration = .seconds(120)) {
        self.library = library
        self.holdsFor = holdsFor
        NavigationRouter.shared = self
    }

    /// Handle a `hellonotes://` URL (from `onOpenURL`).
    func handle(_ url: URL) {
        guard let dest = URLRouter.destination(for: url) else { return }
        Task { await route(dest) }
    }

    /// Perform a navigation. Returns whether it resolved to a target — now.
    /// One that did not, while the library is still coming back at launch, is
    /// held and tried again when it has (`hold`).
    @discardableResult
    func route(_ dest: URLRouter.Destination) async -> Bool {
        activationTick &+= 1
        let resolved = await resolve(dest)
        // The latest link is where the person meant to go, whichever way it
        // went: one that could not be resolved replaces what was held, and one
        // that could *ends* it — or an older link, still held, was tried when
        // the launch settled and opened over this one.
        if resolved { held = nil } else { hold(dest) }
        return resolved
    }

    // MARK: - A link that arrives before the library

    /// Keep `dest` to try again when the launch has settled.
    ///
    /// **A link that launches the app arrives before the library does.** The
    /// window's first work is bringing back what was open at the last quit —
    /// bookmarks resolved off the main actor, then each collection read — and
    /// a link is handed over as soon as there is a window. Resolved then, it
    /// named a collection not yet open (or open and not yet read), found
    /// nothing and was dropped: the app came up on whatever it showed last,
    /// and a tap on the widget with the app closed did nothing a tap on its
    /// icon would not have.
    ///
    /// Held, not waited for: the answer `route` gives is still the answer
    /// *now*, so a caller that needs one — an intent — is not kept waiting on
    /// a launch that, with no window, may never come. The last one held is the
    /// one tried; the launch settling tries it once; and one that still names
    /// nothing then is dropped, as a link to nothing always was — so is one
    /// held so long that it is no longer what the person is doing. Once the
    /// launch has settled nothing is held at all.
    private func hold(_ dest: URLRouter.Destination) {
        guard !library.hasSettled else { return }
        let alreadyWaiting = held != nil
        held = (dest, .now)
        guard !alreadyWaiting else { return }
        library.afterLaunch { [weak self] in self?.tryWhatWasHeld() }
    }

    private func tryWhatWasHeld() {
        guard let (dest, since) = held else { return }
        held = nil
        guard ContinuousClock.now - since <= holdsFor else { return }
        Task { _ = await resolve(dest) }
    }

    /// Resolve `dest` against the library as it stands. Holds nothing.
    private func resolve(_ dest: URLRouter.Destination) async -> Bool {
        switch dest {
        case .note(let collection, let ref):
            return select(collectionNamed: collection, ref: ref)
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

    /// Ask the window to show the note — or, if it cannot be found while the
    /// library is still coming back, when it has (`hold`): an intent that
    /// opens the app to show a note runs before the note's collection is open.
    @discardableResult
    func selectNote(collectionNamed name: String, ref: URLRouter.NoteRef) -> Bool {
        let selected = select(collectionNamed: name, ref: ref)
        if selected { held = nil } else { hold(.note(collection: name, ref: ref)) }
        return selected
    }

    private func select(collectionNamed name: String, ref: URLRouter.NoteRef) -> Bool {
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
        // The note is shown either way — it is there — and the answer is
        // whether the text reached it: it was `true` for a note left empty.
        let written = await coll.append(text, to: note)
        library.focusedID = coll.id
        library.requestOpen(note.fileURL)
        return written
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

    /// What became of a request for today's note.
    enum DailyNoteResult: Equatable {
        case done
        /// There is no collection to make it in.
        case noCollection
        /// The note could not be made, or what was to be added to it could not
        /// be — with why, as the collection reported it.
        case failed(String)
    }

    /// Open (creating if needed) today's daily note in the target collection,
    /// honoring the configured folder + date format.
    @discardableResult
    func openDailyNote(collectionNamed name: String? = nil, appending text: String? = nil) async -> Bool {
        await dailyNote(collectionNamed: name, appending: text) == .done
    }

    /// The same, saying what went wrong. Quick Capture clears its field as it
    /// sends and answered "Added to today's note." for anything but a missing
    /// collection — so a capture that could not be written was gone, under a
    /// line saying it had been added (implemented.md §51.45).
    func dailyNote(collectionNamed name: String? = nil, appending text: String? = nil) async -> DailyNoteResult {
        guard let coll = targetCollection(named: name) else { return .noCollection }
        let folder = UserDefaults.standard.string(forKey: "dailyNoteFolder") ?? ""
        let format = UserDefaults.standard.string(forKey: "dailyDateFormat") ?? "yyyy-MM-dd"
        let dayName = TemplateExpander.dailyNoteName(for: .now, format: format)
        let rel = folder.isEmpty ? "\(dayName).md" : "\(folder)/\(dayName).md"
        guard let note = await coll.note(atRelativePath: rel, creatingWith: "# \(dayName)\n\n") else {
            return .failed(coll.lastError ?? "Couldn't make today's note.")
        }
        if let text, !text.isEmpty {
            guard await coll.append(text.hasSuffix("\n") ? text : text + "\n", to: note) else {
                return .failed(coll.lastError ?? "Couldn't add that to today's note.")
            }
        }
        library.focusedID = coll.id
        library.requestOpen(note.fileURL)   // reuses the existing open-note plumbing
        return .done
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

    /// UserDefaults key holding the ids donated last time, so the next donation
    /// can retract the ones that disappeared.
    private static let donatedIDsKey = "spotlightDonatedIDs"

    /// Donate the open notes to system Spotlight — findable in ⌘Space, and
    /// opened by `OpenNoteFromSearchIntent`. Re-donated when the note set
    /// changes.
    ///
    /// `indexAppEntities` is add-or-update **by id**, and `NoteEntity.id`
    /// encodes the relative path — so a rename or delete strands the old id in
    /// the system index *permanently* (it survives relaunches), leaving ⌘Space
    /// results that open nothing. Diff against the previous donation and
    /// explicitly retract what's gone.
    func donateNotesToSpotlight() async {
        // A run launched to be captured opens the sample collection alone, and
        // donated like any other launch it *retracted* every note the person
        // has in Spotlight — the last donation, less the sample — for their
        // next launch to donate again.
        guard !CaptureSession.isActive else { return }
        let entities = openNotesForIntents().prefix(500).map {
            NoteEntity(collectionName: $0.collectionName, relativePath: $0.relativePath, title: $0.title)
        }
        let index = CSSearchableIndex.default()
        let current = Set(entities.map(\.id))
        let previous = Set(UserDefaults.standard.stringArray(forKey: Self.donatedIDsKey) ?? [])

        let stale = previous.subtracting(current)
        if !stale.isEmpty {
            try? await index.deleteAppEntities(identifiedBy: Array(stale), ofType: NoteEntity.self)
        }
        try? await index.indexAppEntities(Array(entities))
        UserDefaults.standard.set(Array(current), forKey: Self.donatedIDsKey)
    }
}
