//
//  LibraryRail.swift
//  HelloNotes
//
//  Column 1 of the wide shells: a narrow vertical switcher of *places* — the
//  Library at the top, then one row per open collection, with a pinned footer
//  at the bottom.
//
//  This replaces the old left sidebar, which was a `List` holding a collection
//  card, five command buttons, bookmarks and Git all at once — three scrolling
//  lists side by side, and commands presented as if they were destinations.
//  Commands are not places. The rail carries only places; everything that used
//  to sit beside them now lives in the Library place itself (LibraryPlace.swift)
//  where it is actually library-wide.
//
//  The consequence, decided with the user: the rail **replaces the note list's
//  collection level**. The outline used to root at collections with folders
//  beneath; now the rail picks the collection and the outline roots at that
//  collection's folders. One question answered in one place.
//

import SwiftUI

/// Which place the rail is showing. `.library` is the library-wide place;
/// `.collection` scopes the note list to one collection's folder tree.
enum RailPlace: Hashable, Sendable {
    case library
    case collection(Collection.ID)
}

struct LibraryRail<Footer: View>: View {
    var collections: [Collection]
    @Binding var place: RailPlace
    var accent: Color

    /// Selecting a collection also focuses it — the rail *is* the focus control
    /// now, so the two can never disagree.
    var onSelectCollection: (Collection) -> Void
    var onCloseCollection: (Collection) -> Void
    /// macOS only; `nil` hides the menu item.
    var onRevealCollection: ((Collection) -> Void)? = nil
    /// The "+" beneath the collections — open another collection or vault.
    var onAddCollection: () -> Void

    /// How far the window's titlebar overlaps this column. The rows start below
    /// it: the column is laid out full height by SwiftUI and cannot be moved
    /// (see TitlebarInsetReader), so the first row's selection chip would
    /// otherwise sit under the traffic lights.
    var topInset: CGFloat = 0

    /// Pinned to the bottom, below a divider. The Mac puts Git here; iOS
    /// passes `EmptyView`.
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            // A `List`, not a `ScrollView`. In a full-height sidebar column the
            // window's titlebar floats *over* the content, and a scroll view
            // deliberately scrolls its content underneath it — so the first
            // row's selection chip landed on top of the traffic lights. AppKit
            // gives a source list the titlebar content-inset for free, which is
            // why the sidebar this rail replaced never had the problem. Use the
            // container the platform already insets rather than re-deriving the
            // inset by hand.
            List {
                railButton(
                    symbol: "books.vertical.fill",
                    caption: "Library",
                    isSelected: place == .library,
                    help: "Quick actions, recent notes and bookmarks across every open collection"
                ) {
                    place = .library
                }
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                .listRowSeparator(.hidden)

                ForEach(collections) { collection in
                    collectionButton(collection)
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                        .listRowSeparator(.hidden)
                }

                railButton(
                    symbol: "plus",
                    caption: "Open",
                    isSelected: false,
                    help: "Open a collection, an Obsidian vault, or a saved library",
                    action: onAddCollection
                )
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                .listRowSeparator(.hidden)
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: topInset)
            }
            // S1: a rail is a viewport onto its rows, never sized by them.
            .frame(maxHeight: .infinity)

            footer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("shell.libraryRail")
    }

    // MARK: - Rows

    private func collectionButton(_ collection: Collection) -> some View {
        // Where a collection *lives* used to be on the sidebar's collection
        // card. The rail has no room for a card, but a vault in Dropbox behaves
        // differently enough — online-only files, Git guarded — that its icon
        // and tooltip have to carry it.
        let cloud = collection.isRemote ? nil : CloudProvider.name(for: collection.rootURL)
        let symbol = collection.isRemote ? "network"
            : (cloud != nil ? CloudProvider.symbol : "folder.fill")
        let notes = "\(collection.notes.count) note\(collection.notes.count == 1 ? "" : "s")"
        let where_: String
        if let remote = collection.remote {
            where_ = " — \(remote.store.providerName) (direct)"
        } else if let cloud {
            where_ = " — in \(cloud)"
        } else {
            where_ = ""
        }
        return railButton(
            symbol: symbol,
            caption: collection.name,
            isSelected: place == .collection(collection.id),
            help: "\(collection.name) — \(notes)\(where_)",
            // An orange pip means "this collection has uncommitted changes",
            // the one thing about a collection worth knowing before you open it.
            badge: collection.git.status.isRepository && !collection.git.status.isClean
        ) {
            place = .collection(collection.id)
            onSelectCollection(collection)
        }
        .contextMenu {
            Button("Focus Collection") {
                place = .collection(collection.id)
                onSelectCollection(collection)
            }
            if let onRevealCollection {
                Button("Reveal in Finder") { onRevealCollection(collection) }
            }
            Divider()
            Button("Close Collection") { onCloseCollection(collection) }
        }
    }

    private func railButton(symbol: String,
                            caption: String,
                            isSelected: Bool,
                            help: String,
                            badge: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? AnyShapeStyle(accent.opacity(0.18)) : AnyShapeStyle(.clear))
                        .frame(width: 40, height: 30)
                        .overlay {
                            Image(systemName: symbol)
                                .font(.system(size: 15, weight: .regular))
                                .foregroundStyle(isSelected ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                        }
                    if badge {
                        Circle()
                            .fill(.orange)
                            .frame(width: 6, height: 6)
                            .offset(x: -3, y: 2)
                    }
                }
                Text(caption)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(caption)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
