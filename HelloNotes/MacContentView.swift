//
//  MacContentView.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(macOS)
import SwiftUI
import AppKit

/// The macOS three-column navigation shell: sidebar, note list, and editor.
struct MacContentView: View {
    @Environment(WorkspaceIndexer.self) private var indexer
    @Environment(\.scenePhase) private var scenePhase

    /// Owns the open document and its debounced autosave.
    @State private var editor = EditorModel()

    /// The vault's `[[wiki-link]]` / backlink index.
    @State private var linkGraph = LinkGraph()

    /// Tells the editor which wiki-link targets exist (drives clickability).
    @State private var wikiResolver = VaultWikiLinkResolver()

    /// Caches note contents for full-text search and "Open Quickly".
    @State private var search = VaultSearchModel()

    /// Watches the vault for external changes (edits, git pulls, Finder ops).
    @State private var fileWatcher: FileWatcher?

    /// Git status + operations for the vault.
    @State private var git = GitService()

    /// Opt-in background local auto-commit (never auto-pushes).
    @AppStorage("gitAutoCommit") private var autoCommit = false

    /// Selected note identity (its file URL — stable across re-indexing).
    @State private var selectedNoteID: Note.ID?

    /// Full-text query for the note list.
    @State private var searchText = ""

    /// Whether the ⌘O "Open Quickly" palette is showing.
    @State private var showOpenQuickly = false

    /// How notes are ordered in the folder tree.
    @State private var sortOrder: VaultSortOrder = .modified

    /// Active tag filter, if any (mutually exclusive with the folder tree).
    @State private var selectedTag: String?

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Full-text hits shown as flat rows while searching.
    private var searchRows: [NoteRow] {
        search.fullTextResults(query: searchText).map {
            NoteRow(note: $0.note, snippet: $0.snippet.isEmpty ? nil : $0.snippet)
        }
    }

    /// Notes matching the active tag filter, as flat rows.
    private var taggedRows: [NoteRow] {
        guard let selectedTag else { return [] }
        return search.notesTagged(selectedTag).map { NoteRow(note: $0, snippet: nil) }
    }

    /// The folder tree for the current vault and sort order.
    private var tree: [VaultTreeNode] {
        guard let vault = indexer.selectedVaultURL else { return [] }
        return VaultTree.build(from: indexer.notes, vaultURL: vault, sort: sortOrder)
    }

    /// Distinct hashtags across the vault.
    private var tags: [String] { search.allTags() }

    private var selectedNote: Note? {
        indexer.notes.first { $0.id == selectedNoteID }
    }

    private var backlinks: [Note] {
        guard let selectedNote else { return [] }
        return linkGraph.backlinks(for: selectedNote, in: indexer.notes)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            noteList
        } detail: {
            NoteEditorView(
                editor: editor,
                backlinks: backlinks,
                wikiResolver: wikiResolver,
                onOpenWikiLink: openWikiLink,
                onOpenNote: { selectedNoteID = $0.id }
            )
        }
        .task {
            // Reopen the last vault on first launch.
            if indexer.selectedVaultURL == nil {
                indexer.restoreVault()
            }
            if let url = indexer.selectedVaultURL {
                startWatching(url)
                git.vaultURL = url
                await git.refreshStatus()
            }
            refreshDerived(with: indexer.notes)
        }
        .onChange(of: selectedNoteID) { _, newID in
            let note = indexer.notes.first { $0.id == newID }
            Task { await editor.open(note) }
        }
        .onChange(of: indexer.selectedVaultURL) { _, url in
            if let url {
                startWatching(url)
                git.vaultURL = url
                Task { await git.refreshStatus() }
            }
        }
        .onChange(of: indexer.notes) { _, notes in
            // Note set changed (scan / create / delete): refresh derived data.
            refreshDerived(with: notes)
            Task { await git.refreshStatus() }
        }
        .onChange(of: editor.savedRevision) { _, _ in
            // A note's contents changed on disk: refresh links & search index.
            refreshDerived(with: indexer.notes)
            Task { await git.refreshStatus() }
            if autoCommit {
                git.scheduleAutoCommit(message: autoCommitMessage)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Safety net beyond the debounce: flush unsaved edits when the app
            // is no longer active (hidden, backgrounded, or quitting).
            if newPhase != .active {
                Task { await editor.flush() }
            }
        }
        .sheet(isPresented: $showOpenQuickly) {
            OpenQuicklyView(search: search) { selectedNoteID = $0.id }
        }
    }

    // MARK: - Column 1: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                indexer.requestVaultAccess()
            } label: {
                Label("Select Vault Folder", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if let vaultURL = indexer.selectedVaultURL {
                Text(vaultURL.lastPathComponent)
                    .font(.headline)
                Text("\(indexer.notes.count) notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    newNote()
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }

                if !tags.isEmpty {
                    Divider()

                    Button {
                        selectedTag = nil
                    } label: {
                        Label("All Notes", systemImage: "tray.full")
                            .fontWeight(selectedTag == nil ? .semibold : .regular)
                    }
                    .buttonStyle(.plain)

                    Text("TAGS")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(tags, id: \.self) { tag in
                                Button {
                                    selectedTag = tag
                                    searchText = ""
                                } label: {
                                    Label("#\(tag)", systemImage: "number")
                                        .foregroundStyle(selectedTag == tag ? Color.accentColor : Color.primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            Spacer()

            if indexer.selectedVaultURL != nil {
                gitSection
            }
        }
        .padding()
        .navigationTitle("HelloNotes")
        .navigationSplitViewColumnWidth(min: 200, ideal: 220)
    }

    // MARK: - Git section

    @ViewBuilder
    private var gitSection: some View {
        Divider()

        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
            Text("GIT").font(.caption2).foregroundStyle(.secondary)
            Spacer()
            if git.isBusy { ProgressView().controlSize(.small) }
        }

        if !git.status.isRepository {
            Text("Not a Git repository")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task { await git.initializeRepository() }
            } label: {
                Label("Initialize Repository", systemImage: "plus.circle")
            }
            .disabled(git.isBusy)
        } else {
            HStack {
                Label(git.status.branch ?? "—", systemImage: "point.3.filled.connected.trianglepath.dotted")
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Text(git.status.isClean ? "Clean" : "\(git.status.changeCount) changed")
                    .font(.caption)
                    .foregroundStyle(git.status.isClean ? Color.secondary : Color.orange)
            }

            HStack {
                Button {
                    Task { await git.commitAll(message: autoCommitMessage) }
                } label: {
                    Label("Commit", systemImage: "checkmark.seal")
                }
                .disabled(git.status.isClean || git.isBusy)

                Menu {
                    Button("Push") { Task { await git.push() } }
                    Button("Fetch") { Task { await git.fetch() } }
                } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(git.isBusy)
                .fixedSize()
            }

            Toggle("Auto-commit", isOn: $autoCommit)
                .font(.caption)
                .toggleStyle(.checkbox)

            if let error = git.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if let message = git.lastMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var autoCommitMessage: String {
        "Update notes — \(Date.now.formatted(date: .abbreviated, time: .shortened))"
    }

    // MARK: - Column 2: Note list

    private var noteList: some View {
        List(selection: $selectedNoteID) {
            if isSearching {
                ForEach(searchRows) { flatRow($0) }
            } else if selectedTag != nil {
                ForEach(taggedRows) { flatRow($0) }
            } else {
                ForEach(tree) { node in
                    VaultTreeRow(node: node, onDelete: delete)
                }
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search notes & contents")
        .navigationTitle(selectedTag.map { "#\($0)" } ?? "Notes")
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Sort By", selection: $sortOrder) {
                        ForEach(VaultSortOrder.allCases) { order in
                            Label(order.rawValue, systemImage: order.systemImage).tag(order)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .disabled(indexer.notes.isEmpty || isSearching || selectedTag != nil)
            }
            ToolbarItem {
                Button {
                    showOpenQuickly = true
                } label: {
                    Label("Open Quickly", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("o", modifiers: .command)
                .help("Open Quickly (⌘O)")
                .disabled(indexer.notes.isEmpty)
            }
        }
        .overlay {
            if indexer.notes.isEmpty {
                ContentUnavailableView(
                    "No Notes",
                    systemImage: "doc.text",
                    description: Text("Select a vault folder to index your Markdown files.")
                )
            } else if isSearching && searchRows.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    /// A flat (non-tree) note row used for search results and tag filtering.
    private func flatRow(_ row: NoteRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.note.title)
                .font(.headline)
            if let snippet = row.snippet {
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text(row.note.lastModified, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tag(row.note.id)
        .contextMenu {
            Button(role: .destructive) {
                delete(row.note)
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        }
    }

    // MARK: - Actions

    /// Keep the derived data (wiki-link resolver, backlink graph, search index)
    /// in sync with the current note set.
    private func refreshDerived(with notes: [Note]) {
        wikiResolver.update(titles: notes.map(\.title))
        Task {
            await linkGraph.rebuild(from: notes)
            await search.refresh(from: notes)
        }
    }

    /// Start watching the vault directory; external changes trigger a re-index
    /// and reconcile the open note against its on-disk copy.
    private func startWatching(_ url: URL) {
        let watcher = FileWatcher {
            Task { @MainActor in
                indexer.scanVault()
                await editor.reconcileWithDisk()
            }
        }
        watcher.start(url: url)
        fileWatcher = watcher
    }

    private func newNote() {
        if let note = indexer.createNote() {
            selectedNoteID = note.id
        }
    }

    private func delete(_ note: Note) {
        let wasSelected = selectedNoteID == note.id
        indexer.deleteNote(note)
        if wasSelected {
            selectedNoteID = nil
        }
    }

    /// Handle a clicked link. External URLs open in the default app; otherwise
    /// the target is treated as a note title — navigate to the matching note,
    /// or create it if it doesn't exist yet (create-on-miss).
    private func openWikiLink(_ target: String) {
        let webSchemes: Set<String> = ["http", "https", "mailto", "file"]
        if let url = URL(string: target),
           let scheme = url.scheme?.lowercased(),
           webSchemes.contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }

        if let match = indexer.notes.first(where: { $0.title.localizedCaseInsensitiveCompare(target) == .orderedSame }) {
            selectedNoteID = match.id
        } else if let created = indexer.createNote(title: target) {
            selectedNoteID = created.id
        }
    }
}

/// A note list row: the note plus an optional search snippet.
private struct NoteRow: Identifiable {
    let note: Note
    let snippet: String?
    var id: Note.ID { note.id }
}
#endif
