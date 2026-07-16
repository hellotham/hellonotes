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
/// The note list shows every open collection in the library; the editor and Git
/// panel act on the focused collection (the one owning the selected note).
struct MacContentView: View {
    @Environment(Library.self) private var library
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    /// The launch splash shows once per process, from the first main window.
    @MainActor private static var didShowSplash = false

    /// Open notes as tabs, each with its own debounced-autosave editor. Tabs may
    /// hold notes from any collection in the library.
    @State private var tabs = EditorTabs()

    /// Git commit identity + hosting-service accounts (GitHub, GitLab, …).
    @State private var gitAccounts = GitAccountsStore()
    @State private var showGitSettings = false
    @State private var showClone = false

    /// The "open" launcher and its backing stores (recents + saved libraries).
    @State private var recents = RecentsStore()
    @State private var libraries = LibrariesStore()
    @State private var showLauncher = false
    @State private var showNewRepo = false

    /// Shared LLM configuration (the Assistant and Ask Library windows own
    /// their models; the editor's intelligence features read this directly).
    @Environment(LLMSettings.self) private var llmSettings

    /// Opt-in background local auto-commit (never auto-pushes).
    @AppStorage("gitAutoCommit") private var autoCommit = false

    /// Daily-notes & templates configuration.
    @AppStorage("dailyNoteFolder") private var dailyNoteFolder = ""
    @AppStorage("dailyDateFormat") private var dailyDateFormat = "yyyy-MM-dd"
    @AppStorage("templatesFolder") private var templatesFolder = "Templates"

    /// Selected note identity (its file URL — stable across re-indexing).
    @State private var selectedNoteID: Note.ID?

    /// Full-text query for the note list (searches across every collection).
    @State private var searchText = ""

    /// Debounced full-text results, computed off the render path so typing in
    /// the search field doesn't scan every note's body on each keystroke.
    @State private var searchResults: [SearchGroup] = []
    @State private var searchResultsRevision = 0
    @State private var searchTask: Task<Void, Never>?
    @State private var isSearchInFlight = false

    /// System Spotlight-index query for matches inside attachments (PDFs etc.).
    @State private var spotlight = SpotlightSearch()

    /// Cached note-list outline, rebuilt only when its inputs change (see
    /// `outlineInputsKey`) rather than re-derived (O(N log N)) every render.
    @State private var cachedRoots: [NoteOutlineItem] = []
    @State private var cachedSignature = ""

    /// References panel data, computed off-main and keyed on `referencesKey`.
    @State private var references = ReferencesData()

    /// Debounces the per-save git status refresh.
    @State private var gitStatusTask: Task<Void, Never>?

    @State private var showOpenQuickly = false

    /// Rename-note prompt state (set via the context menu or the Note menu).
    @State private var renameTarget: Note?
    @State private var renameTitle = ""

    /// New-folder prompt state (set via the note-list context menu).
    @State private var newFolderCollection: Collection?
    @State private var newFolderParent: URL?
    @State private var newFolderName = ""

    /// How notes are ordered in the folder tree.
    @State private var sortOrder: SortOrder = .modified

    /// Active tag filter, if any (within the focused collection).
    @State private var selectedTag: String?

    // MARK: - Focused / selection helpers

    /// The focused collection — drives the editor, Git panel, and note actions.
    private var focused: Collection? { library.focused }

    /// The selected note, wherever it lives across the open collections.
    private var selectedNote: Note? {
        library.note(id: selectedNoteID)
    }

    /// The collection that owns the current selection (falls back to focused).
    private var editorCollection: Collection? {
        if let note = selectedNote { return library.collection(containing: note.fileURL) ?? focused }
        return focused
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The editor for the active tab (the selected note).
    private var activeEditor: EditorModel? {
        tabs.editor(withID: selectedNoteID)
    }

    /// The attachment file the current selection points at, if any.
    private var selectedAttachment: CollectionFile? {
        library.collections.lazy.compactMap { c in c.attachments.first { $0.url == selectedNoteID } }.first
    }

    // MARK: - Note list rows

    /// A collection paired with its full-text search hits (for grouped results).
    /// `fileRows` are attachments (PDFs, documents, …) whose *content* matched,
    /// found via the system Spotlight index rather than the app's own index.
    private struct SearchGroup: Identifiable {
        let collection: Collection
        let rows: [NoteRow]
        var fileRows: [CollectionFile] = []
        var id: Collection.ID { collection.id }
    }

    /// Recompute the debounced search results. Runs at most once per ~200 ms of
    /// typing (not per keystroke), and computes the groups once (they used to be
    /// recomputed twice per body — for the rows and the empty-state check).
    private func scheduleSearch(_ raw: String) {
        searchTask?.cancel()
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            searchResultsRevision &+= 1
            isSearchInFlight = false
            rebuildOutline()
            return
        }
        isSearchInFlight = true
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            searchResults = library.collections.compactMap { collection in
                let rows = collection.search.fullTextResults(query: query).map {
                    NoteRow(note: $0.note, snippet: $0.snippet.isEmpty ? nil : $0.snippet)
                }
                return rows.isEmpty ? nil : SearchGroup(collection: collection, rows: rows)
            }
            searchResultsRevision &+= 1
            isSearchInFlight = false
            rebuildOutline()   // reflect results immediately, independent of key timing

            // Second wave: matches *inside attachments* (PDFs, documents, …) via
            // the system Spotlight index — content macOS already indexed for us.
            let hits = await spotlight.search(query, in: library.collections.map(\.rootURL))
            guard !Task.isCancelled, !hits.isEmpty else { return }
            let hitPaths = Set(hits.map { $0.standardizedFileURL.path })
            var merged: [SearchGroup] = []
            for collection in library.collections {
                let files = collection.attachments.filter { hitPaths.contains($0.url.standardizedFileURL.path) }
                let rows = searchResults.first { $0.id == collection.id }?.rows ?? []
                guard !rows.isEmpty || !files.isEmpty else { continue }
                merged.append(SearchGroup(collection: collection, rows: rows, fileRows: files))
            }
            searchResults = merged
            searchResultsRevision &+= 1
            rebuildOutline()
        }
    }

    /// Notes matching the active tag filter in the focused collection, flat rows.
    private var taggedRows: [NoteRow] {
        guard let selectedTag, let focused else { return [] }
        return focused.search.notesTagged(selectedTag).map { NoteRow(note: $0, snippet: nil) }
    }

    /// The folder tree for `collection` and the current sort order.
    private func tree(for collection: Collection) -> [CollectionTreeNode] {
        CollectionTree.build(from: collection.notes, attachments: collection.attachments,
                             folders: collection.folders, rootURL: collection.rootURL, sort: sortOrder)
    }

    // MARK: - Editor derived data (for the selection's collection)

    private var currentNoteNames: [String] {
        guard let selectedNote, let c = editorCollection else { return [] }
        // Cached aliases from the index — available immediately from the
        // persistent cache, even before note text streams in.
        return [selectedNote.title] + c.search.aliases(of: selectedNote.fileURL)
    }

    /// Backlinks / outgoing links / unlinked mentions for the references panel.
    private struct ReferencesData: Equatable {
        var backlinks: [Note] = []
        var outgoingLinks: [Note] = []
        var unlinkedMentions: [Note] = []
    }

    /// Changes when the selection or the collection's index changes — the key
    /// for recomputing `references`.
    private var referencesKey: String {
        "\(selectedNoteID?.path ?? "")|\(editorCollection?.derivedRevision ?? 0)"
    }

    /// Recompute the references panel off the main thread. The unlinked-mention
    /// scan is O(N notes); doing it in the view body made *selecting* a note (or
    /// arrow-keying through the list) run that scan on the main actor each time.
    private func computeReferences() async {
        guard let note = selectedNote, let c = editorCollection else {
            references = ReferencesData(); return
        }
        let back = c.linkGraph.backlinks(for: note, in: c.notes)
        let out = c.linkGraph.outgoingLinks(for: note, in: c.notes)
        let names = currentNoteNames
        let corpus = c.search.mentionCorpus()
        let excluded = Set(back.map(\.fileURL)).union([note.fileURL])
        let mentions = await Task.detached(priority: .userInitiated) { () -> [Note] in
            corpus.compactMap { candidate, text in
                guard !excluded.contains(candidate.fileURL),
                      MentionScanner.containsMention(of: names, in: text) else { return nil }
                return candidate
            }
        }.value
        guard !Task.isCancelled else { return }
        references = ReferencesData(backlinks: back, outgoingLinks: out, unlinkedMentions: mentions)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            noteList
        } detail: {
            editorColumn
        }
        // A floor under the three-column layout, so the editor's status bar
        // and note list never collapse into vertical text wrapping.
        .frame(minWidth: 860, minHeight: 480)
        .task {
            if !Self.didShowSplash {
                Self.didShowSplash = true
                SplashWindow.show(autoDismiss: true)
            }
            library.onExternalChange = { @MainActor in
                Task { await tabs.reconcileAll() }
                revalidateSelection()
            }
            // A note's autosave marks the write as the collection's own (so its
            // file watcher ignores it) and refreshes that collection's index
            // without a full re-scan — keeping typing off the vault-read path.
            tabs.onNoteSaved = { @MainActor url, text in
                library.collection(containing: url)?.noteDidSave(url, text: text)
            }
            library.onOpened = { recents.record($0) }
            if library.isEmpty {
                await library.restore()
                // First run with nothing to restore: offer the launcher.
                if library.isEmpty { showLauncher = true }
            }
        }
        .onChange(of: selectedNoteID) { _, newID in
            if let note = library.allNotes.first(where: { $0.id == newID }) {
                library.focusCollection(containing: note.fileURL)
                Task { await tabs.editor(for: note) }
            }
        }
        .onChange(of: library.focusedID) { _, _ in
            selectedTag = nil
        }
        .onChange(of: library.pendingOpenNoteID) { _, id in
            // Another window (graph, mind map, assistant, chat) asked us to
            // show a note.
            guard let id else { return }
            selectedTag = nil
            searchText = ""
            selectedNoteID = id
            library.pendingOpenNoteID = nil
        }
        .onChange(of: library.allNotes) { _, notes in
            tabs.prune(keeping: Set(notes.map(\.id)))
            revalidateSelection()
        }
        .onChange(of: searchText) { _, q in scheduleSearch(q) }
        // Rebuild the (cached) note-list outline only when its structural inputs
        // change — not on every unrelated body re-eval (selection, git, accent).
        .onChange(of: outlineInputsKey, initial: true) { _, _ in rebuildOutline() }
        // Recompute the references panel off-main when the selection or index
        // changes — never inline in the body (would scan all notes on selection).
        .task(id: referencesKey) { await computeReferences() }
        .onChange(of: tabs.totalSavedRevision) { _, _ in
            guard let c = editorCollection else { return }
            if autoCommit { c.git.scheduleAutoCommit(message: autoCommitMessage) }
            // Debounce the status refresh — it fires on every autosave, so a
            // burst of edits shouldn't spawn a git status walk per keystroke.
            gitStatusTask?.cancel()
            gitStatusTask = Task {
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                await c.git.refreshStatus()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                Task { await tabs.flushAll() }
            }
        }
        .sheet(isPresented: $showOpenQuickly) {
            if let c = focused {
                OpenQuicklyView(search: c.search) { selectedNoteID = $0.id }
            }
        }
        .sheet(isPresented: $showGitSettings) {
            if let c = focused {
                GitSettingsView(store: gitAccounts, git: c.git)
            }
        }
        .sheet(isPresented: $showClone) {
            CloneRepositoryView(store: gitAccounts, git: focused?.git ?? GitService()) { url in
                Task { await library.open(url: url) }
            }
        }
        .sheet(isPresented: $showLauncher) {
            LauncherView(
                recents: recents,
                libraries: libraries,
                openCollectionURLs: library.collections.map(\.rootURL),
                onOpenURL: { url in Task { await library.open(url: url) } },
                onOpenLibrary: { lib in
                    let urls = libraries.urls(for: lib)
                    Task { await library.openLibrary(urls) }
                },
                onSaveLibrary: { name in libraries.save(name: name, urls: library.collections.map(\.rootURL)) },
                onOpenCollection: { library.requestOpenCollections() },
                onOpenObsidian: { openObsidianVault() },
                onClone: { showClone = true },
                onNewRepository: { showNewRepo = true }
            )
        }
        .sheet(isPresented: $showNewRepo) {
            NewRepositoryView(store: gitAccounts) { url in
                Task { await library.open(url: url) }
            }
        }
        .alert("Rename Note",
               isPresented: Binding(get: { renameTarget != nil },
                                    set: { if !$0 { renameTarget = nil } })) {
            TextField("Title", text: $renameTitle)
            Button("Rename") { performRename() }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text("Wiki links to this note across the collection are updated too.")
        }
        .alert("New Folder",
               isPresented: Binding(get: { newFolderCollection != nil },
                                    set: { if !$0 { newFolderCollection = nil } })) {
            TextField("Name", text: $newFolderName, prompt: Text("New Folder"))
            Button("Create") {
                let collection = newFolderCollection
                let name = newFolderName.isEmpty ? "New Folder" : newFolderName
                let parent = newFolderParent
                newFolderCollection = nil
                Task { await collection?.createFolder(named: name, in: parent) }
            }
            Button("Cancel", role: .cancel) { newFolderCollection = nil }
        }
        .focusedSceneValue(\.appActions, appActions)
        .background {
            // ⌘W → close the active editor tab, but only while several tabs
            // are open. A window-level shortcut wins over the File > Close
            // menu item; when this button isn't present, ⌘W falls through to
            // Close and dismisses the window — the Safari/Xcode convention.
            if tabs.openNotes.count > 1, let id = selectedNoteID, tabs.editor(withID: id) != nil {
                Button("") { closeTab(id) }
                    .keyboardShortcut("w", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Move a note/attachment into `folder` (drag & drop). Flushes pending
    /// edits first — the file is about to change paths — then reselects the
    /// item at its new URL.
    private func moveItem(at source: URL, into folder: URL) {
        guard let c = library.collection(containing: source) else { return }
        let wasSelected = selectedNoteID == source
        Task {
            await tabs.flushAll()
            if let destination = await c.moveItem(at: source, into: folder), wasSelected {
                selectedNoteID = destination
            }
        }
    }

    // MARK: - Menu-bar actions (File / Note / View commands)

    /// The command surface published to the menu bar for this window.
    private var appActions: AppActions {
        AppActions(
            canNewNote: focused != nil,
            newNote: { newNote() },
            todaysNote: { openTodaysNote() },
            openLauncher: { showLauncher = true },
            canOpenQuickly: !(focused?.notes.isEmpty ?? true),
            openQuickly: { showOpenQuickly = true },
            canGraph: !(focused?.notes.isEmpty ?? true),
            graphView: { openWindow(id: "graph") },
            canAsk: !library.allNotes.isEmpty,
            askLibrary: { openWindow(id: "askLibrary") },
            assistant: { openWindow(id: "assistant") },
            canCloseTab: tabs.openNotes.count > 1 && tabs.editor(withID: selectedNoteID) != nil,
            closeTab: { if let id = selectedNoteID { closeTab(id) } },
            format: selectedNote.map { note in
                { action in
                    NotificationCenter.default.post(
                        name: .hnFormat(action.kind, documentId: note.fileURL.path),
                        object: nil, userInfo: action.userInfo)
                }
            },
            note: selectedNote.map { note in
                NoteMenuActions(
                    isBookmarked: library.collection(containing: note.fileURL)?.bookmarks.isBookmarked(note) ?? false,
                    rename: { beginRename(note) },
                    duplicate: {
                        let c = library.collection(containing: note.fileURL)
                        Task {
                            if let copy = await c?.duplicateNote(note) { selectedNoteID = copy.id }
                        }
                    },
                    toggleBookmark: { library.collection(containing: note.fileURL)?.bookmarks.toggle(note) },
                    copyWikiLink: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("[[\(note.title)]]", forType: .string)
                    },
                    revealInFinder: { NSWorkspace.shared.activateFileViewerSelecting([note.fileURL]) },
                    openInNewWindow: { openWindow(value: NoteRef(note.fileURL)) },
                    exportHTML: {
                        if let editor = activeEditor {
                            EditorExport.exportHTML(markdown: editor.text, title: note.title)
                        }
                    },
                    exportPDF: {
                        if let editor = activeEditor {
                            EditorExport.exportPDF(markdown: editor.text, title: note.title)
                        }
                    },
                    moveToTrash: {
                        if let c = library.collection(containing: note.fileURL) { delete(note, in: c) }
                    }
                )
            },
            rescan: focused.map { collection in
                { collection.rescan() }
            }
        )
    }

    /// Open the rename prompt pre-filled with the note's current title.
    private func beginRename(_ note: Note) {
        renameTitle = note.title
        renameTarget = note
    }

    /// Flush pending edits (the file is about to move), rename, and reselect.
    private func performRename() {
        guard let note = renameTarget,
              let c = library.collection(containing: note.fileURL) else { renameTarget = nil; return }
        let title = renameTitle
        renameTarget = nil
        Task {
            await tabs.flushAll()
            if let renamed = await c.renameNote(note, to: title) {
                selectedNoteID = renamed.id
            }
        }
    }

    /// Drop the selection if the note (or attachment) it pointed at is gone.
    private func revalidateSelection() {
        let stillValid = selectedNoteID.map { id in
            library.allNotes.contains { $0.id == id }
                || library.collections.contains { $0.attachments.contains { $0.url == id } }
        } ?? true
        if !stillValid { selectedNoteID = tabs.openNotes.last?.id }
    }

    /// Browse iCloud Drive for Obsidian vaults. The open panel (Powerbox) grants
    /// access to the chosen folders; the panel opens in Obsidian's iCloud folder
    /// so vaults are one click away. Each selected folder that is an Obsidian
    /// vault (has a `.obsidian` config) — or contains vaults — opens as a
    /// collection; a plain folder opens as-is. Multi-select opens several at once.
    private func openObsidianVault() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.message = "Choose your Obsidian vault folder(s) in iCloud Drive."
        panel.directoryURL = ObsidianVault.defaultBrowseDirectory

        guard panel.runModal() == .OK else { return }

        var toOpen: [URL] = []
        for url in panel.urls {
            let scoped = url.startAccessingSecurityScopedResource()
            let found = ObsidianVault.discoverVaults(in: url)
            if scoped { url.stopAccessingSecurityScopedResource() }
            toOpen += found.isEmpty ? [url] : found   // fall back to the folder itself
        }
        Task { await library.open(urls: toOpen) }
    }

    // MARK: - Column 1: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                showLauncher = true
            } label: {
                Label("Open…", systemImage: "books.vertical")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help("Recents, Obsidian vaults, libraries, clone, or a new repository")

            if let focused {
                Text(focused.name)
                    .font(.headline)
                Text("\(focused.notes.count) notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button { newNote() } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }

                Button { openTodaysNote() } label: {
                    Label("Today's Note", systemImage: "calendar")
                }

                Button { openWindow(id: "graph") } label: {
                    Label("Graph View", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .disabled(focused.notes.isEmpty)

                Button { openWindow(id: "askLibrary") } label: {
                    Label("Ask Library", systemImage: "sparkles.rectangle.stack")
                }
                .disabled(library.allNotes.isEmpty)

                Button { openWindow(id: "assistant") } label: {
                    Label("Assistant", systemImage: "sparkles")
                }

                let bookmarked = focused.bookmarks.bookmarkedNotes(from: focused.notes)
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
                                .foregroundStyle(selectedNoteID == note.id
                                    ? AnyShapeStyle(appearance.accentText ?? Color.accentColor)
                                    : AnyShapeStyle(.primary))
                        }
                        .buttonStyle(.plain)
                    }
                }

                let tags = focused.search.allTags()
                if !tags.isEmpty {
                    Divider()

                    Button { selectedTag = nil } label: {
                        Label("All Notes", systemImage: "tray.full")
                            .fontWeight(selectedTag == nil ? .semibold : .regular)
                    }
                    .buttonStyle(.plain)

                    Text("TAGS")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(focused.search.tagTree()) { node in
                                TagTreeRow(node: node, selectedTag: selectedTag,
                                           selectedColor: appearance.accentText ?? .accentColor) { tag in
                                    selectedTag = tag
                                    searchText = ""
                                }
                            }
                        }
                    }
                }
            }

            Spacer()

            if focused != nil {
                gitSection
            }
        }
        .padding()
        .navigationTitle("HelloNotes")
        .navigationSplitViewColumnWidth(min: 200, ideal: 220)
    }

    // MARK: - Git section (focused collection)

    @ViewBuilder
    private var gitSection: some View {
        if let git = focused?.git {
            Divider()

            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                Text("GIT").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if git.isBusy { ProgressView().controlSize(.small) }
                Button { showGitSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Git identity & accounts")
                .accessibilityLabel("Git identity & accounts")
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

                    if git.status.hasRemote {
                        Menu {
                            Button("Push") { Task { await git.push() } }
                            Button("Fetch") { Task { await git.fetch() } }
                        } label: {
                            Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(git.isBusy)
                        .fixedSize()
                    } else {
                        Button { showGitSettings = true } label: {
                            Label("Connect Remote", systemImage: "link.badge.plus")
                        }
                        .fixedSize()
                    }
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

            if let attachment = selectedAttachment {
                FileViewerView(file: attachment)
            } else if let activeEditor, let c = editorCollection {
                NoteEditorView(
                    editor: activeEditor,
                    backlinks: references.backlinks,
                    outgoingLinks: references.outgoingLinks,
                    unlinkedMentions: references.unlinkedMentions,
                    wikiResolver: c.wikiResolver,
                    embedProvider: c.embedProvider,
                    git: c.git,
                    linkCandidates: c.search.linkTargets(),
                    tagCandidates: c.search.allTags(),
                    headingProvider: { c.search.headings(forName: $0) },
                    onOpenWikiLink: openWikiLink,
                    onOpenNote: { selectedNoteID = $0.id },
                    onLinkMention: linkMention,
                    onShowMindMap: {
                        if let url = selectedNote?.fileURL { openWindow(value: MindMapRef(url)) }
                    }
                )
            } else {
                ContentUnavailableView(
                    "No Note Selected",
                    systemImage: "doc.text",
                    description: Text("Select a note from the list, or create a new one.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if focused != nil {
                    Divider()
                    noNoteStatusBar
                }
            }
        }
    }

    /// Bottom status bar shown when a collection is open but no note is selected.
    private var noNoteStatusBar: some View {
        HStack(spacing: 8) {
            if let focused {
                Label(focused.name, systemImage: "folder").foregroundStyle(.secondary)
                Divider().frame(height: 11)
                Text("\(focused.notes.count) note\(focused.notes.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                let tagCount = focused.search.allTags().count
                if tagCount > 0 {
                    Divider().frame(height: 11)
                    Text("\(tagCount) tag\(tagCount == 1 ? "" : "s")").foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            statusBarButton("New note", "square.and.pencil") { newNote() }
            statusBarButton("Today's note", "calendar") { openTodaysNote() }
            statusBarButton("Graph view", "point.3.connected.trianglepath.dotted") { openWindow(id: "graph") }
                .disabled(focused?.notes.isEmpty ?? true)
            statusBarButton("Ask your library", "sparkles.rectangle.stack") { openWindow(id: "askLibrary") }
                .disabled(library.allNotes.isEmpty)
            statusBarButton("Assistant", "sparkles") { openWindow(id: "assistant") }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func statusBarButton(_ help: String, _ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).frame(width: 22, height: 18)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }

    private func closeTab(_ id: Note.ID) {
        Task {
            let next = await tabs.close(id)
            if selectedNoteID == id {
                selectedNoteID = next
            }
        }
    }

    // MARK: - Column 2: Note list (all collections)

    private var noteList: some View {
        NoteOutlineList(
            roots: cachedRoots,
            signature: cachedSignature,
            selection: $selectedNoteID,
            focusedCollectionID: library.focusedID,
            accent: appearance.resolvedAccent,
            fontScale: appearance.textScale,
            isBookmarked: { note in
                library.collection(containing: note.fileURL)?.bookmarks.isBookmarked(note) ?? false
            },
            onToggleBookmark: { note in
                library.collection(containing: note.fileURL)?.bookmarks.toggle(note)
            },
            onDelete: { note in
                if let c = library.collection(containing: note.fileURL) { delete(note, in: c) }
            },
            onOpenInNewWindow: { openWindow(value: NoteRef($0.fileURL)) },
            onCloseCollection: { collection in
                if selectedNote.map({ library.collection(containing: $0.fileURL)?.id == collection.id }) ?? false {
                    selectedNoteID = nil
                }
                library.close(collection)
            },
            onFocusCollection: { library.focus($0) },
            onRename: { beginRename($0) },
            onDuplicate: { note in
                let c = library.collection(containing: note.fileURL)
                Task { if let copy = await c?.duplicateNote(note) { selectedNoteID = copy.id } }
            },
            onNewNote: { collection, folderID in
                // A folder id is the folder's absolute path (collection id + relative path).
                if let folderID, let c = library.collections.first(where: { folderID.hasPrefix($0.id) }) {
                    Task {
                        if let note = await c.createNote(in: URL(fileURLWithPath: folderID, isDirectory: true)) {
                            selectedNoteID = note.id
                        }
                    }
                } else if let c = collection ?? focused {
                    Task { if let note = await c.createNote() { selectedNoteID = note.id } }
                }
            },
            onNewFolder: { collection, folderID in
                if let folderID, let c = library.collections.first(where: { folderID.hasPrefix($0.id) }) {
                    newFolderParent = URL(fileURLWithPath: folderID, isDirectory: true)
                    newFolderCollection = c
                } else if let c = collection ?? focused {
                    newFolderParent = nil
                    newFolderCollection = c
                }
                newFolderName = ""
            },
            onDeleteFolder: { folderID in
                if let c = library.collections.first(where: { folderID.hasPrefix($0.id) }) {
                    Task { await c.deleteFolder(at: URL(fileURLWithPath: folderID, isDirectory: true)) }
                }
            },
            onMoveItem: { source, folder in moveItem(at: source, into: folder) }
        )
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search all collections")
        .navigationTitle(selectedTag.map { "#\($0)" } ?? "Notes")
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Sort By", selection: $sortOrder) {
                        ForEach(SortOrder.allCases) { order in
                            Label(order.rawValue, systemImage: order.systemImage).tag(order)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .disabled(library.isEmpty || isSearching || selectedTag != nil)
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
                .help("Open Quickly (⇧⌘O)")
                .disabled(focused?.notes.isEmpty ?? true)
            }
        }
        .overlay {
            if library.isEmpty {
                ContentUnavailableView {
                    Label("No Collections", systemImage: "folder")
                } description: {
                    Text("Open a collection, an Obsidian vault, or a saved library to begin.")
                } actions: {
                    Button("Open…") { showLauncher = true }
                        .buttonStyle(.borderedProminent)
                }
            } else if isSearching && searchResults.isEmpty && !isSearchInFlight {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    // MARK: - Outline items (NSOutlineView data)

    /// The outline tree for the current mode: collections as group rows, with
    /// their folder trees (or flat search / tag results) as children.
    private func buildOutlineRoots() -> [NoteOutlineItem] {
        if isSearching {
            return searchResults.map { group in
                NoteOutlineItem(id: group.collection.id, kind: .collection(group.collection),
                                children: group.rows.map {
                    NoteOutlineItem(id: $0.note.fileURL.path, kind: .note($0.note, snippet: $0.snippet))
                } + group.fileRows.map {
                    NoteOutlineItem(id: $0.url.path, kind: .file($0))
                })
            }
        } else if selectedTag != nil, let focused {
            return [NoteOutlineItem(id: focused.id, kind: .collection(focused),
                                    children: taggedRows.map {
                NoteOutlineItem(id: $0.note.fileURL.path, kind: .note($0.note, snippet: nil))
            })]
        } else {
            return library.collections.map { collection in
                NoteOutlineItem(id: collection.id, kind: .collection(collection),
                                children: outlineItems(from: tree(for: collection), prefix: collection.id))
            }
        }
    }

    /// `prefix` (the owning collection's id) namespaces folder ids so equal
    /// relative paths in different collections stay distinct — and lets folder
    /// actions (New Note Here) recover the collection + folder from the id.
    private func outlineItems(from nodes: [CollectionTreeNode], prefix: String) -> [NoteOutlineItem] {
        nodes.map { node in
            if let note = node.note {
                return NoteOutlineItem(id: node.id, kind: .note(note, snippet: nil))
            } else if let file = node.file {
                return NoteOutlineItem(id: node.id, kind: .file(file))
            } else {
                return NoteOutlineItem(id: prefix + node.id, kind: .folder(node.name),
                                       children: outlineItems(from: node.children ?? [], prefix: prefix))
            }
        }
    }

    /// A cheap fingerprint of everything the outline depends on — collection
    /// membership + each collection's structural `revision` + sort/mode/search.
    /// O(collections), not O(notes): computed every render, but the expensive
    /// `buildOutlineRoots()` only re-runs when this key actually changes.
    private var outlineInputsKey: String {
        let mode: String
        if isSearching {
            mode = "s:\(searchResultsRevision)"
        } else if let selectedTag {
            mode = "t:\(selectedTag):\(focused?.id ?? "")"
        } else {
            mode = "n:" + library.collections
                .map { "\($0.id)#\($0.revision)" }
                .joined(separator: ",")
        }
        return "\(sortOrder.rawValue)|\(library.focusedID ?? "")|\(appearance.textScale)|\(mode)"
    }

    /// Rebuild and cache the outline tree + its signature. Called only when
    /// `outlineInputsKey` changes.
    private func rebuildOutline() {
        cachedRoots = buildOutlineRoots()
        cachedSignature = outlineInputsKey
    }

    // MARK: - Actions

    /// Turn the first plain-text mention of the open note (by title) in `note`
    /// into a `[[link]]`, writing the change to disk and re-indexing.
    private func linkMention(_ note: Note) {
        guard let target = selectedNote, let c = editorCollection,
              let text = try? String(contentsOf: note.fileURL, encoding: .utf8),
              let updated = MentionScanner.linkingFirstMention(of: target.title, in: text) else { return }
        try? Data(updated.utf8).write(to: note.fileURL, options: .atomic)
        // The note set is unchanged (only one note's content), so no re-scan:
        // patch the index incrementally and suppress the watcher for our write.
        c.noteDidSave(note.fileURL, text: updated)
    }

    private func newNote() {
        guard let c = focused else { return }
        Task { if let note = await c.createNote() { selectedNoteID = note.id } }
    }

    // MARK: - Daily notes & templates

    /// Open today's daily note in the focused collection, creating it if needed.
    private func openTodaysNote() {
        let name = TemplateExpander.dailyNoteName(for: .now, format: dailyDateFormat)
        let rel = dailyNoteFolder.isEmpty ? "\(name).md" : "\(dailyNoteFolder)/\(name).md"
        guard let c = focused else { return }
        Task {
            if let note = await c.note(atRelativePath: rel, creatingWith: "# \(name)\n\n") {
                selectedTag = nil
                searchText = ""
                selectedNoteID = note.id
            }
        }
    }

    /// Notes under the configured templates folder in the focused collection.
    private var templateNotes: [Note] {
        guard !templatesFolder.isEmpty, let c = focused else { return [] }
        let base = c.rootURL.appendingPathComponent(templatesFolder).standardizedFileURL.path + "/"
        return c.notes
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

    private func delete(_ note: Note, in collection: Collection) {
        if selectedNoteID == note.id { selectedNoteID = nil }
        Task { await collection.deleteNote(note) }
    }

    /// Handle a clicked link within the selection's collection. External URLs
    /// open in the default app; otherwise the target is a note title — navigate
    /// to the matching note, or create it if it doesn't exist yet.
    private func openWikiLink(_ target: String) {
        let webSchemes: Set<String> = ["http", "https", "mailto", "file"]
        if let url = URL(string: target),
           let scheme = url.scheme?.lowercased(),
           webSchemes.contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }

        guard let c = editorCollection else { return }

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

        Task {
            let destination: Note?
            if base.isEmpty {
                destination = selectedNote
            } else if let url = c.linkGraph.resolve(base),
                      let note = c.notes.first(where: { $0.fileURL == url }) {
                destination = note
            } else if let match = c.notes.first(where: { $0.title.localizedCaseInsensitiveCompare(base) == .orderedSame }) {
                destination = match
            } else {
                destination = await c.createNote(title: base)   // create-on-miss
            }

            guard let destination else { return }
            let switching = selectedNoteID != destination.id
            selectedNoteID = destination.id

            if let heading {
                await tabs.editor(for: destination)
                if switching { try? await Task.sleep(for: .milliseconds(350)) }
                scrollToHeading(heading)
            }
        }
    }

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
