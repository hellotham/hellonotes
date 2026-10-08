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
//  switcher — a rail since folded into the sidebar's one tree.
//

import SwiftUI

/// Which place a shell's navigation is scoped to. `.library` means everything;
/// `.collection` narrows to one.
///
/// No shell has a rail to switch between them now — collections and their
/// folders are one tree (`docs/shell-chrome.md` D2). This is the sidebar's
/// scope in every shell: what New Note, Open Quickly, Graph and the rest act on
/// (`ContentView.railCollection`), and the compact shell's places.
enum RailPlace: Hashable, Sendable {
    case library
    case collection(Collection.ID)
}

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

    /// Drawn by the app with the compact places' own rows and headings. It was
    /// a `List` — `.sidebar` on the Mac and `.insetGrouped` on iOS, two
    /// different pictures of one place — with the open note picked out in the
    /// accent's *text* colour; it is now the shell's selection, the accent at
    /// 30% behind the row, as every other list draws it.
    var body: some View {
        Group {
            if isEmptyLibrary {
                ChromeEmptyState("No Collections", systemImage: "folder",
                                 description: Text("Open a collection, an Obsidian vault, or a saved library to begin.")) {
                    Button("Open…") { onOpenLibrary() }
                        .buttonStyle(ChromePushStyle(prominent: true))
                }
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(actions) { action in
                            row(action.title, symbol: action.symbol, action: action.run)
                                .disabled(!action.isEnabled)
                        }

                        if !bookmarks.isEmpty {
                            header("Bookmarks")
                            ForEach(bookmarks) { note in
                                noteRow(note, symbol: "bookmark.fill")
                            }
                        }

                        if !recents.isEmpty {
                            header("Recent")
                            ForEach(recents) { note in
                                noteRow(note, symbol: "clock")
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .viewport()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        ChromeDivider()
                        Button {
                            onOpenLibrary()
                        } label: {
                            Label("Open…", systemImage: "books.vertical")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ChromePushStyle(prominent: true))
                        .controlSize(.large)
                        .padding(10)
                    }
                    .background(Chrome.Colour.chrome)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Chrome.Colour.chrome)
    }

    private func noteRow(_ note: Note, symbol: String) -> some View {
        row(note.title, symbol: symbol, isSelected: selection == note.id) {
            onOpenNote(note)
        }
    }

    /// One row: a 12pt glyph and a 13pt title in the shell's row frame. A
    /// button rather than a tap gesture, so a command that cannot run is
    /// disabled as well as dimmed.
    private func row(_ title: String, symbol: String, isSelected: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ChromeRowFrame(height: Chrome.Metric.rowNote, isSelected: isSelected, accent: accent) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(Chrome.Typeface.rowIcon)
                        .foregroundStyle(Chrome.Colour.secondaryLabel)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    ChromeLine(title, size: 13)
                    Spacer(minLength: 8)
                }
            }
        }
        .buttonStyle(ChromePlainStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// A group's heading, as the other compact places draw theirs.
    private func header(_ title: String) -> some View {
        ChromeLine(title, size: 11, weight: .semibold, colour: Chrome.Colour.secondaryLabel)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)
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
            // `Note.newestFirst`, so notes saved in the same second keep one
            // order everywhere, as the sidebar's do.
            if top.count < limit {
                let index = top.firstIndex { Note.newestFirst(note, $0) } ?? top.count
                top.insert(note, at: index)
            } else if let last = top.last, Note.newestFirst(note, last) {
                top.removeLast()
                let index = top.firstIndex { Note.newestFirst(note, $0) } ?? top.count
                top.insert(note, at: index)
            }
        }
        return top
    }
}
