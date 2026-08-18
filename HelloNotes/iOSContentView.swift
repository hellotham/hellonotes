//
//  iOSContentView.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(iOS)
import SwiftUI
import MarkdownEditor
import UniformTypeIdentifiers

/// The iOS / iPadOS shell, arranged by `AdaptiveShell` exactly as macOS is: a
/// narrow library rail of *places*, the note list (or the Library place), the
/// editor, and an inspector where there is room. On iPad landscape all of them
/// show at once; in portrait the shell bands navigation across the top; on
/// iPhone it hands off to `CompactShell`, where the editor is the screen. Shares `Note`, `Library`, `Collection`, `EditorModel`, and
/// `CollectionSearchModel` with macOS. The live TextKit 2 editor now runs on
/// iOS too (`iOSLiveEditor`), sharing the NotesEditor package with macOS.
struct iOSContentView: View {
    @Environment(Library.self) private var library
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(LLMSettings.self) private var llmSettings
    @Environment(\.scenePhase) private var scenePhase

    /// How the editor presents the note (live Markdown / Preview / Split).
    @AppStorage("iosEditorViewMode") private var storedMode = EditorMode.edit.rawValue
    private var mode: EditorMode {
        EditorMode(rawValue: storedMode) ?? .edit
    }
    private var modeBinding: Binding<EditorMode> {
        Binding(get: { mode }, set: { storedMode = $0.rawValue })
    }

    @State private var editor = EditorModel()
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var showWelcome = false
    /// Onboarding is queued during launch but only presented once the splash
    /// overlay has faded, so it doesn't pop up over the splash.
    @State private var pendingWelcome = false
    /// First-run onboarding, shown once on a brand-new install.
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @State private var searchText = ""
    @State private var selectedNoteID: Note.ID?
    @State private var selectedTag: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// The right inspector rail, remembered per scene (decision 10). Off by
    /// default on iPad: a reader wants the note, not the apparatus.
    @SceneStorage("inspectorPresented") private var inspectorPresented = false

    /// Compact only: which place the bottom tab bar is showing, and whether the
    /// open note is filling the screen rather than sitting in the mini strip.
    @State private var place: CompactPlace = .notes
    @State private var noteIsExpanded = false

    /// The open note's front-matter properties, edited in the inspector.
    @State private var properties: [Property] = []
    /// On iPhone (collapsed), open straight to the note list rather than the
    /// filter sidebar.
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .content

    /// Which place the library rail is on — `""` is the Library place, the
    /// sentinel means "never chosen", so a first launch lands in the notes.
    @SceneStorage("railPlace") private var railPlaceID = iOSContentView.railPlaceUnset
    static let railPlaceUnset = "?"

    /// Launch splash overlay; fades out after a beat (or on tap).
    @State private var showSplash = true
    /// The whole-note rewrite sheet, raised from the editor's toolbar menu.
    @State private var showRewriteNote = false

    /// An in-progress link review, carrying the text its ranges describe.
    private struct LinkReviewRequest: Identifiable {
        let id = UUID()
        let proposals: [LinkProposal]
        let noteText: String
    }
    @State private var linkReview: LinkReviewRequest?

    /// Write or research a new note — the Mac's ⌃⌘N, which on iOS lives beside
    /// New Note in the Library actions because that is the only fixed place a
    /// command about *creating* a note can be found.
    @State private var composer = NoteComposer()
    @State private var showCompose = false
    /// Research calls only read-only tools, so this is never consulted; it
    /// exists because `ToolContext` requires one.
    @State private var composePermissions = PermissionBroker()
    /// Ask Library, and the question it should open with (`nil` = ask fresh).
    @State private var showLibraryChat = false
    @State private var chatSeed: String?
    /// The agentic assistant, and the provider/key settings it needs. Both were
    /// macOS-only until 1.3 — and without the second, an iPad had no way to
    /// enter an API key at all, so every provider but Apple was unreachable.
    @State private var showAssistant = false
    @State private var showLLMSettings = false

    /// Which inspector tab is showing. Owned here rather than by the panel,
    /// because the toolbar is the panel's tab strip (`shell-chrome.md` D6).
    @AppStorage("inspectorTab") private var inspectorTabRaw = InspectorTab.outline.rawValue
    private var inspectorTab: InspectorTab {
        InspectorTab(rawValue: inspectorTabRaw) ?? .outline
    }

    /// The last AI request routed to the inspector from the editor's toolbar
    /// menu. Same mechanism as the Mac's menu bar — see `InspectorRequest`.
    @State private var inspectorRequest: InspectorRequest?

    private var focused: Collection? { library.focused }

    /// The collection the library rail is standing in, or `nil` on the Library
    /// place. Resolved by id every time, so closing it falls back to Library
    /// rather than dangling.
    private var railCollection: Collection? {
        library.collections.first { $0.id == railPlaceID }
    }

    private var railPlace: RailPlace {
        railCollection.map { .collection($0.id) } ?? .library
    }

    /// Search and a tag filter are questions about the library and override the
    /// rail's scope; otherwise the Library place owns the note-list column.
    private var showsLibraryPlace: Bool {
        railPlace == .library && searchText.isEmpty && selectedTag == nil
    }

    /// Open picked folders, expanding any that are (or contain) Obsidian vaults
    /// — so choosing an iCloud Drive folder full of vaults opens each of them.
    private func openPicked(_ urls: [URL]) async {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            let vaults = ObsidianVault.discoverVaults(in: url)
            if vaults.isEmpty {
                await library.open(url: url)
            } else {
                // Hold the picked folder's security scope while opening each
                // child vault. A discovered child URL is not itself picker- or
                // bookmark-scoped, so `Collection.activate`'s own
                // startAccessingSecurityScopedResource() returns false; without
                // the parent scope held, the vault would open (and bookmark)
                // as an empty collection.
                for vault in vaults { await library.open(url: vault) }
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
    }

    /// Tags of the focused collection.
    private var tags: [String] { (railCollection ?? focused)?.search.allTags() ?? [] }

    /// Notes shown in the list — the focused collection's notes, filtered by the
    /// active tag or the search field.
    private var displayedNotes: [Note] {
        // Scoped by the rail, falling back to the focused collection so a
        // search or tag filter still has somewhere to look from the Library
        // place.
        guard let scope = railCollection ?? focused else { return [] }
        if let selectedTag {
            return scope.search.notesTagged(selectedTag)
        }
        guard !searchText.isEmpty else { return scope.notes }
        return scope.notes.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        AdaptiveShell(
            inspectorPresented: $inspectorPresented,
            columnVisibility: $columnVisibility,
            // Touch sizing: 44pt targets, and the keyboard accessory bar
            // instead of a persistent format bar (decision 3).
            prefersTouch: true,
            sidebar: { collectionTree },
            pane: { detail },
            inspector: { inspector },
            compact: { compactShell }
        )
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result {
                Task { await openPicked(urls) }
            }
        }
        .sheet(isPresented: $showSettings) {
            iOSSettingsView(settings: appearance)
        }
        // Ask Library, which iOS simply did not have. The Mac gives it a window;
        // a sheet is the same thing on a platform with one window.
        .sheet(isPresented: $showLibraryChat, onDismiss: { chatSeed = nil }) {
            NavigationStack {
                LibraryChatView(intelligence: IntelligenceService(settings: llmSettings),
                                notes: library.allNotes,
                                searches: library.collections.map(\.search),
                                onOpenNote: { note in
                                    showLibraryChat = false
                                    selectedNoteID = note.id
                                },
                                initialQuestion: chatSeed)
            }
        }
        .sheet(isPresented: $showAssistant) {
            NavigationStack {
                AssistantHost().navigationTitle("Assistant")
            }
        }
        .sheet(isPresented: $showCompose, onDismiss: { composer.reset() }) {
            NavigationStack {
                ComposeNoteView(
                    composer: composer,
                    availability: { NoteComposer.unavailableReason(for: $0, settings: llmSettings) },
                    onRun: { prompt, mode, depth in runCompose(prompt, mode: mode, depth: depth) },
                    onCreate: { draft in
                        guard let scope = railCollection ?? focused else { return }
                        Task {
                            if let note = await composer.create(draft, in: scope) {
                                selectedNoteID = note.id
                                place = .notes
                            }
                        }
                    })
            }
        }
        .sheet(isPresented: $showLLMSettings) {
            NavigationStack {
                LLMSettingsView(settings: llmSettings)
            }
        }
        .sheet(isPresented: $showWelcome, onDismiss: { hasSeenWelcome = true }) {
            WelcomeView(
                onOpenCollection: { showWelcome = false; showImporter = true },
                onOpenObsidian: { showWelcome = false; showImporter = true },
                onDismiss: { showWelcome = false }
            )
        }
        .task {
            // Not under a test host — see TestEnvironment.
            guard !TestEnvironment.isRunningTests else { return }
            if library.isEmpty {
                await library.restore()
                if library.isEmpty && !hasSeenWelcome { pendingWelcome = true }
            }
            // A window whose rail has never been moved opens in the focused
            // collection, not on the Library place: the notes are the point.
            if railPlaceID == Self.railPlaceUnset { railPlaceID = library.focusedID ?? "" }
        }
        .onChange(of: showSplash) { _, visible in
            // Present onboarding only after the launch splash has faded.
            if !visible && pendingWelcome {
                pendingWelcome = false
                showWelcome = true
            }
        }
        .onChange(of: library.focusedID) { _, newID in
            // Switching collections resets the in-collection filter.
            selectedTag = nil
            searchText = ""
            // **Only deselect a note that the new focus doesn't contain.**
            // This used to clear the selection unconditionally, so any focus
            // change — including one the app made itself while opening a note
            // in another collection — closed whatever was on screen. Nothing
            // outside the editor may close the file being edited.
            if let selectedNoteID,
               !library.allNotes.contains(where: { $0.id == selectedNoteID
                   && library.collection(containing: $0.fileURL)?.id == newID }) {
                self.selectedNoteID = nil
            }
            // The rail follows the focus while it is standing in a collection;
            // on the Library place it stays put — you went there on purpose.
            if railPlace != .library, let newID { railPlaceID = newID }
        }
        .onChange(of: library.collections.count) { was, now in
            if was == 0, now > 0, railPlace == .library { railPlaceID = library.focusedID ?? "" }
        }
        .onChange(of: selectedNoteID) { _, newID in
            // A selection that resolves to nothing must not blank the editor.
            // The same bare lookup on macOS was the "populated sidebar, clicks
            // do nothing" bug; here the failure is worse, because opening `nil`
            // actively closes the open note. Deselecting is the one case where
            // clearing is what was asked for.
            guard let newID else { Task { await editor.open(nil) }; return }
            guard let note = library.allNotes.first(where: { $0.id == newID }) else { return }
            Task { await editor.open(note) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                Task { await editor.flush() }
            }
        }
        .overlay {
            if showSplash {
                SplashScreenView { withAnimation(.easeOut(duration: 0.5)) { showSplash = false } }
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .task {
                        try? await Task.sleep(for: .seconds(2.8))
                        withAnimation(.easeOut(duration: 0.5)) { showSplash = false }
                    }
            }
        }
    }

    // MARK: - Column 1: the collection tree

    /// The same single sidebar the Mac has (`docs/shell-chrome.md` D2/D4):
    /// Recents and Bookmarks pinned above one section per open collection.
    ///
    /// It replaced a rail plus a note-list column for the structural reason set
    /// out in `ShellMetrics.sidebarIdeal` — the collapsible panel has to be
    /// column one to get the platform's toggle. On iPhone the shell hands off to
    /// `CompactShell` before reaching here, where a sidebar beside a 375pt
    /// screen would be absurd; there the collection list keeps its own tab.
    private var collectionTree: some View {
        List(selection: $selectedNoteID) {
            if !LibraryPlace.mostRecent(library.allNotes).isEmpty {
                DisclosureGroup {
                    ForEach(LibraryPlace.mostRecent(library.allNotes)) { note in
                        Text(note.title).tag(note.id)
                    }
                } label: {
                    Label("Recents", systemImage: "clock")
                }
            }
            if !bookmarkedNotes.isEmpty {
                DisclosureGroup {
                    ForEach(bookmarkedNotes) { note in
                        Text(note.title).tag(note.id)
                    }
                } label: {
                    Label("Bookmarks", systemImage: "bookmark")
                }
            }
            ForEach(library.collections) { collection in
                Section(collection.name) {
                    ForEach(notes(in: collection)) { note in
                        Text(note.title).tag(note.id)
                    }
                }
            }
        }
        .navigationTitle("Collections")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showImporter = true } label: {
                    Label("Open Collection", systemImage: "plus")
                }
            }
        }
    }

    private var bookmarkedNotes: [Note] {
        library.collections.flatMap { $0.bookmarks.bookmarkedNotes(from: $0.notes) }
    }

    /// One collection's notes, narrowed by whatever filter is active. iPad has
    /// never shown folders in this column, so this stays flat — merging the
    /// *collections* into the tree is the change, not adding a folder level the
    /// platform never had.
    private func notes(in collection: Collection) -> [Note] {
        if let selectedTag { return collection.search.notesTagged(selectedTag) }
        guard !searchText.isEmpty else { return collection.notes }
        return collection.notes.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    /// Moving the rail is a navigation: it clears whatever was narrowing the
    /// note list, so switching collections never lands in the previous one's
    /// empty tag filter.
    private func select(_ place: RailPlace) {
        selectedTag = nil
        searchText = ""
        selectedNoteID = nil
        preferredCompactColumn = .content
        switch place {
        case .library: railPlaceID = ""
        case .collection(let id): railPlaceID = id
        }
    }

    // MARK: - Compact: the collection list as its own place

    @ViewBuilder
    private var collectionsList: some View {
        List {
            if library.isEmpty {
                Section {
                    Button("Open Collection") { showImporter = true }
                }
            } else {
                Section("Collections") {
                    ForEach(library.collections) { collection in
                        collectionRow(collection)
                    }
                }

                Section {
                    filterRow(title: "All Notes", systemImage: "tray.full", isSelected: selectedTag == nil) {
                        selectedTag = nil
                    }
                }

                // Tags are not here. The library rail answers "where is it?";
                // tags are cross-cutting and belong to the inspector, or to
                // their own place in the compact tab bar (decision 1).
            }
        }
        .listStyle(.sidebar)   // native inset/grouped source-list appearance (esp. iPad)
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !library.isEmpty {
                        Button {
                            guard let c = focused else { return }
                            Task { if let note = await c.createNote() { selectedNoteID = note.id } }
                        } label: {
                            Label("New Note", systemImage: "square.and.pencil")
                        }
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label("Open Collection", systemImage: "folder.badge.plus")
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label("Open Obsidian Vault…", systemImage: "shippingbox")
                    }
                    Divider()
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings…", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More actions")
            }
        }
    }

    /// A collection row: tap to focus it (and show its notes); swipe to close.
    private func collectionRow(_ collection: Collection) -> some View {
        Button {
            // Compact has no rail, but it shares the rail's scope: without
            // this the list would keep showing whichever collection the rail
            // was left on at iPad size.
            select(.collection(collection.id))
            library.focus(collection)
        } label: {
            HStack {
                Label(collection.name, systemImage: "books.vertical")
                    .fontWeight(collection.id == focused?.id ? .semibold : .regular)
                Spacer()
                Text("\(collection.notes.count)")
                    .foregroundStyle(.secondary)
                if collection.id == focused?.id {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .foregroundStyle(.primary)
        .swipeActions(edge: .trailing) {
            // Closing a collection loses no data, so no destructive red —
            // gray, like Mail's non-destructive swipe actions.
            Button {
                library.close(collection)
            } label: {
                Label("Close", systemImage: "xmark.circle")
            }
            .tint(.gray)
        }
    }

    private func filterRow(title: String, systemImage: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            preferredCompactColumn = .content   // on iPhone, push to the note list
        } label: {
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
            if showsLibraryPlace || library.isEmpty {
                LibraryPlace(
                    actions: libraryActions,
                    recents: LibraryPlace.mostRecent(library.allNotes),
                    bookmarks: library.collections.flatMap {
                        $0.bookmarks.bookmarkedNotes(from: $0.notes)
                    },
                    selection: selectedNoteID,
                    accent: appearance.resolvedAccent,
                    onOpenNote: { note in
                        selectedTag = nil
                        searchText = ""
                        selectedNoteID = note.id
                    },
                    onOpenLibrary: { showImporter = true },
                    isEmptyLibrary: library.isEmpty
                )
            } else {
                List(displayedNotes, selection: $selectedNoteID) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(note.title)
                                .font(.headline)
                            if note.isOnlineOnly {
                                Image(systemName: "icloud.and.arrow.down")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .accessibilityLabel("Online only — not downloaded")
                            }
                        }
                        Text(note.lastModified, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(note.id)
                    .swipeActions(edge: .leading) {
                        if note.isOnlineOnly {
                            Button {
                                try? FileIO.download(at: note.fileURL)
                            } label: {
                                Label("Download", systemImage: "arrow.down.circle")
                            }
                            .tint(.blue)
                        }
                    }
                }
                .searchable(text: $searchText, prompt: "Search \(railCollection?.name ?? "notes")")
                .overlay {
                    if displayedNotes.isEmpty {
                        ContentUnavailableView("No Notes", systemImage: "doc.text")
                    }
                }
            }
        }
        .navigationTitle(noteListTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !library.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        guard let c = railCollection ?? focused else { return }
                        Task { if let note = await c.createNote() { selectedNoteID = note.id } }
                    } label: {
                        Label("New Note", systemImage: "square.and.pencil")
                    }
                    .disabled(focused == nil)
                }
            }
        }
    }

    private var noteListTitle: String {
        if let selectedTag { return "#\(selectedTag)" }
        return railCollection?.name ?? "Library"
    }

    /// Library-wide commands, shown in the Library place. The iPad has no
    /// separate Graph / Ask Library / Assistant windows, so this is the short
    /// list the platform actually has.
    private var libraryActions: [LibraryPlace.Action] {
        let scope = railCollection ?? focused
        return [
            .init(title: "New Note", symbol: "square.and.pencil", isEnabled: scope != nil) {
                guard let scope else { return }
                Task { if let note = await scope.createNote() { selectedNoteID = note.id } }
            },
            .init(title: "New Note from a Prompt…", symbol: "sparkles.square.filled.on.square",
                  isEnabled: scope != nil) { showCompose = true },
            .init(title: "Open Collection", symbol: "folder.badge.plus") { showImporter = true },
            // Reachable deliberately, not only by selecting a phrase — the
            // question you want to ask your notes usually isn't already in one.
            .init(title: "Ask Your Library", symbol: "sparkles.rectangle.stack",
                  isEnabled: !library.allNotes.isEmpty) {
                chatSeed = nil
                showLibraryChat = true
            },
            .init(title: "Assistant", symbol: "sparkles", isEnabled: scope != nil) {
                showAssistant = true
            },
            .init(title: "AI Settings…", symbol: "brain") { showLLMSettings = true },
            .init(title: "Settings…", symbol: "gearshape") { showSettings = true },
        ]
    }

    /// Rename from the inline title. Goes through the collection so the file
    /// moves *and* every `[[wiki-link]]` to it is rewritten.
    private func renameNote(_ note: Note, to title: String) {
        guard let collection = library.collection(containing: note.fileURL) else { return }
        Task {
            // Renaming moves the file; an in-flight autosave would be writing
            // to the old path.
            await editor.flush()
            if let renamed = await collection.renameNote(note, to: title) {
                selectedNoteID = renamed.id
            }
        }
    }

    /// Tags as their own place in the compact tab bar — the phone has no
    /// inspector rail to keep them in, and they are still how people navigate
    /// across a vault rather than down it.
    private var tagList: some View {
        Group {
            if tags.isEmpty {
                ContentUnavailableView("No Tags", systemImage: "number",
                                       description: Text("Tags you write as #tag in a note appear here."))
            } else {
                List {
                    filterRow(title: "All Notes", systemImage: "tray.full",
                              isSelected: selectedTag == nil) {
                        selectedTag = nil
                        place = .search
                    }
                    ForEach(tags, id: \.self) { tag in
                        filterRow(title: tag, systemImage: "number",
                                  isSelected: selectedTag == tag) {
                            selectedTag = tag
                            searchText = ""
                            // Picking a tag is a request to see its notes.
                            place = .search
                        }
                    }
                }
            }
        }
        .navigationTitle("Tags")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - The inspector rail (right)

    /// The same rail the Mac has, on the iPad shells wide or tall enough for
    /// it. Below that it isn't offered at all — every point goes to the list
    /// and the text, which is exactly where they are tightest.
    @ViewBuilder
    private var inspector: some View {
        if let collection = focused {
            NoteInspector(
                noteText: editor.text,
                onSelectHeading: { scrollToHeading($0.title) },
                summarize: { text in
                    try await IntelligenceService(settings: llmSettings).summarize(text)
                },
                onInsertSummary: { editor.text = NoteEdits.insertingSummaryCallout($0, into: editor.text) },
                allTags: collection.search.allTags(),
                noteCount: { collection.search.notesTagged($0).count },
                selectedTag: Binding(
                    get: { selectedTag },
                    set: { selectedTag = $0; if $0 != nil { searchText = "" } }
                ),
                suggestTags: { text, existing in
                    try await IntelligenceService(settings: llmSettings)
                        .suggestTags(for: text, existing: existing)
                },
                onInsertTag: { editor.text = NoteEdits.addingTag($0, to: editor.text) },
                backlinks: editor.note.map {
                    collection.linkGraph.backlinks(for: $0, in: collection.notes)
                } ?? [],
                outgoingLinks: editor.note.map {
                    collection.linkGraph.outgoingLinks(for: $0, in: collection.notes)
                } ?? [],
                // Unlinked mentions need a Spotlight query the iOS shell does
                // not run yet; the other two come straight from the index.
                unlinkedMentions: [],
                onOpenNote: { selectedNoteID = $0.id },
                onLinkMention: { _ in },
                linkCandidates: collection.search.linkTargets(),
                suggestLinks: { text, _ in
                    // Retrieval first, model second — see the Mac's
                    // `suggestLinks(for:in:)` for why the full title list is
                    // the wrong candidate set.
                    let neighbours = await collection.relatedNotes(
                        to: text, excluding: editor.note?.fileURL, limit: 40)
                    guard !neighbours.isEmpty else { return [] }
                    return try await IntelligenceService(settings: llmSettings)
                        .suggestLinks(for: text, candidates: neighbours.map(\.title))
                },
                onInsertLink: { editor.text = NoteEdits.addingRelatedLink($0, to: editor.text) },
                properties: $properties,
                onPropertiesChanged: {
                    editor.text = FrontMatter.applying(properties, to: editor.text)
                },
                fileURL: editor.note?.fileURL,
                git: collection.git,
                onRestoreRevision: { editor.text = $0 },
                tab: inspectorTab,
                request: inspectorRequest
            )
        } else {
            ContentUnavailableView("No Collection", systemImage: "sidebar.right",
                                   description: Text("Open a collection to inspect its notes."))
        }
    }

    /// Heading navigation is a notification, so it reaches the editor from
    /// anywhere in the shell — the rail is the editor's sibling, not its parent.
    ///
    /// The iOS editor host does not consume this yet: `MarkdownEditorView`
    /// exposes no `EditorProxy` on iOS, so there is nothing to drive the scroll
    /// with. Posting it anyway means the outline starts working the moment the
    /// package grows that seam, rather than needing this rewired.
    private func scrollToHeading(_ title: String) {
        NotificationCenter.default.post(name: .hnEditorFindQuery, object: nil,
                                        userInfo: ["query": title])
    }

    // MARK: - Compact: the editor is the screen

    /// Phone-sized: places in a bottom tab bar, the open note above it as a
    /// mini strip, one tap from full screen (decisions 6 and 11).
    private var compactShell: some View {
        CompactShell(
            place: $place,
            openNoteTitle: editor.note?.title,
            noteIsExpanded: $noteIsExpanded,
            places: { place in
                NavigationStack {
                    switch place {
                    case .notes:  collectionsList
                    // The same list, with its search field already up — the
                    // tab means "start typing", not a different set of notes.
                    case .search: noteList
                    case .tags:   tagList
                    }
                }
            },
            editor: { detail }
        )
    }

    // MARK: - Column 3: Editor

    @ViewBuilder
    private var detail: some View {
        if let note = editor.note {
            VStack(spacing: 0) {
                if appearance.showInlineTitle {
                    InlineNoteTitle(
                        title: note.title,
                        theme: EditorTheme(fontSize: appearance.editorFontSize),
                        onRename: { renameNote(note, to: $0) }
                    )
                }
                switch mode {
                case .edit:
                    liveEditor(note)
                case .markdown:
                    sourceEditor
                case .split:
                    splitEditor(note)
                default:
                    preview(note)
                }
            }
            // S3: the detail column is a viewport, whatever mode it is in.
            // Without the clamp the editor's or preview's ideal height sizes
            // the column, and the split view follows it past the screen.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(note.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    reviewLinksButton
                }
                ToolbarItem(placement: .topBarTrailing) {
                    aiMenu
                }
                ToolbarItem(placement: .topBarTrailing) {
                    modePicker
                }
            }
            .sheet(item: $linkReview) { review in
                NavigationStack {
                    ReviewLinksView(
                        proposals: review.proposals,
                        noteText: review.noteText,
                        preview: { focused?.openingLines(of: $0) ?? "" },
                        onFinish: { applyAcceptedLinks($0, reviewedText: review.noteText) },
                        onDecline: { focused?.declineLink($0) }
                    )
                }
            }
            .sheet(isPresented: $showRewriteNote) {
                NavigationStack {
                    RewriteSelectionView(
                        intelligence: IntelligenceService(settings: llmSettings),
                        original: FrontMatter.body(of: editor.text),
                        onReplace: { replaceBody(with: $0) },
                        onInsertBelow: { editor.text = editor.text.trimmingTrailingNewlines() + "\n\n\($0)\n" },
                        subject: .wholeNote
                    )
                }
            }
        } else {
            ContentUnavailableView(
                "Select a Note",
                systemImage: "doc.text",
                description: Text("Choose a note from the list, or create a new one.")
            )
        }
    }

    // MARK: - AI on the open note
    //
    // iOS has no menu bar, so the toolbar is the *only* fixed place a command
    // can live. Same four actions as the Mac, landing in the same inspector
    // tabs — the answer belongs with the thing it is about on both platforms,
    // and only the route to it differs.

    @ViewBuilder
    private var aiMenu: some View {
        let intelligence = IntelligenceService(settings: llmSettings)
        if intelligence.isAvailable {
            Menu {
                Button("Summarise Note", systemImage: "text.append") { askInspector(.summarize) }
                Button("Suggest Tags", systemImage: "number") { askInspector(.suggestTags) }
                Button("Suggest Links", systemImage: "link.badge.plus") { askInspector(.suggestLinks) }
                Divider()
                Button("Rewrite or Expand Note…", systemImage: "wand.and.stars") { showRewriteNote = true }
                Divider()
                Text("via \(intelligence.providerName)")
            } label: {
                Image(systemName: "sparkles")
            }
        }
    }

    /// Review Links is its own toolbar button rather than an item in the AI
    /// menu: it is an exact text scan and works with no provider configured, so
    /// burying it under a sparkles icon would hide a working feature behind a
    /// setting it does not need.
    @ViewBuilder
    private var reviewLinksButton: some View {
        if editor.note != nil, focused != nil {
            Button { beginLinkReview() } label: {
                Image(systemName: "link.badge.plus")
            }
            .help("Find links this note names but doesn't make")
        }
    }

    /// Start a composition run against the collection the rail is showing.
    private func runCompose(_ prompt: String, mode: NoteComposer.Mode, depth: Int) {
        guard let scope = railCollection ?? focused else { return }
        switch mode {
        case .write:
            composer.compose(prompt: prompt, in: scope, settings: llmSettings)
        case .research:
            composer.research(
                question: prompt, depth: depth,
                context: ToolContext(collection: scope, search: scope.search, git: scope.git,
                                     permissions: composePermissions, settings: llmSettings),
                settings: llmSettings)
        }
    }

    /// See the Mac's `beginLinkReview()` — proposals are generated once, up
    /// front, because every range is an offset into the text as it is now.
    private func beginLinkReview() {
        guard let collection = focused else { return }
        let text = editor.text
        Task {
            let found = await collection.linkProposals(in: text, for: editor.note?.fileURL)
            linkReview = LinkReviewRequest(proposals: found, noteText: text)
        }
    }

    private func applyAcceptedLinks(_ accepted: [LinkProposal], reviewedText: String) {
        guard !accepted.isEmpty else { return }
        guard editor.text == reviewedText else {
            focused?.lastError = "The note changed while you were reviewing, so no links were added. Run Review Links again."
            return
        }
        editor.text = LinkProposals.apply(accepted, to: editor.text)
    }

    /// Reveal the tab that shows this kind of answer, then ask for it.
    ///
    /// The reveal matters more here than on the Mac: the iOS rail defaults to
    /// *closed*, so without it every one of these commands would appear to do
    /// nothing at all.
    private func askInspector(_ kind: InspectorRequest.Kind) {
        let request = InspectorRequest(kind: kind, token: (inspectorRequest?.token ?? 0) + 1)
        inspectorTabRaw = request.tab.rawValue
        inspectorPresented = true
        inspectorRequest = request
    }

    /// Replace the note's body, keeping any front matter.
    private func replaceBody(with text: String) {
        let full = editor.text
        let body = FrontMatter.body(of: full)
        editor.text = body.count < full.count ? String(full.dropLast(body.count)) + text : text
    }

    /// The shared TextKit 2 live editor (inline styling, caret-driven reveal,
    /// list bullets, callouts, heading rules, checkboxes).
    private func liveEditor(_ note: Note) -> some View {
        iOSLiveEditor(
            editor: editor,
            note: note,
            collection: focused,
            fontSize: appearance.editorFontSize,
            onOpenWikiLink: { openWikiLink($0) },
            selectionActions: focused.map(selectionActions(in:))
        )
    }

    /// What the collection can do with a selected phrase — the same three the
    /// Mac offers, reached through the system edit menu.
    private func selectionActions(in collection: Collection) -> SelectionActions {
        SelectionActions(
            linkTarget: { phrase in
                // Exact and case-insensitive, nothing looser: a wrong link
                // corrupts the graph silently. Meaning-based candidates belong
                // behind a review step, not behind one tap.
                let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !phrase.isEmpty else { return nil }
                return collection.search.linkTargets().first {
                    $0.caseInsensitiveCompare(phrase) == .orderedSame
                }
            },
            findRelated: { phrase in
                selectedTag = nil
                searchText = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
                // The phone hides the list behind the editor, so a search whose
                // results are on another screen has to bring you to that screen.
                place = .search
                noteIsExpanded = false
            },
            explain: { phrase in
                chatSeed = "Explain this, using my notes: \(phrase)"
                showLibraryChat = true
            }
        )
    }

    /// Resolve a `[[wiki-link]]` tap to a note in the focused collection and
    /// select it (create-on-miss is a macOS-only nicety for now).
    private func openWikiLink(_ target: String) {
        let base = target.split(separator: "#", maxSplits: 1).first.map(String.init) ?? target
        guard let c = focused,
              let match = c.notes.first(where: { $0.title.localizedCaseInsensitiveCompare(base) == .orderedSame })
        else { return }
        selectedNoteID = match.id
    }

    /// Raw Markdown source editor, bound straight to the note buffer.
    private var sourceEditor: some View {
        TextEditor(text: Binding(get: { editor.text }, set: { editor.text = $0 }))
            .font(.system(size: appearance.editorFontSize, design: .monospaced))
            .padding(.horizontal, 4)
    }

    /// Read-only rendered preview (WKWebView over the shared HTML export).
    private func preview(_ note: Note) -> some View {
        MarkdownWebView(
            markdown: editor.text,
            title: note.title,
            baseURL: note.fileURL.deletingLastPathComponent(),
            fontScale: appearance.textScale
        )
    }

    /// Source + preview together — side by side on a wide (landscape) screen,
    /// stacked on a tall (portrait) one.
    private func splitEditor(_ note: Note) -> some View {
        GeometryReader { geo in
            let sideBySide = geo.size.width >= geo.size.height
            let layout = sideBySide
                ? AnyLayout(HStackLayout(spacing: 0))
                : AnyLayout(VStackLayout(spacing: 0))
            layout {
                sourceEditor
                Divider()
                preview(note)
            }
        }
    }

    /// Preview / Markdown / Split switcher.
    private var modePicker: some View {
        Picker("View mode", selection: modeBinding) {
            ForEach(EditorMode.iOSCases) { m in
                Image(systemName: m.symbol)
                    .accessibilityLabel(m.label)
                    .tag(m)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}
#endif
