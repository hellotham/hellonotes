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
    @Environment(\.openWindow) private var openWindow

    /// Open notes as tabs, each with its own debounced-autosave editor.
    @State private var tabs = EditorTabs()

    /// The vault's `[[wiki-link]]` / backlink index.
    @State private var linkGraph = LinkGraph()

    /// Tells the editor which wiki-link targets exist (drives clickability).
    @State private var wikiResolver = VaultWikiLinkResolver()

    /// Renders `![[Note]]` transclusions to inline images.
    @State private var embedProvider = VaultEmbedProvider()

    /// Caches note contents for full-text search and "Open Quickly".
    @State private var search = VaultSearchModel()

    /// Watches the vault for external changes (edits, git pulls, Finder ops).
    @State private var fileWatcher: FileWatcher?

    /// Git status + operations for the vault.
    @State private var git = GitService()

    /// Per-vault bookmarked notes.
    @State private var bookmarks = BookmarksStore()

    /// Opt-in background local auto-commit (never auto-pushes).
    @AppStorage("gitAutoCommit") private var autoCommit = false

    /// Daily-notes & templates configuration.
    @AppStorage("dailyNoteFolder") private var dailyNoteFolder = ""
    @AppStorage("dailyDateFormat") private var dailyDateFormat = "yyyy-MM-dd"
    @AppStorage("templatesFolder") private var templatesFolder = "Templates"

    /// Selected note identity (its file URL — stable across re-indexing).
    @State private var selectedNoteID: Note.ID?

    /// Full-text query for the note list.
    @State private var searchText = ""

    /// Whether the ⌘O "Open Quickly" palette is showing.
    @State private var showOpenQuickly = false

    /// Whether the link-graph sheet is showing.
    @State private var showGraph = false
    @State private var showVaultChat = false

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

    /// The vault's hashtags as a nested tree for the sidebar.
    private var tagTree: [TagNode] { search.tagTree() }

    /// Nodes and resolved edges for the link-graph view.
    private var graphData: (nodes: [GraphNode], edges: [GraphEdge]) {
        let notes = indexer.notes
        let indexByURL = Dictionary(uniqueKeysWithValues: notes.enumerated().map { ($1.fileURL, $0) })
        var edges: [GraphEdge] = []
        for (i, note) in notes.enumerated() {
            for target in linkGraph.outgoingByURL[note.fileURL] ?? [] {
                if let destURL = linkGraph.resolve(target), let j = indexByURL[destURL], j != i {
                    edges.append(GraphEdge(from: i, to: j))
                }
            }
        }
        return (notes.map { GraphNode(url: $0.fileURL, label: $0.title) }, edges)
    }

    private var selectedNote: Note? {
        indexer.notes.first { $0.id == selectedNoteID }
    }

    /// The editor for the active tab (the selected note).
    private var activeEditor: EditorModel? {
        tabs.editor(withID: selectedNoteID)
    }

    private var backlinks: [Note] {
        guard let selectedNote else { return [] }
        return linkGraph.backlinks(for: selectedNote, in: indexer.notes)
    }

    private var outgoingLinks: [Note] {
        guard let selectedNote else { return [] }
        return linkGraph.outgoingLinks(for: selectedNote, in: indexer.notes)
    }

    /// The open note's title plus any aliases — the names an unlinked mention
    /// can use to refer to it.
    private var currentNoteNames: [String] {
        guard let selectedNote else { return [] }
        let text = activeEditor?.text ?? search.text(of: selectedNote) ?? ""
        return [selectedNote.title] + MarkdownParsing.aliases(in: text)
    }

    private var unlinkedMentions: [Note] {
        guard let selectedNote else { return [] }
        return search.unlinkedMentions(
            of: selectedNote,
            names: currentNoteNames,
            excluding: Set(backlinks.map(\.fileURL))
        )
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            noteList
        } detail: {
            editorColumn
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
            bookmarks.load(vaultURL: indexer.selectedVaultURL)
            refreshDerived(with: indexer.notes)
        }
        .onChange(of: selectedNoteID) { _, newID in
            // Ensure a tab exists for (and loads) the selected note.
            if let note = indexer.notes.first(where: { $0.id == newID }) {
                Task { await tabs.editor(for: note) }
            }
        }
        .onChange(of: indexer.selectedVaultURL) { _, url in
            if let url {
                startWatching(url)
                git.vaultURL = url
                Task { await git.refreshStatus() }
            }
            bookmarks.load(vaultURL: url)
        }
        .onChange(of: indexer.notes) { _, notes in
            // Note set changed (scan / create / delete): refresh derived data
            // and drop tabs for notes that no longer exist.
            refreshDerived(with: notes)
            tabs.prune(keeping: Set(notes.map(\.id)))
            if selectedNoteID.map({ id in !notes.contains { $0.id == id } }) == true {
                selectedNoteID = tabs.openNotes.last?.id
            }
            Task { await git.refreshStatus() }
        }
        .onChange(of: tabs.totalSavedRevision) { _, _ in
            // A tab saved: refresh links & search index.
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
                Task { await tabs.flushAll() }
            }
        }
        .sheet(isPresented: $showOpenQuickly) {
            OpenQuicklyView(search: search) { selectedNoteID = $0.id }
        }
        .sheet(isPresented: $showGraph) {
            let data = graphData
            GraphView(nodes: data.nodes, edges: data.edges) { url in
                if let note = indexer.notes.first(where: { $0.fileURL == url }) {
                    selectedTag = nil
                    searchText = ""
                    selectedNoteID = note.id
                }
            }
        }
        .sheet(isPresented: $showVaultChat) {
            VaultChatView(notes: indexer.notes, search: search) { note in
                selectedTag = nil
                searchText = ""
                selectedNoteID = note.id
                showVaultChat = false
            }
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

                Button {
                    openTodaysNote()
                } label: {
                    Label("Today's Note", systemImage: "calendar")
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Button {
                    showGraph = true
                } label: {
                    Label("Graph View", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(indexer.notes.isEmpty)

                Button {
                    showVaultChat = true
                } label: {
                    Label("Ask Vault", systemImage: "sparkles.rectangle.stack")
                }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(indexer.notes.isEmpty)

                let bookmarked = bookmarks.bookmarkedNotes(from: indexer.notes)
                if !bookmarked.isEmpty {
                    Divider()
                    Text("BOOKMARKS")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(bookmarked) { note in
                        Button {
                            selectedTag = nil
                            searchText = ""
                            selectedNoteID = note.id
                        } label: {
                            Label(note.title, systemImage: "bookmark.fill")
                                .lineLimit(1)
                                .foregroundStyle(selectedNoteID == note.id ? Color.accentColor : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
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
                            ForEach(tagTree) { node in
                                TagTreeRow(node: node, selectedTag: selectedTag) { tag in
                                    selectedTag = tag
                                    searchText = ""
                                }
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

    // MARK: - Column 3: Editor (with tabs)

    @ViewBuilder
    private var editorColumn: some View {
        VStack(spacing: 0) {
            if tabs.openNotes.count > 1 {
                EditorTabBar(
                    notes: tabs.openNotes,
                    activeID: selectedNoteID,
                    onSelect: { selectedNoteID = $0 },
                    onClose: closeTab
                )
                Divider()
            }

            if let activeEditor {
                NoteEditorView(
                    editor: activeEditor,
                    backlinks: backlinks,
                    outgoingLinks: outgoingLinks,
                    unlinkedMentions: unlinkedMentions,
                    wikiResolver: wikiResolver,
                    embedProvider: embedProvider,
                    git: git,
                    linkCandidates: search.linkTargets(),
                    tagCandidates: search.allTags(),
                    headingProvider: { search.headings(forName: $0) },
                    onOpenWikiLink: openWikiLink,
                    onOpenNote: { selectedNoteID = $0.id },
                    onLinkMention: linkMention
                )
            } else {
                ContentUnavailableView(
                    "No Note Selected",
                    systemImage: "doc.text",
                    description: Text("Select a note from the list, or create a new one.")
                )
            }
        }
    }

    private func closeTab(_ id: Note.ID) {
        Task {
            let next = await tabs.close(id)
            if selectedNoteID == id {
                selectedNoteID = next
            }
        }
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
                    VaultTreeRow(
                        node: node,
                        onDelete: delete,
                        onOpenInNewWindow: { openWindow(value: $0.fileURL) },
                        isBookmarked: bookmarks.isBookmarked,
                        onToggleBookmark: bookmarks.toggle
                    )
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
                Menu {
                    if templateNotes.isEmpty {
                        Text("No templates in \(templatesFolder.isEmpty ? "—" : "\"\(templatesFolder)\"")")
                    } else {
                        ForEach(templateNotes) { template in
                            Button(template.title) { insertTemplate(template) }
                        }
                    }
                } label: {
                    Label("Insert Template", systemImage: "doc.badge.plus")
                }
                .help("Insert a template into the current note")
                .disabled(activeEditor == nil || templateNotes.isEmpty)
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
            bookmarkButton(row.note)
            Button {
                openWindow(value: row.note.fileURL)
            } label: {
                Label("Open in New Window", systemImage: "macwindow.badge.plus")
            }
            Divider()
            Button(role: .destructive) {
                delete(row.note)
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        }
    }

    /// Context-menu toggle for bookmarking a note.
    @ViewBuilder
    private func bookmarkButton(_ note: Note) -> some View {
        let on = bookmarks.isBookmarked(note)
        Button {
            bookmarks.toggle(note)
        } label: {
            Label(on ? "Remove Bookmark" : "Add Bookmark",
                  systemImage: on ? "bookmark.slash" : "bookmark")
        }
    }

    // MARK: - Actions

    /// Keep the derived data (wiki-link resolver, backlink graph, search index)
    /// in sync with the current note set.
    private func refreshDerived(with notes: [Note]) {
        // Titles first so links are clickable immediately; the async rebuild then
        // adds aliases to the resolver so `[[alias]]` resolves too.
        wikiResolver.update(titles: notes.map(\.title))
        embedProvider.update(notes: notes)
        Task {
            await linkGraph.rebuild(from: notes)
            await search.refresh(from: notes)
            wikiResolver.update(titles: Array(linkGraph.resolution.keys))
        }
    }

    /// Start watching the vault directory; external changes trigger a re-index
    /// and reconcile the open note against its on-disk copy.
    private func startWatching(_ url: URL) {
        let watcher = FileWatcher {
            Task { @MainActor in
                indexer.scanVault()
                await tabs.reconcileAll()
            }
        }
        watcher.start(url: url)
        fileWatcher = watcher
    }

    /// Turn the first plain-text mention of the open note (by title) in `note`
    /// into a `[[link]]`, writing the change to disk and re-indexing.
    private func linkMention(_ note: Note) {
        guard let target = selectedNote,
              let text = try? String(contentsOf: note.fileURL, encoding: .utf8),
              let updated = MentionScanner.linkingFirstMention(of: target.title, in: text) else { return }
        try? Data(updated.utf8).write(to: note.fileURL, options: .atomic)
        indexer.scanVault()
    }

    private func newNote() {
        if let note = indexer.createNote() {
            selectedNoteID = note.id
        }
    }

    // MARK: - Daily notes & templates

    /// Open today's daily note, creating it (with a date heading) if needed.
    private func openTodaysNote() {
        let name = TemplateExpander.dailyNoteName(for: .now, format: dailyDateFormat)
        let rel = dailyNoteFolder.isEmpty ? "\(name).md" : "\(dailyNoteFolder)/\(name).md"
        if let note = indexer.note(atRelativePath: rel, creatingWith: "# \(name)\n\n") {
            selectedTag = nil
            searchText = ""
            selectedNoteID = note.id
        }
    }

    /// Notes that live under the configured templates folder.
    private var templateNotes: [Note] {
        guard !templatesFolder.isEmpty, let vault = indexer.selectedVaultURL else { return [] }
        let base = vault.appendingPathComponent(templatesFolder).standardizedFileURL.path + "/"
        return indexer.notes
            .filter { $0.fileURL.standardizedFileURL.path.hasPrefix(base) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Append a template's expanded contents to the active note.
    private func insertTemplate(_ template: Note) {
        guard let editor = activeEditor,
              let raw = try? String(contentsOf: template.fileURL, encoding: .utf8) else { return }
        let expanded = TemplateExpander.expand(raw, title: editor.note?.title ?? "", date: .now)
        editor.text += (editor.text.isEmpty ? "" : "\n") + expanded
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

        // Split `Note#heading`: an empty base is a same-note `[[#heading]]` link.
        let base: String
        let heading: String?
        if let hash = target.firstIndex(of: "#") {
            base = String(target[..<hash])
            let after = String(target[target.index(after: hash)...])
            heading = after.isEmpty ? nil : after
        } else {
            base = target
            heading = nil
        }

        let destination: Note?
        if base.isEmpty {
            destination = selectedNote
        } else if let url = linkGraph.resolve(base),
                  let note = indexer.notes.first(where: { $0.fileURL == url }) {
            destination = note
        } else if let match = indexer.notes.first(where: { $0.title.localizedCaseInsensitiveCompare(base) == .orderedSame }) {
            destination = match
        } else {
            destination = indexer.createNote(title: base)
        }

        guard let destination else { return }
        let switching = selectedNoteID != destination.id
        selectedNoteID = destination.id

        // If the link targets a heading, scroll to it once the note is loaded.
        if let heading {
            Task {
                await tabs.editor(for: destination)
                if switching { try? await Task.sleep(for: .milliseconds(350)) }
                scrollToHeading(heading)
            }
        }
    }

    /// Ask the visible editor to scroll to (and briefly highlight) `title`.
    private func scrollToHeading(_ title: String) {
        NotificationCenter.default.post(name: .hnEditorFindQuery, object: nil, userInfo: ["query": title])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            NotificationCenter.default.post(name: .hnEditorClearHighlights, object: nil)
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
