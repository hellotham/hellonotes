//
//  LibraryPlace.swift
//  HelloNotes
//
//  What the note-list column shows when the library rail is on **Library**:
//  the things that belong to the whole library rather than to one collection —
//  quick actions, recently edited notes, and bookmarks across every open
//  collection.
//
//  These used to sit in the left sidebar beside the collection list, which was
//  the bug: "New Note", "Graph View" and "Assistant" are commands, not places,
//  and bookmarks and recents span collections while the list beside them showed
//  exactly one. Giving them a place of their own is what freed the rail to be a
//  switcher (LibraryRail.swift).
//

import SwiftUI

struct LibraryPlace: View {
    /// A library-wide command. `id` is the title, so the array is a literal at
    /// the call site and still diffs stably.
    struct Action: Identifiable {
        let title: String
        let symbol: String
        var isEnabled: Bool = true
        let run: () -> Void
        var id: String { title }
    }

    var actions: [Action]
    /// Most recently edited notes across every open collection.
    var recents: [Note]
    /// Bookmarked notes across every open collection.
    var bookmarks: [Note]
    var selection: Note.ID?
    var accent: Color
    var onOpenNote: (Note) -> Void
    /// The primary action — open another collection, vault or library.
    var onOpenLibrary: () -> Void
    var isEmptyLibrary: Bool

    var body: some View {
        List {
            if isEmptyLibrary {
                Section {
                    ContentUnavailableView {
                        Label("No Collections", systemImage: "folder")
                    } description: {
                        Text("Open a collection, an Obsidian vault, or a saved library to begin.")
                    } actions: {
                        Button("Open…") { onOpenLibrary() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                Section {
                    ForEach(actions) { action in
                        Button {
                            action.run()
                        } label: {
                            Label(action.title, systemImage: action.symbol)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(!action.isEnabled)
                    }
                }

                if !bookmarks.isEmpty {
                    Section("Bookmarks") {
                        ForEach(bookmarks) { note in
                            noteRow(note, symbol: "bookmark.fill")
                        }
                    }
                }

                if !recents.isEmpty {
                    Section("Recent") {
                        ForEach(recents) { note in
                            noteRow(note, symbol: "clock")
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #else
        .listStyle(.insetGrouped)
        #endif
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isEmptyLibrary {
                VStack(spacing: 0) {
                    Divider()
                    Button {
                        onOpenLibrary()
                    } label: {
                        Label("Open…", systemImage: "books.vertical")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(10)
                }
                .background(.bar)
            }
        }
    }

    private func noteRow(_ note: Note, symbol: String) -> some View {
        Button {
            onOpenNote(note)
        } label: {
            Label {
                Text(note.title).lineLimit(1)
            } icon: {
                Image(systemName: symbol)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .foregroundStyle(selection == note.id
                             ? AnyShapeStyle(accent)
                             : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Recents

extension LibraryPlace {
    /// The `limit` most recently modified notes, in one pass.
    ///
    /// Deliberately not `sorted().prefix(limit)`: this is derived in a view
    /// body, and a 2,000-note vault would pay an O(n log n) sort on every
    /// re-evaluation to show eight rows.
    static func mostRecent(_ notes: [Note], limit: Int = 8) -> [Note] {
        var top: [Note] = []
        top.reserveCapacity(limit)
        for note in notes {
            if top.count < limit {
                let index = top.firstIndex { $0.lastModified < note.lastModified } ?? top.count
                top.insert(note, at: index)
            } else if let last = top.last, note.lastModified > last.lastModified {
                top.removeLast()
                let index = top.firstIndex { $0.lastModified < note.lastModified } ?? top.count
                top.insert(note, at: index)
            }
        }
        return top
    }
}
