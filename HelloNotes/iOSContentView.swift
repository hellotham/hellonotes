//
//  iOSContentView.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// The iOS / iPadOS shell. A `NavigationSplitView` adapts automatically: a
/// two-column layout (note list + editor) on iPad and in landscape, collapsing
/// to a push-based stack on iPhone. Shares `Note`, `WorkspaceIndexer`, and
/// `EditorModel` with macOS. MarkdownEngine is macOS-only (AppKit/TextKit 2),
/// so the mobile editor is a plain-text `TextEditor` backed by the same
/// `EditorModel` load / dirty / debounced-autosave logic.
struct iOSContentView: View {
    @Environment(WorkspaceIndexer.self) private var indexer
    @Environment(\.scenePhase) private var scenePhase

    @State private var editor = EditorModel()
    @State private var showImporter = false
    @State private var searchText = ""
    @State private var selectedNoteID: Note.ID?

    private var filteredNotes: [Note] {
        guard !searchText.isEmpty else { return indexer.notes }
        return indexer.notes.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                indexer.setVault(url)
            }
        }
        .task {
            if indexer.selectedVaultURL == nil {
                indexer.restoreVault()
            }
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

    // MARK: - Sidebar (note list)

    @ViewBuilder
    private var sidebar: some View {
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
                List(filteredNotes, selection: $selectedNoteID) { note in
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

    // MARK: - Detail (editor)

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
