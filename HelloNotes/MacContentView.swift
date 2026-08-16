//
//  MacContentView.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(macOS)
import SwiftUI
import AppKit
import TipKit

/// The macOS three-column navigation shell: sidebar, note list, and editor.
/// The note list shows every open collection in the library; the editor and Git
/// panel act on the focused collection (the one owning the selected note).
struct MacContentView: View {
    @Environment(Library.self) private var library
    @Environment(EditorDocumentStore.self) private var documents
    @Environment(NavigationRouter.self) private var router
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    /// The launch splash shows once per process, from the first main window.
    @MainActor private static var didShowSplash = false

    /// Open notes as tabs, each with its own debounced-autosave editor. Tabs may
    /// hold notes from any collection in the library.
    @State private var tabs = EditorTabs()
    /// A folder pending a confirmed "Move to Trash" (trashes all its contents).
    @State private var pendingFolderDelete: URL?

    /// Git commit identity + hosting-service accounts (GitHub, GitLab, …).
    @State private var gitAccounts = GitAccountsStore()
    @State private var showGitSettings = false
    @State private var showClone = false

    /// The "open" launcher and its backing stores (recents + saved libraries).
    @State private var recents = RecentsStore()
    @State private var libraries = LibrariesStore()
    @State private var showLauncher = false
    @State private var showNewRepo = false
    @State private var showWelcome = false
    /// First-run onboarding is shown once; afterwards an empty launch offers the
    /// launcher instead.
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

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
    /// Reopen where you left off: the focused collection + selected note persist
    /// across relaunches as stable path identifiers (not URLs).
    @SceneStorage("restoredCollectionID") private var restoredCollectionID = ""
    @SceneStorage("restoredNotePath") private var restoredNotePath = ""

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

    /// A separate Spotlight query for the references panel's unlinked-mention
    /// candidates, so selecting a note never cancels an in-flight sidebar search
    /// (each SpotlightSearch supersedes its own previous query).
    @State private var referenceSpotlight = SpotlightSearch()

    /// Cached note-list outline, rebuilt only when its inputs change (see
    /// `outlineInputsKey`) rather than re-derived (O(N log N)) every render.
    @State private var cachedRoots: [NoteOutlineItem] = []
    @State private var cachedSignature = ""

    /// References panel data, computed off-main and keyed on `referencesKey`.
    @State private var references = ReferencesData()

    /// Debounces the per-save git status refresh.
    @State private var gitStatusTask: Task<Void, Never>?

    @State private var showOpenQuickly = false
    /// ⌘⇧P — every command, findable by name. See `CommandPalette.swift`.
    @State private var showCommandPalette = false

    /// An in-progress link review, with the text the proposals were generated
    /// against so stale ranges can be detected rather than applied.
    private struct LinkReview: Identifiable {
        let id = UUID()
        let proposals: [LinkProposal]
        let noteText: String
    }
    @State private var linkReview: LinkReview?

    /// Rename-note prompt state (set via the context menu or the Note menu).
    @State private var renameTarget: Note?
    @State private var renameTitle = ""

    /// New-folder prompt state (set via the note-list context menu).
    @State private var newFolderCollection: Collection?
    @State private var newFolderParent: URL?
    @State private var newFolderName = ""

    /// How notes are ordered in the folder tree.
    @State private var sortOrder: SortOrder = .modified

    /// Active tag filter, if any (within the focused collection). Set from the
    /// inspector's Tags tab — the rails cooperate across the shell (decision 1).
    @State private var selectedTag: String?

    /// The right inspector rail. Per window, and remembered, because it is a
    /// place the user works in rather than something they summon (decision 10).
    @SceneStorage("inspectorPresented") private var inspectorPresented = true

    /// Left-rail visibility, so the native sidebar toggle works. Below 960pt
    /// the shell overrides this and the library becomes an overlay (decision 12).
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Which place the library rail is on, remembered per window. Stored as the
    /// collection's id — `""` means the Library place — because `SceneStorage`
    /// takes primitives, and because an id survives a collection being closed
    /// and reopened where an index or a reference would not.
    ///
    /// The sentinel distinguishes "never chosen" (follow the focused
    /// collection on first launch) from "chose Library", which is `""` — the
    /// two look identical otherwise, and a new window would keep snapping back
    /// to a collection the user had just navigated out of.
    @SceneStorage("railPlace") private var railPlaceID = MacContentView.railPlaceUnset

    static let railPlaceUnset = "?"

    /// An outline row to scroll into view once, set when something asks the
    /// window to *show* a collection (see `Library.pendingRevealCollectionID`).
    @State private var revealOutlineID: String?

    /// The Git panel, reached from the collection status bar. Git is
    /// collection-level state, and the status bar already carries that.
    @State private var showGitPanel = false

    /// Which inspector tab the band's five toggles select (D6). `@AppStorage`
    /// rather than `@State`: reopening the inspector to a different tab than
    /// you left it on is a small betrayal, and it used to live inside the panel.
    @AppStorage("inspectorTab") private var inspectorTabRaw = InspectorTab.outline.rawValue

    private var inspectorTab: InspectorTab {
        get { InspectorTab(rawValue: inspectorTabRaw) ?? .outline }
        nonmutating set { inspectorTabRaw = newValue.rawValue }
    }

    /// The last AI request sent to the inspector from a menu command or the
    /// palette. See `InspectorRequest` — the counter inside it is what lets the
    /// same command run twice.
    @State private var inspectorRequest: InspectorRequest?

    /// Focus for the band's search field. `.searchable` came with a keyboard
    /// route; a plain field has to be handed focus explicitly, which
    /// Edit ▸ Search All Collections (⌥⌘F) does over `hnFocusLibrarySearch`.
    @FocusState private var searchFocused: Bool


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

    // MARK: - The library rail's place

    /// The collection the rail is scoped to, or `nil` on the Library place.
    /// Resolved by id every time rather than held, so closing the collection
    /// the rail was on falls back to Library instead of dangling.
    private var railCollection: Collection? {
        library.collections.first { $0.id == railPlaceID }
    }

    private var railPlace: RailPlace {
        railCollection.map { .collection($0.id) } ?? .library
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
            // Wave 1: title/alias hits, straight from the metadata index —
            // instant, no file reads.
            searchResults = library.collections.compactMap { collection in
                let rows = collection.search.titleResults(query: query).map {
                    NoteRow(note: $0.note, snippet: nil)
                }
                return rows.isEmpty ? nil : SearchGroup(collection: collection, rows: rows)
            }
            searchResultsRevision &+= 1
            isSearchInFlight = false
            rebuildOutline()   // reflect results immediately, independent of key timing

            // Wave 2: *content* matches — inside notes and attachments (PDFs,
            // documents, …) — via the system Spotlight index. Spotlight names
            // the files whose content matches; only those files are then read
            // (off-main) to verify and extract snippets, so a query costs a
            // handful of reads, not a pass over the whole collection. Zero
            // Spotlight hits simply means no content matches (Finder
            // semantics); title hits above still stand. Skipped for 1–2
            // character queries, which would churn through enormous result
            // sets for no discriminating value.
            guard query.count >= 3 else { return }
            let hits = await spotlight.search(query, in: library.collections.map(\.rootURL))
            guard !Task.isCancelled, !hits.isEmpty else { return }
            let hitPaths = Set(hits.map { $0.standardizedFileURL.path })
            var merged: [SearchGroup] = []
            for collection in library.collections {
                let mdCandidates = collection.notes.map(\.fileURL)
                    .filter { hitPaths.contains($0.standardizedFileURL.path) }
                let contentHits = await collection.search.contentResults(query: query, in: mdCandidates)
                guard !Task.isCancelled else { return }
                let contentURLs = Set(contentHits.map(\.id))
                let titleRows = (searchResults.first { $0.id == collection.id }?.rows ?? [])
                    .filter { !contentURLs.contains($0.note.fileURL) }
                let rows = contentHits.map { NoteRow(note: $0.note, snippet: $0.snippet) } + titleRows
                let files = collection.attachments.filter { hitPaths.contains($0.url.standardizedFileURL.path) }
                guard !rows.isEmpty || !files.isEmpty else { continue }
                merged.append(SearchGroup(collection: collection, rows: rows, fileRows: files))
            }
            guard !Task.isCancelled else { return }
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

    /// Recompute the references panel off the main thread.
    ///
    /// Unlinked mentions no longer scan an in-memory corpus (note text isn't
    /// kept resident any more): Spotlight names the files whose content
    /// contains the note's title/aliases, and only those few candidates are
    /// read and verified with the word-boundary scanner. On a volume without
    /// a Spotlight index the panel degrades to backlinks + outgoing links.
    private func computeReferences() async {
        guard let note = selectedNote, let c = editorCollection else {
            references = ReferencesData(); return
        }
        let back = c.linkGraph.backlinks(for: note, in: c.notes)
        let out = c.linkGraph.outgoingLinks(for: note, in: c.notes)
        let names = currentNoteNames
        let excluded = Set(back.map(\.fileURL)).union([note.fileURL])

        var candidatePaths: Set<String> = []
        for name in names {
            let hits = await referenceSpotlight.search(name, in: [c.rootURL])
            guard !Task.isCancelled else { return }
            candidatePaths.formUnion(hits.map { $0.standardizedFileURL.path })
        }
        let candidates = c.notes.filter {
            candidatePaths.contains($0.fileURL.standardizedFileURL.path)
                && !excluded.contains($0.fileURL)
        }

        let mentions = await Task.detached(priority: .userInitiated) { () -> [Note] in
            candidates.compactMap { candidate in
                guard let text = try? FileIO.readString(at: candidate.fileURL),
                      MentionScanner.containsMention(of: names, in: text) else { return nil }
                return candidate
            }
        }.value
        guard !Task.isCancelled else { return }
        references = ReferencesData(backlinks: back, outgoingLinks: out, unlinkedMentions: mentions)
    }

    var body: some View {
        // Split in two deliberately: the scene wiring below (a dozen `onChange`
        // handlers, a `task`, and a stack of sheets and alerts) is one
        // expression to the type checker, and adding to it eventually trips
        // "unable to type-check in reasonable time". Two opaque halves are two
        // smaller problems.
        presentations(
            shellCore
                .modifier(FileOperationErrorAlert(collection: focused))
                .modifier(FolderDeleteConfirmation(folder: $pendingFolderDelete) { folder in
                    if let c = library.collections.first(where: { folder.path == $0.id || folder.path.hasPrefix($0.id + "/") }) {
                        Task { await c.deleteFolder(at: folder) }
                    }
                })
        )
    }

    private var shellCore: some View {
        AdaptiveShell(
            inspectorPresented: $inspectorPresented,
            columnVisibility: $columnVisibility,
            sidebar: { collectionTree },
            pane: { editorColumn },
            inspector: { inspector },
            // A Mac window declares an 860pt minimum, so the compact shell is
            // only reachable if the OS forces it (Stage Manager can ignore a
            // minimum). Degrade to the editor rather than an error — decision 9.
            compact: { EditorPaneContainer { editorColumn } }
        )
        // The declared window minimum (decision 9). A floor under the layout so
        // the editor's status bar and note list never collapse into vertical
        // text wrapping — and if the OS forces smaller anyway, the shell
        // degrades rather than erroring.
        // HIG (Toolbars): "Don't title windows with your app name. Your app's
        // name doesn't provide useful information about your content
        // hierarchy." The window is titled with where you are — the collection
        // — and left empty when there is none, which the same section allows:
        // "If titling a toolbar seems redundant, you can leave the title area
        // empty."
        // HIG (Toolbars): "Don't title windows with your app name." The window
        // is titled with where you are — the collection — for the Window menu
        // and Mission Control…
        .navigationTitle(railCollection?.name ?? "")
        // …but the *band* does not draw it (shell-chrome.md D10). Apple Notes
        // shows no title there either, and at 860pt the title is the difference
        // between one clean row and a `»` that swallows search and every
        // inspector tab — measured in ChromeLab, designs 8 vs 10.
        .toolbar(removing: .title)
        .onReceive(NotificationCenter.default.publisher(for: .hnFocusLibrarySearch)) { _ in
            // Opening the sidebar too: a search whose results land in a hidden
            // panel is a dead end, and ⌥⌘F is a request to *look* for something.
            if columnVisibility == .detailOnly {
                withAnimation(.easeInOut(duration: 0.18)) { columnVisibility = .all }
            }
            searchFocused = true
        }
        .frame(minWidth: ShellMetrics.windowMinWidth, minHeight: ShellMetrics.windowMinHeight)
        // S2 (docs/layout-architecture.md): a minimum is a floor, not a
        // ceiling. Without a maximum, any column child with a large ideal size
        // (note list, editor, file viewer) inflates the split view past the
        // window and offsets it off-screen.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // A hosted test bundle launches this app to run in. Restoring the
            // user's real library there is both a privacy surprise and the
            // reason the suite crawled: 2,000 notes of coordinated cloud I/O
            // land on the same main actor the tests run on. See TestEnvironment.
            guard !TestEnvironment.isRunningTests else { return }
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
            tabs.prepareToOpen = { @MainActor url in
                await library.collection(containing: url)?.hydrateIfNeeded(url)
            }
            // Never write into a folder that isn't there. The edit stays in the
            // buffer and lands as soon as the collection is readable again.
            tabs.saveBlocked = { @MainActor url in
                guard let collection = library.collection(containing: url),
                      case .unavailable(let reason) = collection.state else { return nil }
                let title = url.deletingPathExtension().lastPathComponent
                return "Can’t save “\(title)” — \(reason.explanation) Your changes are kept here until it’s back."
            }
            library.onOpened = { recents.record($0) }
            if library.isEmpty {
                await library.restore()
                // First run with nothing to restore: onboard a brand-new user,
                // otherwise (welcome already seen) go straight to the launcher.
                if library.isEmpty {
                    if hasSeenWelcome { showLauncher = true } else { showWelcome = true }
                }
            }
            // Reopen the last-focused collection + note (if still present).
            if !restoredCollectionID.isEmpty,
               library.collections.contains(where: { $0.id == restoredCollectionID }) {
                library.focusedID = restoredCollectionID
            }
            if !restoredNotePath.isEmpty {
                let url = URL(fileURLWithPath: restoredNotePath)
                if library.allNotes.contains(where: { $0.id == url }) { selectedNoteID = url }
            }
            // A window that has never had its rail moved opens in the focused
            // collection, not on the Library place: the notes are the point.
            if railPlaceID == Self.railPlaceUnset {
                railPlaceID = library.focusedID ?? ""
            }
        }
        .onChange(of: selectedNoteID) { _, newID in
            restoredNotePath = newID?.path ?? ""
            if let note = library.allNotes.first(where: { $0.id == newID }) {
                library.focusCollection(containing: note.fileURL)
                Task { await tabs.editor(for: note) }
            }
        }
        .onChange(of: library.focusedID) { _, newID in
            restoredCollectionID = newID ?? ""
            selectedTag = nil
            // The rail follows the focus while it is standing in a collection:
            // opening a search hit from another collection should move the rail
            // rather than leave it pointing at a tree you're no longer looking
            // at. On the Library place it stays put — you went there on purpose.
            if railPlace != .library, let newID { railPlaceID = newID }
        }
        .onChange(of: library.collections.count) { was, now in
            // Opening the first collection should land you in it rather than
            // leaving you on the Library place looking at quick actions.
            if was == 0, now > 0, railPlace == .library { railPlaceID = library.focusedID ?? "" }
        }
        .onChange(of: library.pendingRevealCollectionID) { _, id in
            // Something added a collection and asked us to show it. Unlike a
            // passing focus change this moves the rail unconditionally — the
            // user asked for this collection by name, so leaving them looking at
            // a different tree makes a successful add look like a failed one.
            guard let id else { return }
            selectedTag = nil
            library.focusedID = id
            railPlaceID = id
            revealOutlineID = id
            library.pendingRevealCollectionID = nil
        }
        .onChange(of: library.pendingOpenNoteID) { _, id in
            // Another window (graph, mind map, assistant, chat) asked us to
            // show a note.
            guard let id else { return }
            // Same rule as the menu commands: nothing changes the selection
            // underneath the palette while it is up, because a sheet over a
            // window whose state moved on is how it wedged.
            showOpenQuickly = false
            selectedTag = nil
            searchText = ""
            selectedNoteID = id
            library.pendingOpenNoteID = nil
        }
        .onChange(of: library.allNotes) { _, notes in
            // A cached document captured which wiki-link targets existed when
            // it was built, so once the note set changes it would colour
            // [[links]] by a stale answer.
            documents.forgetAll()
            tabs.prune(keeping: Set(notes.map(\.id)))
            revalidateSelection()
            library.writeWidgetSnapshot()   // refresh the recent-notes widget
            Task { await router.donateNotesToSpotlight() }   // system Spotlight
        }
        .onChange(of: searchText) { _, q in scheduleSearch(q) }
        .onChange(of: router.pendingSearch) { _, query in
            guard let query else { return }
            showOpenQuickly = false
            selectedTag = nil
            searchText = query
            router.pendingSearch = nil
        }
        // Rebuild the (cached) note-list outline only when its structural inputs
        // change — not on every unrelated body re-eval (selection, git, accent).
        .onChange(of: outlineInputsKey, initial: true) { _, _ in rebuildOutline() }
        // Recompute the references panel off-main when the selection or index
        // changes — never inline in the body (would scan all notes on selection).
        .task(id: referencesKey) { await computeReferences() }
        .onChange(of: tabs.totalSavedRevision) { _, _ in
            guard let c = editorCollection else { return }
            // Never auto-commit a cloud-backed collection: libgit2 would churn
            // the object store against online-only files. Nor a collection that
            // is only *part* of a repository — commits there are scoped to this
            // folder, but writing commits automatically into a repository
            // someone is using for other work is not ours to decide.
            // (Both are disabled in the toggle too; honour a pre-existing
            // enabled flag as well.)
            if autoCommit, CloudProvider.name(for: c.rootURL) == nil,
               !c.git.status.isSubdirectory {
                c.git.scheduleAutoCommit(message: autoCommitMessage)
            }
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
        .onAppear {
            // On ⌘Q, drain this window's pending autosaves before exit
            // (terminateLater handshake) so no debounced edit is lost.
            TerminationGuard.current?.register(tabs) { [tabs] in await tabs.flushAll() }
        }
        .onDisappear { TerminationGuard.current?.unregister(tabs) }
    }

    /// Every sheet, alert and scene value the window owns — the second half of
    /// the split described in `body`.
    private func presentations<V: View>(_ content: V) -> some View {
        content
        .sheet(isPresented: $showCommandPalette) {
            CommandPaletteView(commands: appActions.paletteCommands)
        }
        .sheet(item: $linkReview) { review in
            ReviewLinksView(
                proposals: review.proposals,
                noteText: review.noteText,
                preview: { focused?.openingLines(of: $0) ?? "" },
                onFinish: { applyAcceptedLinks($0, reviewedText: review.noteText) },
                onDecline: { focused?.declineLink($0) }
            )
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
        .sheet(isPresented: $showWelcome, onDismiss: { hasSeenWelcome = true }) {
            WelcomeView(
                onOpenCollection: { showWelcome = false; library.requestOpenCollections() },
                onOpenObsidian: { showWelcome = false; openObsidianVault() },
                onDismiss: { showWelcome = false }
            )
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
                // Through the same wrapper as every other command: this one is
                // a window-level shortcut rather than a menu item, which is
                // exactly how it escaped the original sweep.
                Button("") { closingOpenQuickly { closeTab(id) }() }
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

    /// Wraps a menu-bar command so it dismisses the Open Quickly palette before
    /// running. A global shortcut (⌘N, ⌘O, …) fired while the palette sheet is
    /// up would otherwise mutate selection/presentation state underneath it and
    /// wedge the sheet's focus — Escape stops dismissing until the query field
    /// recovers. Commands behave as if the user closed the palette first.
    private func closingOpenQuickly(_ action: @escaping () -> Void) -> () -> Void {
        {
            showOpenQuickly = false
            action()
        }
    }

    /// The command surface published to the menu bar for this window.
    private var appActions: AppActions {
        AppActions(
            canNewNote: focused != nil,
            newNote: closingOpenQuickly { newNote() },
            todaysNote: closingOpenQuickly { openTodaysNote() },
            openLauncher: closingOpenQuickly { showLauncher = true },
            canOpenQuickly: !(focused?.notes.isEmpty ?? true),
            openQuickly: { showOpenQuickly = true },
            canGraph: !(focused?.notes.isEmpty ?? true),
            graphView: closingOpenQuickly { openWindow(id: "graph") },
            canAsk: !library.allNotes.isEmpty,
            askLibrary: closingOpenQuickly { openWindow(id: "askLibrary") },
            assistant: closingOpenQuickly { openWindow(id: "assistant") },
            canCloseTab: tabs.openNotes.count > 1 && tabs.editor(withID: selectedNoteID) != nil,
            closeTab: closingOpenQuickly { if let id = selectedNoteID { closeTab(id) } },
            // Format and Note commands target the note *behind* the palette
            // (Rename would even stack an alert on the sheet), so they grey
            // out while it's presented instead of dismissing it.
            format: showOpenQuickly ? nil : selectedNote.map { note in
                { action in
                    NotificationCenter.default.post(
                        name: .hnFormat(action.kind, documentId: note.fileURL.path),
                        object: nil, userInfo: action.userInfo)
                }
            },
            note: showOpenQuickly ? nil : selectedNote.map { note in
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
                    printNote: {
                        if let editor = activeEditor {
                            EditorExport.printNote(markdown: editor.text, title: note.title)
                        }
                    },
                    moveToTrash: {
                        if let c = library.collection(containing: note.fileURL) { delete(note, in: c) }
                    }
                )
            },
            rescan: focused.map { collection in
                { collection.rescan() }
            },
            showsNonNoteFiles: focused?.showsNonNoteFiles,
            setShowsNonNoteFiles: focused.map { collection in
                { collection.showsNonNoteFiles = $0 }
            },
            openCloudFolder: { library.requestOpenCloudFolder() },
            refreshCloudCollection: focused.flatMap { collection in
                collection.isRemote ? { Task { await collection.refreshFromProvider() } } : nil
            },
            commandPalette: { showCommandPalette = true },
            ai: aiActions,
            reviewLinks: (!showOpenQuickly && selectedNote != nil && focused != nil)
                ? { beginLinkReview() } : nil
        )
    }

    /// Gather this note's unmade links, then hand them to the review sheet.
    ///
    /// Generated once, up front, rather than lazily per step: every proposal's
    /// range is an offset into the text as it is *now*, so a set generated
    /// piecemeal while the note changed underneath would apply at the wrong
    /// offsets. Nothing is written until the review finishes.
    private func beginLinkReview() {
        guard let collection = focused, let editor = activeEditor else { return }
        let text = editor.text
        Task {
            let found = await collection.linkProposals(in: text, for: selectedNote?.fileURL)
            linkReview = LinkReview(proposals: found, noteText: text)
        }
    }

    /// Apply the accepted links as one edit.
    private func applyAcceptedLinks(_ accepted: [LinkProposal], reviewedText: String) {
        guard !accepted.isEmpty, let editor = activeEditor else { return }
        // If the note changed while the sheet was open, the ranges no longer
        // describe it. Re-deriving would silently link different words, so this
        // says so instead — the review is cheap to repeat, a wrong link is not.
        guard editor.text == reviewedText else {
            focused?.lastError = "The note changed while you were reviewing, so no links were added. Run Review Links again."
            return
        }
        editor.text = LinkProposals.apply(accepted, to: editor.text)
    }

    /// The AI commands, or `nil` when they would only disappoint — no note
    /// open, or no provider that can actually answer. A greyed-out menu item
    /// says "not now"; an enabled one that always errors says "this app is
    /// broken", and the second is the lie.
    private var aiActions: AIActions? {
        guard !showOpenQuickly, selectedNote != nil else { return nil }
        let intelligence = IntelligenceService(settings: llmSettings)
        guard intelligence.isAvailable else { return nil }
        return AIActions(
            providerName: intelligence.providerName,
            summarize: { askInspector(.summarize) },
            suggestTags: { askInspector(.suggestTags) },
            suggestLinks: { askInspector(.suggestLinks) },
            rewriteNote: { NotificationCenter.default.post(name: .hnRewriteNote, object: nil) }
        )
    }

    /// What the floating bar offers over a selection in `collection`.
    ///
    /// All three are things Writing Tools structurally cannot do, because they
    /// are about this vault rather than about this sentence.
    private func selectionActions(in collection: Collection) -> SelectionActions {
        SelectionActions(
            linkTarget: { phrase in
                // Exact, case-insensitive, and nothing looser. A fuzzy match
                // here would confidently link "second brain" to a note called
                // "Second Screen", and a wrong link is worse than no link: it
                // corrupts the graph silently and nobody re-reads a link they
                // accepted. Meaning-based candidates are the semantic index's
                // job, behind a review step, not a one-click button.
                let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !phrase.isEmpty else { return nil }
                return collection.search.linkTargets().first {
                    $0.caseInsensitiveCompare(phrase) == .orderedSame
                }
            },
            findRelated: { phrase in
                // Into the note list's search, where results already have rows,
                // snippets and selection — the same reasoning as following a tag.
                selectedTag = nil
                searchText = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            },
            explain: { phrase in
                library.requestAsk("Explain this, using my notes: \(phrase)")
                openWindow(id: "askLibrary")
            }
        )
    }

    /// Reveal the tab that shows this kind of answer, then ask for it.
    ///
    /// Revealing first is the point: a command whose result appears in a panel
    /// you cannot see has not been made findable, it has been made invisible
    /// twice over.
    private func askInspector(_ kind: InspectorRequest.Kind) {
        let request = InspectorRequest(kind: kind, token: (inspectorRequest?.token ?? 0) + 1)
        inspectorTab = request.tab
        inspectorPresented = true
        inspectorRequest = request
    }

    /// Open the rename prompt pre-filled with the note's current title.
    private func beginRename(_ note: Note) {
        renameTitle = note.title
        renameTarget = note
    }

    /// Flush pending edits (the file is about to move), rename, and reselect.
    /// Rename the open note from its inline title. Goes through the same
    /// collection path as the note-list rename, so the file moves *and* every
    /// `[[wiki-link]]` to it is rewritten — a title that only relabelled the
    /// note would quietly break every link pointing at it.
    private func renameSelectedNote(to title: String) {
        guard let note = selectedNote,
              let collection = library.collection(containing: note.fileURL) else { return }
        Task {
            // Flush first: renaming moves the file, and an in-flight autosave
            // would be writing to the old path.
            await tabs.flushAll()
            if let renamed = await collection.renameNote(note, to: title) {
                selectedNoteID = renamed.id
            }
        }
    }

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

    // MARK: - Column 1: the collection tree

    /// **The** sidebar: Recents and Bookmarks pinned above every open
    /// collection, each collection expanding into its own folder tree
    /// (`docs/shell-chrome.md` D2/D4). Apple Notes' sidebar exactly — pinned
    /// places, then a section per account, then that account's folders.
    ///
    /// It replaced a fixed-width collection rail *plus* a folder-tree column.
    /// The reason is structural: SwiftUI gives a correctly-placed sidebar
    /// toggle to column one only, so while the rail held that slot the panel
    /// that actually needs collapsing had to have its control hand-placed —
    /// which is where the button floating mid-list came from.
    ///
    /// Tags deliberately do not live here: the sidebar answers "where is it?",
    /// while tags are cross-cutting and belong to the inspector, which answers
    /// "what is this, and what touches it?" (decision 1).
    private var collectionTree: some View {
        VStack(spacing: 0) {
            searchCompletenessNotice
            outlineList
                .overlay { noteListEmptyState }
        }
    }

    /// Collections that can't answer a search truthfully right now: the index is
    /// behind the folder, or the folder can't be read at all.
    private var collectionsWithPartialAnswers: [Collection] {
        library.collections.filter { !$0.isAvailable || $0.hasIncompleteIndex }
    }

    /// Collections holding items whose content a search cannot read because it
    /// has not been downloaded.
    private var collectionsWithUnreadableContent: [Collection] {
        library.collections.filter { $0.notLocalCount > 0 }
    }

    /// Say when search results are incomplete, at the point they are read.
    ///
    /// Marking the collection row alone would not do: a **false negative** is
    /// the most damaging thing a knowledge tool can produce, because it is
    /// invisible by construction — you cannot notice the note that didn't come
    /// back. Someone searching a vault whose index is behind must be told here,
    /// where they are about to conclude the note doesn't exist.
    @ViewBuilder
    private var searchCompletenessNotice: some View {
        let affected = collectionsWithPartialAnswers
        if isSearching, !affected.isEmpty {
            let names = affected.map(\.name).joined(separator: ", ")
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text("These results may be incomplete — \(names) \(affected.count == 1 ? "is" : "are") not fully indexed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.4))
            Divider()
        }

        // Content search deliberately skips files that aren't downloaded, so a
        // query never quietly pulls a whole account local. That default is
        // right — but a default is not the same as the only option, and without
        // a way past it the omission is a wall rather than a choice.
        let notLocal = collectionsWithUnreadableContent
        if isSearching, !notLocal.isEmpty {
            let total = notLocal.reduce(0) { $0 + $1.notLocalCount }
            HStack(spacing: 6) {
                Image(systemName: "icloud.and.arrow.down")
                    .foregroundStyle(.secondary)
                Text("\(total) item\(total == 1 ? " isn't" : "s aren't") downloaded, so their contents aren't searched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Download and Search") {
                    Task { for collection in notLocal { await collection.downloadAllForSearch() } }
                }
                .font(.caption)
                .buttonStyle(.link)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.4))
            Divider()
        }
    }

    // MARK: - The inspector rail (right)

    /// "What is this, and what touches it?" — outline, tags, references,
    /// properties and history, in one place instead of four (decisions 1, 8, 10).
    @ViewBuilder
    private var inspector: some View {
        if let collection = editorCollection {
            NoteInspector(
                noteText: activeEditor?.text ?? "",
                onSelectHeading: { scrollToHeading($0.title) },
                summarize: { text in
                    try await IntelligenceService(settings: llmSettings).summarize(text)
                },
                onInsertSummary: { insertSummaryCallout($0) },
                allTags: collection.search.allTags(),
                noteCount: { collection.search.notesTagged($0).count },
                selectedTag: Binding(
                    get: { selectedTag },
                    // Selecting a tag in the right rail filters the list in the
                    // left one — and a filter and a search would fight, so the
                    // search field yields.
                    set: { selectedTag = $0; if $0 != nil { searchText = "" } }
                ),
                suggestTags: { text, existing in
                    try await IntelligenceService(settings: llmSettings)
                        .suggestTags(for: text, existing: existing)
                },
                onInsertTag: { insertTag($0) },
                backlinks: references.backlinks,
                outgoingLinks: references.outgoingLinks,
                unlinkedMentions: references.unlinkedMentions,
                onOpenNote: { selectedNoteID = $0.id },
                onLinkMention: linkMention,
                linkCandidates: collection.search.linkTargets(),
                suggestLinks: { text, _ in
                    // Candidates come from the retrieval index, not from the
                    // full title list. Handing a model 2,000 titles does not fit
                    // any context window, and the ones that *did* fit were
                    // whichever happened to sort first — so the feature quietly
                    // got worse as a vault grew, which is the opposite of what
                    // a link suggester is for.
                    try await suggestLinks(for: text, in: collection)
                },
                onInsertLink: { insertLink($0) },
                properties: propertiesBinding,
                onPropertiesChanged: {},
                fileURL: selectedNote?.fileURL,
                git: collection.git,
                onRestoreRevision: { restored in activeEditor?.text = restored },
                tab: inspectorTab,
                request: inspectorRequest
            )
        } else {
            ContentUnavailableView("No Collection", systemImage: "sidebar.right",
                                   description: Text("Open a collection to inspect its notes."))
        }
    }

    /// Ask the model which of the *retrieved* neighbours this note should link
    /// to — retrieval narrows thousands of notes to a shortlist, the model
    /// judges the shortlist.
    ///
    /// The two-stage shape is what makes this scale, and it is also honest about
    /// what each stage is good at: the index finds notes sharing distinctive
    /// vocabulary (measured: 52.1% recall@10, `docs/semantic-retrieval-benchmark.md`),
    /// and the model decides which of those a reader would actually want linked.
    private func suggestLinks(for text: String, in collection: Collection) async throws -> [String] {
        let neighbours = await collection.relatedNotes(
            to: text, excluding: selectedNote?.fileURL, limit: 40)
        guard !neighbours.isEmpty else { return [] }
        return try await IntelligenceService(settings: llmSettings)
            .suggestLinks(for: text, candidates: neighbours.map(\.title))
    }

    /// Write a suggested tag into the open note. See `NoteEdits`.
    private func insertTag(_ tag: String) {
        guard let editor = activeEditor else { return }
        editor.text = NoteEdits.addingTag(tag, to: editor.text)
    }

    /// Write an accepted link suggestion into the open note. See `NoteEdits`.
    private func insertLink(_ title: String) {
        guard let editor = activeEditor else { return }
        editor.text = NoteEdits.addingRelatedLink(title, to: editor.text)
    }

    /// Insert a summary as a `> [!summary]` callout at the top of the body.
    private func insertSummaryCallout(_ text: String) {
        guard let editor = activeEditor else { return }
        editor.text = NoteEdits.insertingSummaryCallout(text, into: editor.text)
    }

    /// Front matter, read from and written straight through the note buffer.
    ///
    /// Deliberately derived rather than copied into `@State`. The copy was
    /// seeded when the *selection* changed, which happens before the editor has
    /// loaded that note's text — so the inspector showed the properties of
    /// nothing at all. A binding over the buffer cannot be stale, and writing
    /// through it autosaves by the same path typing does.
    private var propertiesBinding: Binding<[Property]> {
        Binding(
            get: { FrontMatter.properties(in: activeEditor?.text ?? "") },
            set: { updated in
                guard let editor = activeEditor else { return }
                editor.text = FrontMatter.applying(updated, to: editor.text)
            }
        )
    }

    // MARK: - Git section (the rail's collection)

    /// Git acts on the collection the rail is standing in; on the Library place
    /// it falls back to the focused one, so the button is never a dead end.
    private var gitCollection: Collection? { railCollection ?? focused }

    @ViewBuilder
    private var gitSection: some View {
        if let git = gitCollection?.git {
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

            // Git-on-cloud guardrail: libgit2 reads the whole object store, so a
            // repo whose objects are online-only thrashes (and coordinated access
            // isn't wired through libgit2). Warn, and keep auto-commit off in a
            // cloud folder.
            if let root = gitCollection?.rootURL, let provider = CloudProvider.name(for: root) {
                Label("In \(provider). Git works best when the folder is fully downloaded — online-only files can slow or break operations.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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

                // This collection is only part of its repository — say where the
                // repository starts, and that everything here is confined to
                // this folder. Offering full Git controls without naming the
                // wider repo is how someone ends up surprised by what a commit
                // contained.
                if git.status.isSubdirectory, let repoRoot = git.status.repositoryRoot {
                    Text("Inside the repository at \(repoRoot.path(percentEncoded: false)) — commits, counts and history cover only this folder.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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

                let cloudBacked = gitCollection.map { CloudProvider.name(for: $0.rootURL) != nil } ?? false
                let partOfLargerRepo = git.status.isSubdirectory
                Toggle("Auto-commit", isOn: $autoCommit)
                    .font(.caption)
                    .toggleStyle(.checkbox)
                    .disabled(cloudBacked || partOfLargerRepo)
                if cloudBacked {
                    Text("Auto-commit is off in cloud folders — commit manually once files are downloaded.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if partOfLargerRepo {
                    Text("Auto-commit is off inside a larger repository — commit this folder yourself when you're ready.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = git.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .help(error)
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
        // S3: content expands, chrome stays fixed. Without the clamp this
        // VStack adopts the ideal height of whichever child is largest
        // (editor, file viewer) and pushes it up into the split view.
        editorPaneBody
            // HIG, macOS: "the toolbar resides in the frame at the top of a
            // window, either below or integrated with the title bar", and
            // custom bar backgrounds "might overlay or interfere with
            // background effects that the system provides". A tab strip is not
            // a toolbar — "a tab bar is specifically for navigating between
            // areas of an app" — so it gets its own row *below* the toolbar
            // rather than sharing that frame. (Sharing the row is called out
            // as an iPadOS affordance, pointedly not a macOS one.)
            //
            // `safeAreaInset` is what puts it there: as a plain first child of
            // the column it drew into the toolbar's own row, because the window
            // is `.fullSizeContentView` and the column extends up under it.
            .safeAreaInset(edge: .top, spacing: 0) {
                if tabs.openNotes.count > 1 {
                    VStack(spacing: 0) {
                        EditorTabBar(
                            notes: tabs.openNotes,
                            activeID: selectedNoteID,
                            onSelect: { selectedNoteID = $0 },
                            onClose: closeTab
                        )
                        Divider()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The toolbar belongs to the editor, Mail-style. Declared on the
            // note list it rendered over the *inspector* — the rightmost column
            // wins the trailing edge — leaving nothing above the text.
            .toolbar { editorToolbar }
    }

    /// One row, in reading order: what acts on the sidebar, what acts on the
    /// note, what acts on the inspector. `docs/shell-chrome.md` Part 5, and
    /// every position in it is measured from `scratchpad/ChromeLab --design 10`
    /// at both 1470pt and 860pt rather than judged by eye.
    ///
    /// Note what is *absent*. There is no sidebar-toggle button: the sidebar is
    /// column one of a `NavigationSplitView`, so the platform supplies one and
    /// pins it to that column's trailing edge — Apple Notes' position — and
    /// relocates it beside the traffic lights when the sidebar hides. Every
    /// hand-placed substitute landed somewhere wrong. Sort and Insert Template
    /// are absent too: neither is used *while* writing, so both live in the menu
    /// bar with their shortcuts (D9 of the priority rule).
    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        // Leading — the sidebar's own controls, which hide along with it.
        ToolbarItem(placement: .navigation) {
            Menu {
                Button("New Collection…") { showLauncher = true }
                Button("New Folder…") {
                    newFolderParent = nil
                    newFolderCollection = focused
                }
                .disabled(focused == nil)
            } label: {
                Label("Add", systemImage: "plus.rectangle.on.folder")
            }
            .help("Open a collection, or add a folder to this one")
        }
        // Search sits against the panel it searches — files and folders — which
        // is where Xcode, VS Code and Obsidian put theirs. A plain field rather
        // than `.searchable`, for two measured reasons: `.searchable` collapses
        // to a magnifier glyph at 860pt (P2's laptop, the width where search
        // matters most), and it always claims the trailing end of the band,
        // which would push the inspector's tabs off the panel they belong to.
        ToolbarItem(placement: .navigation) { searchField }

        // Centred, so they sit over the *editor* and survive the sidebar being
        // collapsed — which is exactly when P2 needs Open Quickly to navigate.
        ToolbarItemGroup(placement: .principal) {
            Button { newNote() } label: {
                Label("New Note", systemImage: "square.and.pencil")
            }
            .help("New Note (⌘N)")
            .disabled(focused == nil)

            Button { showOpenQuickly = true } label: {
                Label("Open Quickly", systemImage: "arrow.forward.square")
            }
            .help("Open Quickly (⇧⌘O)")
            .disabled(focused?.notes.isEmpty ?? true)
        }

        // Trailing — the inspector's five tabs, over the inspector, Pages'
        // `Format`/`Document` scaled up. These *are* the tab strip: the panel
        // itself carries none, which is what removes the spurious row inside it.
        ToolbarItemGroup {
            ForEach(InspectorTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        // Pressing the tab you are already on closes the panel,
                        // which is what Pages' Format button does.
                        if inspectorPresented && inspectorTab == tab {
                            inspectorPresented = false
                        } else {
                            inspectorTab = tab
                            inspectorPresented = true
                        }
                    }
                } label: {
                    Label(tab.title, systemImage: tab.systemImage)
                }
                .help(tab.title)
                .background(
                    inspectorPresented && inspectorTab == tab
                        ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 5)
                )
            }
        }
    }

    /// Sized in points so it cannot collapse, and narrow enough that the whole
    /// band still fits at the 860pt window minimum — verified by capture, where
    /// a 240pt field overflowed search *and* all five inspector tabs into a `»`.
    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { searchFocused = false }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(width: 190)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Search all collections")
    }

    /// Collection-level conditions worth interrupting a reader for.
    ///
    /// The status bar carries these too, but only appears when *no* note is
    /// selected — which is the minority of the time. A folder that has gone
    /// missing, or an index known to be behind, must be visible while you are
    /// actually reading. Silent when there is nothing to say, so ordinary work
    /// gains no chrome.
    @ViewBuilder
    private var collectionConditionBar: some View {
        if let focused, selectedNoteID != nil {
            if case .unavailable(let reason) = focused.state {
                conditionStrip("exclamationmark.triangle.fill", .orange,
                               "\(focused.name) is unavailable — \(reason.explanation)") {
                    Button("Try Again") { Task { await library.retry(focused) } }
                        .buttonStyle(.link)
                }
            } else if focused.showsScanProgress, let scan = focused.scanProgress {
                conditionStrip("clock.arrow.circlepath", .secondary,
                               "Scanning \(focused.name) — \(scan.itemsSeen) items so far.") {
                    Button("Stop") { focused.cancelScan() }.buttonStyle(.link)
                }
            } else if focused.hasIncompleteIndex {
                conditionStrip("exclamationmark.circle.fill", .orange,
                               "\(focused.name) is being re-indexed — search may be incomplete.") {
                    EmptyView()
                }
            }
        }
    }

    private func conditionStrip<Trailing: View>(
        _ symbol: String, _ tint: Color, _ message: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                trailing()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4))
            Divider()
        }
    }

    @ViewBuilder
    private var editorPaneBody: some View {
        VStack(spacing: 0) {
            collectionConditionBar
            if let attachment = selectedAttachment {
                FileViewerView(
                    file: attachment,
                    isPlaceholder: { url in
                        library.collection(containing: url).map { !$0.hasContent(url) } ?? false
                    },
                    prepare: { url in
                        await library.collection(containing: url)?.hydrateIfNeeded(url)
                    })
            } else if let activeEditor, let c = editorCollection {
                NoteEditorView(
                    editor: activeEditor,
                    backlinks: references.backlinks,
                    outgoingLinks: references.outgoingLinks,
                    unlinkedMentions: references.unlinkedMentions,
                    embedProvider: c.embedProvider,
                    git: c.git,
                    linkCandidates: c.search.linkTargets(),
                    tagCandidates: c.search.allTags(),
                    headingProvider: { c.search.headings(forName: $0) },
                    onOpenWikiLink: openWikiLink,
                    onOpenNote: { selectedNoteID = $0.id },
                    onLinkMention: linkMention,
                    onRenameNote: { renameSelectedNote(to: $0) },
                    onShowMindMap: {
                        if let url = selectedNote?.fileURL { openWindow(value: MindMapRef(url)) }
                    },
                    ai: aiActions,
                    selectionActions: selectionActions(in: c)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                // Where this collection actually lives. It used to be on the
                // sidebar's collection card, which the rail replaced — and a
                // vault in Dropbox behaves differently enough (online-only
                // files, Git guarded) that it must be visible somewhere.
                if let remote = focused.remote {
                    Divider().frame(height: 11)
                    Label("\(remote.store.providerName) (direct)", systemImage: "network")
                        .foregroundStyle(.secondary)
                        .help("A direct \(remote.store.providerName) collection over the provider's API. Note contents download as you open them, and edits sync back automatically.")
                    // A cache goes stale by definition, so asking is a command
                    // the user must be able to reach.
                    Button("Refresh") { Task { await focused.refreshFromProvider() } }
                        .buttonStyle(.link)
                        .help("Ask \(remote.store.providerName) what has changed since the last check.")
                } else if let provider = CloudProvider.name(for: focused.rootURL) {
                    Divider().frame(height: 11)
                    Label(provider, systemImage: CloudProvider.symbol)
                        .foregroundStyle(.secondary)
                        .help("This collection is stored in \(provider). Online-only notes download on demand.")
                }
                let onlineOnly = focused.notes.lazy.filter(\.isOnlineOnly).count
                if onlineOnly > 0 {
                    Divider().frame(height: 11)
                    Label("\(onlineOnly) online-only", systemImage: "icloud.and.arrow.down")
                        .foregroundStyle(.secondary)
                        .help("\(onlineOnly) note\(onlineOnly == 1 ? " is" : "s are") in the cloud but not downloaded. They appear in the list but aren't indexed until opened or downloaded.")
                }

                // A scan long enough to be worth mentioning. Nothing appears for
                // an ordinary vault, which finishes in well under the threshold.
                if focused.showsScanProgress, let scan = focused.scanProgress {
                    Divider().frame(height: 11)
                    if let fraction = scan.fraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .frame(width: 56)
                    } else {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    }
                    Text("Scanning \(scan.itemsSeen) item\(scan.itemsSeen == 1 ? "" : "s")…")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("Stop") { focused.cancelScan() }
                        .buttonStyle(.link)
                        .help("Stop scanning. What's been found is kept, and scanning resumes from here next time.")
                }

                // Say when the folder can't be read, and offer the two things
                // that make sense: look again, or let it go. Removing is the
                // user's call — a drive unplugged for an afternoon is not a
                // reason for the app to forget a collection.
                if case .unavailable(let reason) = focused.state {
                    Divider().frame(height: 11)
                    Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("\(reason.explanation) The notes listed are the last ones seen; edits are held until it's back.")
                    Button("Try Again") { Task { await library.retry(focused) } }
                        .buttonStyle(.link)
                    Button("Remove") { library.close(focused) }
                        .buttonStyle(.link)
                } else if !focused.showsNonNoteFiles, focused.hiddenFileCount > 0 {
                    Divider().frame(height: 11)
                    Label("\(focused.hiddenFileCount) file\(focused.hiddenFileCount == 1 ? "" : "s") hidden",
                          systemImage: "eye.slash")
                        .foregroundStyle(.secondary)
                        .help("Non-note files (PDFs, images, documents) aren't listed in this collection. Turn them back on in View ▸ Show Non-Note Files.")
                } else if focused.hasIncompleteIndex {
                    Divider().frame(height: 11)
                    Label("Re-indexing", systemImage: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                        .help("The system reported that it dropped file-change notifications, so this collection is being re-scanned. Search results may be incomplete until it finishes.")
                }
            }

            Spacer(minLength: 12)

            gitStatusButton
            statusBarButton("New note", "square.and.pencil") { newNote() }
            statusBarButton("Today's note", "calendar") { openTodaysNote() }
            statusBarButton("Graph view", "point.3.connected.trianglepath.dotted") { openWindow(id: "graph") }
                .disabled(focused?.notes.isEmpty ?? true)
                // The tip used to hang off the sidebar's Graph button; the
                // status bar is where that command still lives on screen.
                .popoverTip(GraphTip())
            statusBarButton("Ask your library", "sparkles.rectangle.stack") { openWindow(id: "askLibrary") }
                .disabled(library.allNotes.isEmpty)
            statusBarButton("Assistant", "sparkles") { openWindow(id: "assistant") }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    /// Git, in the status bar rather than at the foot of the rail — the branch
    /// and a dirty pip, opening the full panel.
    @ViewBuilder
    private var gitStatusButton: some View {
        if let collection = gitCollection, !collection.isRemote {
            Button {
                showGitPanel = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                    if let branch = collection.git.status.branch {
                        Text(branch).lineLimit(1)
                    }
                    if collection.git.status.isRepository && !collection.git.status.isClean {
                        Circle().fill(.orange).frame(width: 6, height: 6)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Git — branch, status, commit and sync for “\(collection.name)”")
            .popover(isPresented: $showGitPanel, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 8) { gitSection }
                    .padding(12)
                    .frame(width: 300)
            }
            Divider().frame(height: 11)
        }
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
            // Closing a tab is the user saying they're done with the note —
            // stop holding its parsed document.
            documents.forget(path: id.path)
            if selectedNoteID == id {
                selectedNoteID = next
            }
        }
    }

    private var outlineList: some View {
        NoteOutlineList(
            roots: cachedRoots,
            signature: cachedSignature,
            selection: $selectedNoteID,
            revealID: $revealOutlineID,
            focusedCollectionID: library.focusedID,
            accent: appearance.resolvedAccent,
            fontScale: appearance.textScale,
            // Every mode now shows collection group rows — the tree holds all
            // of them at once (D2) — so the owning collection is always read
            // from the group a node hangs under. The one exception is a tag
            // filter, whose rows are bare notes from the focused collection.
            scopedCollectionID: selectedTag == nil ? nil : focused?.id,
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
                if let folderID, let c = library.collections.first(where: { folderID == $0.id || folderID.hasPrefix($0.id + "/") }) {
                    Task {
                        if let note = await c.createNote(in: URL(fileURLWithPath: folderID, isDirectory: true)) {
                            selectedNoteID = note.id
                        }
                    }
                } else if let c = collection ?? railCollection ?? focused {
                    Task { if let note = await c.createNote() { selectedNoteID = note.id } }
                }
            },
            onNewFolder: { collection, folderID in
                if let folderID, let c = library.collections.first(where: { folderID == $0.id || folderID.hasPrefix($0.id + "/") }) {
                    newFolderParent = URL(fileURLWithPath: folderID, isDirectory: true)
                    newFolderCollection = c
                } else if let c = collection ?? railCollection ?? focused {
                    newFolderParent = nil
                    newFolderCollection = c
                }
                newFolderName = ""
            },
            onDeleteFolder: { folderID in
                // Deleting a folder trashes everything inside it — confirm first.
                pendingFolderDelete = URL(fileURLWithPath: folderID, isDirectory: true)
            },
            onMoveItem: { source, folder in moveItem(at: source, into: folder) }
        )
    }

    @ViewBuilder
    private var noteListEmptyState: some View {
        if library.isEmpty {
            ContentUnavailableView {
                Label("No Collections", systemImage: "folder")
            } description: {
                Text("Open a collection, an Obsidian vault, or a saved library to begin.")
            } actions: {
                Button("Open…") { showLauncher = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if isSearching {
            if searchResults.isEmpty && !isSearchInFlight {
                ContentUnavailableView.search(text: searchText)
            }
        } else if selectedTag == nil, let collection = focused, collection.notes.isEmpty,
                  library.collections.count == 1 {
            ContentUnavailableView {
                Label("No Notes", systemImage: "square.and.pencil")
            } description: {
                Text("“\(collection.name)” is empty. Create your first note to get started.")
            } actions: {
                Button("New Note") { newNote() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Outline items (NSOutlineView data)

    /// The outline tree for the current mode. Ordinarily the roots are the
    /// pinned places followed by every open collection, each expanding into its
    /// folders (D2) — search and a tag filter replace that with their results.
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
        } else if selectedTag != nil {
            // A tag filter is already scoped to one collection, so a group row
            // above it would say nothing the selection hasn't said.
            return taggedRows.map {
                NoteOutlineItem(id: $0.note.fileURL.path, kind: .note($0.note, snippet: nil))
            }
        } else {
            // One tree: the pinned places, then every open collection with its
            // folders nested beneath it (shell-chrome.md D2/D4). Apple Notes'
            // sidebar — `Quick Notes` and `Shared`, then a section per account.
            return pinnedPlaces + library.collections.map { collection in
                NoteOutlineItem(id: collection.id, kind: .collection(collection),
                                children: outlineItems(from: tree(for: collection),
                                                       prefix: collection.id))
            }
        }
    }

    /// Recents and Bookmarks, above the collections. Both span every open
    /// collection, which is exactly why they cannot be folders: there is no one
    /// place on disk they correspond to.
    ///
    /// A place with nothing in it is omitted rather than shown empty — an
    /// always-present "Bookmarks" that never opens teaches people to ignore it.
    private var pinnedPlaces: [NoteOutlineItem] {
        var places: [NoteOutlineItem] = []

        let recents = LibraryPlace.mostRecent(library.allNotes)
        if !recents.isEmpty {
            places.append(NoteOutlineItem(
                id: "hn:place:recents", kind: .place("Recents", symbol: "clock"),
                children: recents.map {
                    NoteOutlineItem(id: "hn:recents/" + $0.fileURL.path,
                                    kind: .note($0, snippet: nil))
                }))
        }

        let bookmarks = library.collections.flatMap {
            $0.bookmarks.bookmarkedNotes(from: $0.notes)
        }
        if !bookmarks.isEmpty {
            places.append(NoteOutlineItem(
                id: "hn:place:bookmarks", kind: .place("Bookmarks", symbol: "bookmark"),
                children: bookmarks.map {
                    NoteOutlineItem(id: "hn:bookmarks/" + $0.fileURL.path,
                                    kind: .note($0, snippet: nil))
                }))
        }
        return places
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
            // **Every** open collection is in the tree now (D2), so the key has
            // to name all of them. Keyed on one collection — which is what it
            // did while a rail scoped the tree to a single one — opening or
            // closing a collection left the key unchanged, so the outline never
            // rebuilt: a newly-opened vault never appeared and Close Collection
            // did nothing visible. Membership *and* each revision, because
            // either can change the tree.
            // The state rides along too: a collection going unavailable changes
            // how its row is drawn without changing its `revision` (nothing was
            // re-scanned — that is the whole point), so without it the row would
            // keep looking healthy.
            mode = "n:" + library.collections
                .map { "\($0.id)#\($0.revision)#\($0.state)#\($0.showsScanProgress)" }
                .joined(separator: ",")
        }
        // Pinned Recents/Bookmarks hang above the collections and are derived
        // from notes across all of them, so they ride the same revisions —
        // except bookmarking, which changes no revision and is counted here.
        let bookmarkCount = library.collections.reduce(0) { $0 + $1.bookmarks.paths.count }
        return "\(sortOrder.rawValue)|b\(bookmarkCount)|\(library.focusedID ?? "")"
             + "|\(appearance.textScale)|\(mode)"
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
              let text = try? FileIO.readString(at: note.fileURL),
              let updated = MentionScanner.linkingFirstMention(of: target.title, in: text) else { return }
        try? FileIO.write(Data(updated.utf8), to: note.fileURL)
        // The note set is unchanged (only one note's content), so no re-scan:
        // patch the index incrementally and suppress the watcher for our write.
        c.noteDidSave(note.fileURL, text: updated)
    }

    private func newNote() {
        guard let c = railCollection ?? focused else { return }
        Task { if let note = await c.createNote() { selectedNoteID = note.id } }
    }

    // MARK: - Daily notes & templates

    /// Open today's daily note in the focused collection, creating it if needed.
    private func openTodaysNote() {
        let name = TemplateExpander.dailyNoteName(for: .now, format: dailyDateFormat)
        let rel = dailyNoteFolder.isEmpty ? "\(name).md" : "\(dailyNoteFolder)/\(name).md"
        guard let c = railCollection ?? focused else { return }
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
              let raw = try? FileIO.readString(at: template.fileURL) else { return }
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
        hnJumpToHeadingInEditor(titled: title)
    }
}

/// A note list row: the note plus an optional search snippet.
private struct NoteRow: Identifiable {
    let note: Note
    let snippet: String?
    var id: Note.ID { note.id }
}

/// Presents `Collection.lastError` (a failed file operation) as an alert and
/// clears it on dismiss. Extracted from the shell body to keep it type-checkable.
private struct FileOperationErrorAlert: ViewModifier {
    var collection: Collection?
    func body(content: Content) -> some View {
        content.alert(
            "Couldn't complete that",
            isPresented: Binding(
                get: { collection?.lastError != nil },
                set: { if !$0 { collection?.lastError = nil } }
            ),
            presenting: collection?.lastError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0) }
    }
}

/// Confirms a folder "Move to Trash" (which trashes all its contents). Extracted
/// from the shell body to keep it type-checkable.
private struct FolderDeleteConfirmation: ViewModifier {
    @Binding var folder: URL?
    var onConfirm: (URL) -> Void
    func body(content: Content) -> some View {
        content.confirmationDialog(
            folder.map { "Move “\($0.lastPathComponent)” and its contents to the Trash?" } ?? "",
            isPresented: Binding(get: { folder != nil }, set: { if !$0 { folder = nil } }),
            titleVisibility: .visible,
            presenting: folder
        ) { f in
            Button("Move to Trash", role: .destructive) { onConfirm(f) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Everything inside the folder will be moved to the Trash. You can recover it from there.")
        }
    }
}
#endif
