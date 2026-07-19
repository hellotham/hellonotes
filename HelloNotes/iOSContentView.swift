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
    @State private var searchText = ""
    @State private var selectedNoteID: Note.ID?
    @State private var selectedTag: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
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
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredCompactColumn) {
            sidebar
        } content: {
            noteList
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result {
                Task { await openPicked(urls) }
            }
        }
        .sheet(isPresented: $showSettings) {
            iOSSettingsView(settings: appearance)
        }
        .task {
            if library.isEmpty {
                await library.restore()
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
                        Text(note.title)
                            .font(.headline)
                        Text(note.lastModified, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(note.id)
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
    }

    // MARK: - Column 3: Editor

    @ViewBuilder
    private var detail: some View {
        if let note = editor.note {
            Group {
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
