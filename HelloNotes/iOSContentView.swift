//
//  iOSContentView.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// The iOS / iPadOS shell. A three-column `NavigationSplitView` mirrors the
/// macOS app: a navigation sidebar (vault + All Notes + `#tags` filter), the
/// note list, and the editor. On iPad landscape all three columns show at once
/// (like macOS); on iPad portrait the sidebar tucks behind a toggle; on iPhone
/// it collapses to a push stack. Shares `Note`, `WorkspaceIndexer`,
/// `EditorModel`, and `VaultSearchModel` with macOS. MarkdownEngine is
/// macOS-only (AppKit/TextKit 2), so the mobile editor is a plain-text
/// `TextEditor` backed by the same autosave logic.
struct iOSContentView: View {
    @Environment(WorkspaceIndexer.self) private var indexer
    @Environment(\.scenePhase) private var scenePhase

    @State private var editor = EditorModel()
    @State private var search = VaultSearchModel()
    @State private var showImporter = false
    @State private var searchText = ""
    @State private var selectedNoteID: Note.ID?
    @State private var selectedTag: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// On iPhone (collapsed), open straight to the note list rather than the
    /// filter sidebar.
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .content

    private var tags: [String] { search.allTags() }

    private var displayedNotes: [Note] {
        if let selectedTag {
            return search.notesTagged(selectedTag)
        }
        guard !searchText.isEmpty else { return indexer.notes }
        return indexer.notes.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredCompactColumn) {
            sidebar
        } content: {
            noteList
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                indexer.setVault(url)
            }
        }
        .task {
            if indexer.selectedVaultURL == nil {
                indexer.restoreVault()
            }
            await search.refresh(from: indexer.notes)
        }
        .onChange(of: indexer.notes) { _, notes in
            Task { await search.refresh(from: notes) }
        }
        .onChange(of: selectedNoteID) { _, newID in
            let note = indexer.notes.first { $0.id == newID }
            Task { await editor.open(note) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                Task { await editor.flush() }
            }
        }
    }

    // MARK: - Column 1: Navigation sidebar

    @ViewBuilder
    private var sidebar: some View {
        List {
            if indexer.selectedVaultURL == nil {
                Section {
                    Button("Select Vault Folder") { showImporter = true }
                }
            } else {
                Section {
                    filterRow(title: "All Notes", systemImage: "tray.full", isSelected: selectedTag == nil) {
                        selectedTag = nil
                    }
                }

                if !tags.isEmpty {
                    Section("Tags") {
                        ForEach(tags, id: \.self) { tag in
                            filterRow(title: tag, systemImage: "number", isSelected: selectedTag == tag) {
                                selectedTag = tag
                                searchText = ""
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(indexer.selectedVaultURL?.lastPathComponent ?? "HelloNotes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if indexer.selectedVaultURL != nil {
                        Button {
                            if let note = indexer.createNote() {
                                selectedNoteID = note.id
                            }
                        } label: {
                            Label("New Note", systemImage: "square.and.pencil")
                        }
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label("Select Vault Folder", systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private func filterRow(title: String, systemImage: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .foregroundStyle(.primary)
    }

    // MARK: - Column 2: Note list

    @ViewBuilder
    private var noteList: some View {
        Group {
            if indexer.selectedVaultURL == nil {
                ContentUnavailableView {
                    Label("No Vault", systemImage: "folder")
                } description: {
                    Text("Choose a folder of Markdown files to begin.")
                } actions: {
                    Button("Select Vault Folder") { showImporter = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List(displayedNotes, selection: $selectedNoteID) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.title)
                            .font(.headline)
                        Text(note.lastModified, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(note.id)
                }
                .searchable(text: $searchText, prompt: "Search notes")
                .overlay {
                    if indexer.notes.isEmpty {
                        ContentUnavailableView("No Notes", systemImage: "doc.text")
                    }
                }
            }
        }
        .navigationTitle(selectedTag.map { "#\($0)" } ?? "Notes")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Column 3: Editor

    @ViewBuilder
    private var detail: some View {
        if editor.note != nil {
            TextEditor(text: Binding(get: { editor.text }, set: { editor.text = $0 }))
                .font(.body.monospaced())
                .padding(.horizontal, 4)
                .navigationTitle(editor.note?.title ?? "")
                .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView(
                "Select a Note",
                systemImage: "doc.text",
                description: Text("Choose a note from the list, or create a new one.")
            )
        }
    }
}
#endif
