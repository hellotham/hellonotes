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

    /// Multi-provider LLM assistant. Settings live at the app level so every
    /// window shares them.
    @Environment(LLMSettings.self) private var llmSettings
    @State private var assistant: AssistantModel?
    @State private var permissions = PermissionBroker()
    @State private var skills = SkillStore()
    @State private var showAssistant = false
    @State private var showLLMSettings = false

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

    @State private var showOpenQuickly = false
    @State private var showGraph = false
    @State private var showMindMap = false
    @State private var showLibraryChat = false

    /// How notes are ordered in the folder tree.
    @State private var sortOrder: SortOrder = .modified

    /// Active tag filter, if any (within the focused collection).
    @State private var selectedTag: String?

    // MARK: - Focused / selection helpers

    /// The focused collection — drives the editor, Git panel, and note actions.
    private var focused: Collection? { library.focused }

    /// The selected note, wherever it lives across the open collections.
    private var selectedNote: Note? {
        library.allNotes.first { $0.id == selectedNoteID }
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
    private struct SearchGroup: Identifiable {
        let collection: Collection
        let rows: [NoteRow]
        var id: Collection.ID { collection.id }
    }

    private var searchGroups: [SearchGroup] {
        library.collections.compactMap { collection in
            let rows = collection.search.fullTextResults(query: searchText).map {
                NoteRow(note: $0.note, snippet: $0.snippet.isEmpty ? nil : $0.snippet)
            }
            return rows.isEmpty ? nil : SearchGroup(collection: collection, rows: rows)
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
                             rootURL: collection.rootURL, sort: sortOrder)
    }

    // MARK: - Editor derived data (for the selection's collection)

    private var backlinks: [Note] {
        guard let selectedNote, let c = editorCollection else { return [] }
        return c.linkGraph.backlinks(for: selectedNote, in: c.notes)
    }

    private var outgoingLinks: [Note] {
        guard let selectedNote, let c = editorCollection else { return [] }
        return c.linkGraph.outgoingLinks(for: selectedNote, in: c.notes)
    }

    private var currentNoteNames: [String] {
        guard let selectedNote, let c = editorCollection else { return [] }
        let text = activeEditor?.text ?? c.search.text(of: selectedNote) ?? ""
        return [selectedNote.title] + MarkdownParsing.aliases(in: text)
    }

    private var unlinkedMentions: [Note] {
        guard let selectedNote, let c = editorCollection else { return [] }
        return c.search.unlinkedMentions(
            of: selectedNote,
            names: currentNoteNames,
            excluding: Set(backlinks.map(\.fileURL))
        )
    }

    /// Nodes and resolved edges for the focused collection's link-graph view.
    private var graphData: (nodes: [GraphNode], edges: [GraphEdge]) {
        guard let c = focused else { return ([], []) }
        let notes = c.notes
        let indexByURL = Dictionary(uniqueKeysWithValues: notes.enumerated().map { ($1.fileURL, $0) })
        var edges: [GraphEdge] = []
        for (i, note) in notes.enumerated() {
            for target in c.linkGraph.outgoingByURL[note.fileURL] ?? [] {
                if let destURL = c.linkGraph.resolve(target), let j = indexByURL[destURL], j != i {
                    edges.append(GraphEdge(from: i, to: j))
                }
            }
        }
        return (notes.map { GraphNode(url: $0.fileURL, label: $0.title) }, edges)
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
            if assistant == nil {
                let model = AssistantModel(settings: llmSettings)
                model.registry = ToolRegistry(tools: CollectionTools.all())
                assistant = model
            }
            library.onExternalChange = { @MainActor in
                Task { await tabs.reconcileAll() }
                revalidateSelection()
            }
            library.onOpened = { recents.record($0) }
            if library.isEmpty {
                await library.restore()
                // First run with nothing to restore: offer the launcher.
                if library.isEmpty { showLauncher = true }
            }
            syncFocusedServices()
        }
        .onChange(of: selectedNoteID) { _, newID in
            if let note = library.allNotes.first(where: { $0.id == newID }) {
                library.focusCollection(containing: note.fileURL)
                Task { await tabs.editor(for: note) }
            }
        }
        .onChange(of: library.focusedID) { _, _ in
            selectedTag = nil
            syncFocusedServices()
        }
        .onChange(of: library.allNotes) { _, notes in
            tabs.prune(keeping: Set(notes.map(\.id)))
            revalidateSelection()
            if let c = focused { skills.refresh(from: c.notes) }
        }
        .onChange(of: tabs.totalSavedRevision) { _, _ in
            if let c = editorCollection {
                Task { await c.git.refreshStatus() }
                if autoCommit { c.git.scheduleAutoCommit(message: autoCommitMessage) }
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
        .sheet(isPresented: $showGraph) {
            let data = graphData
            GraphView(nodes: data.nodes, edges: data.edges) { url in
                if let note = focused?.notes.first(where: { $0.fileURL == url }) {
                    selectedTag = nil
                    searchText = ""
                    selectedNoteID = note.id
                }
            }
        }
        .sheet(isPresented: $showMindMap) {
            if let note = selectedNote, let c = editorCollection {
                MindMapView(rootURL: note.fileURL, notes: c.notes, linkGraph: c.linkGraph) { note in
                    selectedTag = nil
                    searchText = ""
                    selectedNoteID = note.id
                }
            }
        }
        .sheet(isPresented: $showLibraryChat) {
            LibraryChatView(intelligence: IntelligenceService(settings: llmSettings),
                            notes: library.allNotes, searches: library.collections.map(\.search)) { note in
                selectedTag = nil
                searchText = ""
                selectedNoteID = note.id
                showLibraryChat = false
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
        .sheet(isPresented: $showAssistant) {
            if let assistant {
                AssistantView(model: assistant) {
                    showAssistant = false
                    Task { try? await Task.sleep(for: .milliseconds(250)); showLLMSettings = true }
                }
            }
        }
        .sheet(isPresented: $showLLMSettings) {
            LLMSettingsView(settings: llmSettings)
        }
    }

    /// Point the assistant's tools and chat store at the focused collection.
    private func syncFocusedServices() {
        guard let assistant, let c = focused else { return }
        assistant.toolContext = ToolContext(
            collection: c, search: c.search, git: c.git, permissions: permissions,
            settings: llmSettings, skills: skills)
        assistant.sessionStore = ChatSessionStore(collectionURL: c.rootURL)
        skills.refresh(from: c.notes)
    }

    /// Drop the selection if the note (or attachment) it pointed at is gone.
    private func revalidateSelection() {
        let stillValid = selectedNoteID.map { id in
            library.allNotes.contains { $0.id == id }
                || library.collections.contains { $0.attachments.contains { $0.url == id } }
        } ?? true
        if !stillValid { selectedNoteID = tabs.openNotes.last?.id }
    }

    private func openAssistant() {
        if assistant == nil { assistant = AssistantModel(settings: llmSettings) }
        syncFocusedServices()
        DispatchQueue.main.async { showAssistant = true }
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
            .keyboardShortcut("o", modifiers: [.command, .shift])
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
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Button { showGraph = true } label: {
                    Label("Graph View", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(focused.notes.isEmpty)

                Button { showLibraryChat = true } label: {
                    Label("Ask Library", systemImage: "sparkles.rectangle.stack")
                }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(library.allNotes.isEmpty)

                Button { openAssistant() } label: {
                    Label("Assistant", systemImage: "sparkles")
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

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
                    backlinks: backlinks,
                    outgoingLinks: outgoingLinks,
                    unlinkedMentions: unlinkedMentions,
                    wikiResolver: c.wikiResolver,
                    embedProvider: c.embedProvider,
                    git: c.git,
                    linkCandidates: c.search.linkTargets(),
                    tagCandidates: c.search.allTags(),
                    headingProvider: { c.search.headings(forName: $0) },
                    onOpenWikiLink: openWikiLink,
                    onOpenNote: { selectedNoteID = $0.id },
                    onLinkMention: linkMention,
                    onShowMindMap: { showMindMap = true }
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
            statusBarButton("Graph view", "point.3.connected.trianglepath.dotted") { showGraph = true }
                .disabled(focused?.notes.isEmpty ?? true)
            statusBarButton("Ask your library", "sparkles.rectangle.stack") { showLibraryChat = true }
                .disabled(library.allNotes.isEmpty)
            statusBarButton("Assistant", "sparkles") { openAssistant() }
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
        let roots = outlineRoots
        return NoteOutlineList(
            roots: roots,
            signature: outlineSignature(roots),
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
            onFocusCollection: { library.focus($0) }
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
                .keyboardShortcut("o", modifiers: .command)
                .help("Open Quickly (⌘O)")
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
            } else if isSearching && searchGroups.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    // MARK: - Outline items (NSOutlineView data)

    /// The outline tree for the current mode: collections as group rows, with
    /// their folder trees (or flat search / tag results) as children.
    private var outlineRoots: [NoteOutlineItem] {
        if isSearching {
            return searchGroups.map { group in
                NoteOutlineItem(id: group.collection.id, kind: .collection(group.collection),
                                children: group.rows.map {
                    NoteOutlineItem(id: $0.note.fileURL.path, kind: .note($0.note, snippet: $0.snippet))
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
                                children: outlineItems(from: tree(for: collection)))
            }
        }
    }

    private func outlineItems(from nodes: [CollectionTreeNode]) -> [NoteOutlineItem] {
        nodes.map { node in
            if let note = node.note {
                return NoteOutlineItem(id: node.id, kind: .note(note, snippet: nil))
            } else if let file = node.file {
                return NoteOutlineItem(id: node.id, kind: .file(file))
            } else {
                return NoteOutlineItem(id: node.id, kind: .folder(node.name),
                                       children: outlineItems(from: node.children ?? []))
            }
        }
    }

    /// A cheap structural fingerprint so the outline reloads only when its
    /// contents (not just selection/accent) change.
    private func outlineSignature(_ roots: [NoteOutlineItem]) -> String {
        func walk(_ items: [NoteOutlineItem]) -> String {
            items.map { $0.id + "[" + walk($0.children) + "]" }.joined(separator: ",")
        }
        return "\(sortOrder.rawValue)|\(library.focusedID ?? "")|\(appearance.textScale)|" + walk(roots)
    }

    // MARK: - Actions

    /// Turn the first plain-text mention of the open note (by title) in `note`
    /// into a `[[link]]`, writing the change to disk and re-indexing.
    private func linkMention(_ note: Note) {
        guard let target = selectedNote, let c = editorCollection,
              let text = try? String(contentsOf: note.fileURL, encoding: .utf8),
              let updated = MentionScanner.linkingFirstMention(of: target.title, in: text) else { return }
        try? Data(updated.utf8).write(to: note.fileURL, options: .atomic)
        c.scan()
        c.refreshDerived()
    }

    private func newNote() {
        if let note = focused?.createNote() {
            selectedNoteID = note.id
        }
    }

    // MARK: - Daily notes & templates

    /// Open today's daily note in the focused collection, creating it if needed.
    private func openTodaysNote() {
        let name = TemplateExpander.dailyNoteName(for: .now, format: dailyDateFormat)
        let rel = dailyNoteFolder.isEmpty ? "\(name).md" : "\(dailyNoteFolder)/\(name).md"
        if let note = focused?.note(atRelativePath: rel, creatingWith: "# \(name)\n\n") {
            selectedTag = nil
            searchText = ""
            selectedNoteID = note.id
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
        let wasSelected = selectedNoteID == note.id
        collection.deleteNote(note)
        if wasSelected {
            selectedNoteID = nil
        }
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

        let destination: Note?
        if base.isEmpty {
            destination = selectedNote
        } else if let url = c.linkGraph.resolve(base),
                  let note = c.notes.first(where: { $0.fileURL == url }) {
            destination = note
        } else if let match = c.notes.first(where: { $0.title.localizedCaseInsensitiveCompare(base) == .orderedSame }) {
            destination = match
        } else {
            destination = c.createNote(title: base)
        }

        guard let destination else { return }
        let switching = selectedNoteID != destination.id
        selectedNoteID = destination.id

        if let heading {
            Task {
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
