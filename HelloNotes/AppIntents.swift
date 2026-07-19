//
//  AppIntents.swift
//  HelloNotes
//
//  App Intents: one entity + four intents feed Shortcuts/Siri, macOS 26 Spotlight
//  actions (⌘Space), system-Spotlight donation, and Apple Intelligence. Intents
//  run out of the SwiftUI environment, so they reach the app through the shared
//  `NavigationRouter` (which owns the open Library). Navigation intents launch
//  the app when needed; all work happens on the main actor.
//

import AppIntents
import Foundation

// MARK: - Entity

/// A note, addressable by Shortcuts / Spotlight. `id` composes the collection
/// name and the collection-relative path (they round-trip to a real note and to
/// a `hellonotes://` deep link).
struct NoteEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Note")
    static let defaultQuery = NoteEntityQuery()

    let id: String
    let title: String
    let collectionName: String
    let relativePath: String

    init(collectionName: String, relativePath: String, title: String) {
        self.id = "\(collectionName)\u{1}\(relativePath)"
        self.collectionName = collectionName
        self.relativePath = relativePath
        self.title = title
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(collectionName)")
    }

    /// A `hellonotes://note?...` deep link back to this note.
    var deepLink: URL {
        var comps = URLComponents()
        comps.scheme = URLRouter.scheme
        comps.host = "note"
        comps.queryItems = [
            URLQueryItem(name: "collection", value: collectionName),
            URLQueryItem(name: "path", value: relativePath),
        ]
        return comps.url ?? URL(string: "\(URLRouter.scheme)://daily")!
    }
}

struct NoteEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [NoteEntity.ID]) async throws -> [NoteEntity] {
        let wanted = Set(identifiers)
        return NoteEntity.allInOpenLibrary().filter { wanted.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [NoteEntity] {
        Array(NoteEntity.allInOpenLibrary().prefix(50))
    }
}

extension NoteEntity {
    /// Every note in the open collections (the app must be running — collections
    /// need their security-scoped access).
    @MainActor
    static func allInOpenLibrary() -> [NoteEntity] {
        guard let router = NavigationRouter.shared else { return [] }
        return router.openNotesForIntents().map {
            NoteEntity(collectionName: $0.collectionName, relativePath: $0.relativePath, title: $0.title)
        }
    }
}

// MARK: - Intents

struct CreateNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Note"
    static let description = IntentDescription("Create a new note in HelloNotes.")
    static let openAppWhenRun = true

    @Parameter(title: "Title")
    var noteTitle: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Create a note titled \(\.$noteTitle)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let router = NavigationRouter.shared else {
            throw AppIntentError.noOpenCollection
        }
        guard await router.createNote(collectionNamed: nil, title: noteTitle) else {
            throw AppIntentError.noOpenCollection
        }
        return .result()
    }
}

struct AppendToDailyNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Append to Daily Note"
    static let description = IntentDescription("Append text to today's daily note in HelloNotes.")

    @Parameter(title: "Text")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Append \(\.$text) to today's daily note")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let router = NavigationRouter.shared else { throw AppIntentError.noOpenCollection }
        guard await router.openDailyNote(appending: text) else { throw AppIntentError.noOpenCollection }
        return .result()
    }
}

struct OpenNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Note"
    static let description = IntentDescription("Open a note in HelloNotes.")
    static let openAppWhenRun = true

    @Parameter(title: "Note")
    var note: NoteEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$note)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let router = NavigationRouter.shared else { throw AppIntentError.noOpenCollection }
        _ = router.selectNote(collectionNamed: note.collectionName, ref: .path(note.relativePath))
        return .result()
    }
}

struct SearchNotesIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Notes"
    static let description = IntentDescription("Search notes in the focused HelloNotes collection.")
    static let openAppWhenRun = true

    @Parameter(title: "Query")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search notes for \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[NoteEntity]> {
        guard let router = NavigationRouter.shared else { throw AppIntentError.noOpenCollection }
        router.pendingSearch = query
        let matches = router.searchNotes(query).map {
            NoteEntity(collectionName: $0.collection.rootURL.lastPathComponent,
                       relativePath: $0.collection.relativePath(of: $0.note),
                       title: $0.note.title)
        }
        return .result(value: matches)
    }
}

enum AppIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noOpenCollection
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noOpenCollection: "Open a collection in HelloNotes first."
        }
    }
}

// MARK: - Shortcuts

struct HelloNotesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CreateNoteIntent(), phrases: [
            "Create a note in \(.applicationName)",
            "New \(.applicationName) note",
        ], shortTitle: "Create Note", systemImageName: "square.and.pencil")

        AppShortcut(intent: AppendToDailyNoteIntent(), phrases: [
            "Append to my \(.applicationName) daily note",
            "Add to today's note in \(.applicationName)",
        ], shortTitle: "Append to Daily Note", systemImageName: "calendar.badge.plus")

        AppShortcut(intent: SearchNotesIntent(), phrases: [
            "Search \(.applicationName)",
            "Find notes in \(.applicationName)",
        ], shortTitle: "Search Notes", systemImageName: "magnifyingglass")
    }
}
