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

/// The iOS / iPadOS shell. A three-column `NavigationSplitView` mirrors the
/// macOS app: a navigation sidebar listing every open collection (plus the
/// focused collection's All Notes + `#tags` filter), the note list, and the
/// editor. On iPad landscape all three columns show at once (like macOS); on
/// iPad portrait the sidebar tucks behind a toggle; on iPhone it collapses to a
/// push stack. Shares `Note`, `Library`, `Collection`, `EditorModel`, and
/// `CollectionSearchModel` with macOS. The live TextKit 2 editor now runs on
/// iOS too (`iOSLiveEditor`), sharing the NotesEditor package with macOS.
struct iOSContentView: View {
    @Environment(Library.self) private var library
    @Environment(AppearanceSettings.self) private var appearance
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

    /// Launch splash overlay; fades out after a beat (or on tap).
    @State private var showSplash = true

    private var focused: Collection? { library.focused }

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
    private var tags: [String] { focused?.search.allTags() ?? [] }

    /// Notes shown in the list — the focused collection's notes, filtered by the
    /// active tag or the search field.
    private var displayedNotes: [Note] {
        guard let focused else { return [] }
        if let selectedTag {
            return focused.search.notesTagged(selectedTag)
        }
        guard !searchText.isEmpty else { return focused.notes }
        return focused.notes.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        AdaptiveShell(
            inspectorPresented: $inspectorPresented,
            columnVisibility: $columnVisibility,
            // Touch sizing: 44pt targets, and the keyboard accessory bar
            // instead of a persistent format bar (decision 3).
            prefersTouch: true,
            libraryRail: { sidebar },
            noteList: { noteList },
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
        .sheet(isPresented: $showWelcome, onDismiss: { hasSeenWelcome = true }) {
            WelcomeView(
                onOpenCollection: { showWelcome = false; showImporter = true },
                onOpenObsidian: { showWelcome = false; showImporter = true },
                onDismiss: { showWelcome = false }
            )
        }
        .task {
            if library.isEmpty {
                await library.restore()
                if library.isEmpty && !hasSeenWelcome { pendingWelcome = true }
            }
        }
        .onChange(of: showSplash) { _, visible in
            // Present onboarding only after the launch splash has faded.
            if !visible && pendingWelcome {
                pendingWelcome = false
                showWelcome = true
            }
        }
        .onChange(of: library.focusedID) { _, _ in
            // Switching collections resets the in-collection filter/selection.
            selectedTag = nil
            searchText = ""
            selectedNoteID = nil
        }
        .onChange(of: selectedNoteID) { _, newID in
            let note = library.allNotes.first { $0.id == newID }
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

    // MARK: - Column 1: Navigation sidebar

    @ViewBuilder
    private var sidebar: some View {
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
            library.focus(collection)
            preferredCompactColumn = .content   // on iPhone, push to the note list
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
            if library.isEmpty {
                ContentUnavailableView {
                    Label("No Collections", systemImage: "folder")
                } description: {
                    Text("Open one or more folders of Markdown files to begin.")
                } actions: {
                    Button("Open Collection") { showImporter = true }
                        .buttonStyle(.borderedProminent)
                }
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
                .searchable(text: $searchText, prompt: "Search \(focused?.name ?? "notes")")
                .overlay {
                    if (focused?.notes ?? []).isEmpty {
                        ContentUnavailableView("No Notes", systemImage: "doc.text")
                    }
                }
            }
        }
        .navigationTitle(selectedTag.map { "#\($0)" } ?? (focused?.name ?? "Notes"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !library.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        guard let c = focused else { return }
                        Task { if let note = await c.createNote() { selectedNoteID = note.id } }
                    } label: {
                        Label("New Note", systemImage: "square.and.pencil")
                    }
                    .disabled(focused == nil)
                }
            }
        }
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
                tagTree: collection.search.tagTree(),
                selectedTag: Binding(
                    get: { selectedTag },
                    set: { selectedTag = $0; if $0 != nil { searchText = "" } }
                ),
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
                properties: $properties,
                onPropertiesChanged: {
                    editor.text = FrontMatter.applying(properties, to: editor.text)
                },
                fileURL: editor.note?.fileURL,
                git: collection.git,
                onRestoreRevision: { editor.text = $0 }
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
                    case .notes:  sidebar
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
                    .padding(.horizontal, ShellMetrics.insets)
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
                    modePicker
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

    /// The shared TextKit 2 live editor (inline styling, caret-driven reveal,
    /// list bullets, callouts, heading rules, checkboxes).
    private func liveEditor(_ note: Note) -> some View {
        iOSLiveEditor(
            editor: editor,
            note: note,
            collection: focused,
            fontSize: appearance.editorFontSize,
            onOpenWikiLink: { openWikiLink($0) }
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
