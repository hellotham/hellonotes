//
//  LauncherView.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  The "open" launcher: recent collections and Obsidian vaults to reopen, saved
//  libraries to switch to, and actions to open from the file system, browse
//  iCloud Obsidian vaults, clone a remote, or create a new repository.
//
//  Cross-platform. It was `#if os(macOS)` end to end, and nothing inside it
//  ever needed to be: `RecentsStore`, `LibrariesStore` and `Bookmark` are all
//  ungated, and the body is a `ScrollView` of buttons. Only the fixed 560×560
//  frame was Mac-shaped — a panel declares its own size, a sheet is given one.
//
//  What that gate cost the iPad was not the window but the *contents*: iOS
//  wired `openLauncher` straight to the file importer, so a vault you had
//  opened twenty times was still a folder you had to go and find again, and
//  saved libraries — a named set of collections to reopen together — could be
//  saved on the Mac, synced, and never opened on the iPad.
//

import SwiftUI

struct LauncherView: View {
    var recents: RecentsStore
    var libraries: LibrariesStore
    /// Collections currently open (for "Save Current Library").
    var openCollectionURLs: [URL]

    // Actions (each dismisses the launcher).
    var onOpenURL: (URL) -> Void
    var onOpenLibrary: (LibrariesStore.SavedLibrary) -> Void
    var onSaveLibrary: (String) -> Void
    /// Every way to add a collection — the set the toolbar renders as a menu
    /// and this renders as cards.
    var add: AddCollectionActions

    @Environment(\.dismiss) private var dismiss
    @State private var showSavePrompt = false
    @State private var newLibraryName = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Open", systemImage: "books.vertical")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    actionsRow

                    if !recents.obsidianVaults.isEmpty {
                        section("Obsidian Vaults", systemImage: "shippingbox") {
                            ForEach(recents.obsidianVaults) { entry in
                                recentRow(entry, symbol: "shippingbox")
                            }
                        }
                    }

                    if !recents.recentCollections.isEmpty {
                        section("Recent Collections", systemImage: "clock") {
                            ForEach(recents.recentCollections) { entry in
                                recentRow(entry, symbol: "folder")
                            }
                        }
                    }

                    librariesSection

                    if recents.entries.isEmpty && libraries.libraries.isEmpty {
                        Text("Nothing opened yet. Use the actions above to open a collection, an Obsidian vault, or clone a repository.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                    }
                }
                .padding()
            }
        }
        // Fixed on the Mac, device-sized on iOS — the same expression every
        // other panel in the app uses. Written out as a one-sided gate it read
        // as a size the iPad does not get; it is one presentation rule with two
        // spellings, which is what `panelFrame` is.
        .panelFrame(width: 560, height: 560)
        .alert("Save Library", isPresented: $showSavePrompt) {
            TextField("Library name", text: $newLibraryName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = newLibraryName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { onSaveLibrary(name); dismiss() }
            }
        } message: {
            Text("Save the \(openCollectionURLs.count) open collection\(openCollectionURLs.count == 1 ? "" : "s") as a named library you can reopen later.")
        }
    }

    // MARK: - Actions

    /// The same set the toolbar, the menu bar and the welcome screen offer.
    ///
    /// This listed three of the ways in and named one of them wrongly ("Open
    /// Collection" and "Open Obsidian Vault" were the same command with the
    /// same default). Rendering `AddCollectionActions.options` means the
    /// launcher gains every future way in for free and can never again offer a
    /// subset of them.
    private var actionsRow: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
            ForEach(add.options) { option in
                actionCard(option.title, option.symbol, option.subtitle) {
                    dismiss(); option.run()
                }
            }
        }
    }

    private func actionCard(_ title: String, _ symbol: String, _ subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: 26)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.medium)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recents

    private func recentRow(_ entry: RecentsStore.Entry, symbol: String) -> some View {
        Button {
            if let url = entry.url { dismiss(); onOpenURL(url) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name).fontWeight(.medium)
                    Text(entry.id).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Text(entry.lastOpened, format: .relative(presentation: .named))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) { recents.remove(entry) } label: {
                Label("Remove from Recents", systemImage: "xmark")
            }
        }
    }

    // MARK: - Libraries

    private var librariesSection: some View {
        section("Libraries", systemImage: "square.stack.3d.up") {
            if libraries.libraries.isEmpty {
                Text("No saved libraries yet.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(libraries.libraries) { library in
                    Button { dismiss(); onOpenLibrary(library) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(library.name).fontWeight(.medium)
                                Text(library.collectionNames.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Text("\(library.bookmarks.count)")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) { libraries.delete(library) } label: {
                            Label("Delete Library", systemImage: "trash")
                        }
                    }
                }
            }
            Button {
                newLibraryName = ""
                showSavePrompt = true
            } label: {
                Label("Save Current Library…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .disabled(openCollectionURLs.isEmpty)
            .padding(.top, 2)
        }
    }

    // MARK: - Section chrome

    @ViewBuilder
    private func section<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            content()
        }
    }
}
