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
import UIKit
// Explicit, for `URL: Transferable` — the payload the sidebar's drag-to-move
// carries. It arrives transitively through SwiftUI, and a conformance that
// happens to be visible is not the same as one that is imported.
import CoreTransferable

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
    /// Deep links and quick capture both route through this.
    @Environment(NavigationRouter.self) private var router
    /// Opens a standalone note window (a second iPadOS scene).
    @Environment(\.openWindow) private var openWindow
    /// Parsed editor documents, kept above the shell so a tab switch doesn't
    /// re-parse. Held here because a cached document also captured which
    /// `[[link]]` targets existed when it was built — see the `library.allNotes`
    /// handler, which must forget them when the note set moves.
    @Environment(EditorDocumentStore.self) private var documents
    @Environment(\.scenePhase) private var scenePhase

    /// How the editor presents the note (live Markdown / Preview / Split).
    @AppStorage("iosEditorViewMode") private var storedMode = EditorMode.edit.rawValue
    private var mode: EditorMode {
        EditorMode(rawValue: storedMode) ?? .edit
    }
    private var modeBinding: Binding<EditorMode> {
        Binding(get: { mode }, set: { storedMode = $0.rawValue })
    }

    /// One editor per open note, exactly as on the Mac.
    ///
    /// `EditorTabs` was already cross-platform — 117 lines, no `os(macOS)`
    /// anywhere — and simply unused here, so iPad had a single buffer and no
    /// tabs. Sharing it is what keeps flush-on-close, prune-with-flush and
    /// reconcile identical on both platforms rather than reimplemented once
    /// more.
    @State private var tabs = EditorTabs()
    /// Stands in when no note is open, so the 30-odd `editor.` call sites do
    /// not each have to answer "and if there is nothing open?". The detail
    /// column shows `ContentUnavailableView` in that state anyway.
    @State private var noEditor = EditorModel()
    private var editor: EditorModel { tabs.editor(withID: selectedNoteID) ?? noEditor }

    /// Every sidebar command, one implementation — see `ShellActions`. The
    /// shell owns the state a command reads and writes; what the command *does*
    /// is not platform-shaped and no longer lives here.
    private var actions: ShellActions {
        ShellActions(
            library: library, tabs: tabs, selection: $selectedNoteID,
            scope: railCollection ?? focused,
            renameTarget: $renameTarget, renameText: $renameText,
            newFolderCollection: $newFolderCollection,
            newFolderParent: $newFolderParent,
            newFolderName: $newFolderName,
            pendingFolderDelete: $pendingFolderDelete,
            expandedFolders: expandedFolders,
            openNoteWindow: { openWindow(value: NoteRef($0.fileURL)) },
            reviewLinks: { beginLinkReview() })
    }

    /// Open folders, per scene. Shared storage and shared conversion, because
    /// this was `@SceneStorage` on iPad and `@State` on the Mac — so relaunching
    /// restored the tree on one platform and collapsed it on the other.
    private var expandedFolders: Binding<Set<String>> {
        ExpandedFolders.binding($expandedFolderIDs)
    }
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var showWelcome = false
    /// Onboarding is queued during launch but only presented once the splash
    /// overlay has faded, so it doesn't pop up over the splash.
    @State private var pendingWelcome = false
    /// First-run onboarding, shown once on a brand-new install.
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @State private var searchText = ""
    /// The note being renamed, and the text field's contents. iOS had no rename
    /// anywhere except the inline title, which is a *setting* — turn it off and
    /// notes became unrenameable.
    @State private var renameTarget: Note?
    @State private var renameText = ""
    /// Which sidebar folders are open, by node id.
    ///
    /// `DisclosureGroup` with no `isExpanded` binding is collapsed on every
    /// appearance, so the tree forgot where you were each launch — on a vault
    /// with nested folders that means re-navigating from the root every time.
    @SceneStorage("expandedFolders") private var expandedFolderIDs = ""
    @State private var selectedNoteID: Note.ID?
    /// Reopen where you left off, exactly as the Mac does: the focused
    /// collection and the open note persist across relaunches as stable path
    /// identifiers rather than URLs. `railPlace` was already restored here, so
    /// an iPad came back to the right *tree* and an empty editor — and
    /// `library.focused` was left at whichever collection finished restore last.
    @SceneStorage("restoredCollectionID") private var restoredCollectionID = ""
    @SceneStorage("restoredNotePath") private var restoredNotePath = ""
    @State private var selectedTag: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Focus for the sidebar's search field. Edit ▸ Search All Collections
    /// (⌥⌘F) hands it focus over `hnFocusLibrarySearch`, the same notification
    /// the Mac uses — the command used to *clear* the selection instead, which
    /// closed the note you were reading and showed no field to type into.
    @FocusState private var searchFocused: Bool

    /// The right inspector rail, remembered per scene (decision 10). Off by
    /// default on iPad: a reader wants the note, not the apparatus.
    @SceneStorage("inspectorPresented") private var inspectorPresented = false

    /// Compact only: which place the bottom tab bar is showing, and whether the
    /// open note is filling the screen rather than sitting in the mini strip.
    @State private var place: CompactPlace = .notes
    @State private var noteIsExpanded = false

    /// On iPhone (collapsed), open straight to the note list rather than the
    /// filter sidebar.
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .content

    /// New-folder prompt state, driven from the sidebar's folder and collection
    /// menus. `Collection.createFolder` was cross-platform from the start and
    /// simply had no iOS caller, so an iPad could make notes and never a folder
    /// to put them in.
    /// Collections the user has folded away. Collapsed-set rather than
    /// expanded-set so a newly opened collection starts open, which is what a
    /// collection you just opened should do.
    @State private var collapsedCollections: Set<Collection.ID> = []

    @State private var newFolderCollection: Collection?
    @State private var newFolderParent: URL?
    @State private var newFolderName = ""
    /// A folder awaiting a confirmed "Move to Trash" — which trashes everything
    /// inside it, so it is confirmed rather than done on a tap, as on the Mac.
    @State private var pendingFolderDelete: URL?


    /// Searching the library — the same implementation the Mac runs.
    ///
    /// This was three `@State` fields plus a `scheduleContentSearch` that ran
    /// the identical two waves against the identical Spotlight index as the
    /// Mac's `scheduleSearch`, and then discarded both the snippets and the
    /// attachment hits — so a phrase living only inside a PDF was unfindable on
    /// this platform. See `LibrarySearch`.
    @State private var search = LibrarySearch()

    /// The sidebar tree — built, cached and keyed by `SidebarTreeModel`, which
    /// both shells share. Two caches under two different keys is how "show
    /// non-note files" came to do nothing on the Mac and a tag filter came to
    /// scope to a different collection on each platform.
    @State private var sidebarTree = SidebarTreeModel()

    /// Everything the sidebar tree is built from — and keyed on. One
    /// construction, shared: see `SidebarTree.inputs`.
    private var sidebarInputs: SidebarTree.Inputs {
        SidebarTree.inputs(library: library, appearance: appearance, search: search,
                           searchText: searchText, selectedTag: selectedTag,
                           // The sidebar's selection, per CLAUDE.md — anything
                           // keyed on a collection reads it, falling back to the
                           // focused collection when the rail is on Library.
                           scope: railCollection ?? focused)
    }

    /// Whether the open note is a Marp deck / holds Mermaid fences.
    ///
    /// Both used to be computed inline in `noteMenu`'s builder. `Menu(content:)`
    /// takes a non-escaping `ViewBuilder`, so both ran at construction time on
    /// the main actor — and `mermaidBlocks` is a whole-document regex with no
    /// early exit. Computed once here instead, off-main, against
    /// `docFeaturesKey`, which is the Mac's memoized `DocStats` with a cheaper
    /// key (see the `.task` for why the text itself is the wrong one here).
    @State private var docFeatures = NoteDocFeatures()

    /// Which place the library rail is on — `""` is the Library place, the
    /// sentinel means "never chosen", so a first launch lands in the notes.
    @SceneStorage("railPlace") private var railPlaceID = iOSContentView.railPlaceUnset
    static let railPlaceUnset = "?"

    /// Launch splash overlay; fades out after a beat (or on tap).
    @State private var showSplash = true
    /// The whole-note rewrite sheet, raised from the editor's toolbar menu.

    /// An in-progress link review, carrying the text its ranges describe.
    @State private var linkReview: LinkReviewFlow.Request?

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
    /// The agentic assistant, and the provider/key settings it needs. Both were
    /// macOS-only until 1.3 — and without the second, an iPad had no way to
    /// enter an API key at all, so every provider but Apple was unreachable.
    @State private var showAssistant = false
    @State private var showLLMSettings = false
    @State private var showOpenQuickly = false
    /// Marp deck. `SlidesView` was portable all along — the whole file is
    /// cross-platform apart from one web-view representable that already has a
    /// UIKit twin. Only the way in was missing: its sole caller was the macOS
    /// editor, so an iPad could hold a Marp deck and never present it.
    @State private var showClone = false
    @State private var showNewRepo = false
    /// The "open" launcher and its backing stores — recents plus saved
    /// libraries. Both stores were cross-platform from the day they were
    /// written; only `LauncherView` was gated, so iPad had nowhere to show
    /// them and `openLauncher` went straight to the file importer.
    @State private var showLauncher = false
    /// The direct-API cloud browser the menu bar asked for, if any.
    ///
    /// `AppActions.connectOverWeb` was nil on iOS, so File ▸ Connect Over the
    /// Web ▸ Dropbox… drew, enabled, and did nothing — while the very same four
    /// browsers were reachable from Settings. The capability was there; the
    /// command was not.
    @State private var cloudBrowser: CloudBrowser?
    @State private var recents = RecentsStore()
    @State private var libraries = LibrariesStore()
    @State private var showQuickCapture = false
    @State private var gitAccounts = GitAccountsStore()
    /// Spotlight names the files whose content mentions this note; only those
    /// few are read and verified. `SpotlightSearch` was macOS-gated despite
    /// `NSMetadataQuery` being Foundation, which is why the iPad's References
    /// tab showed backlinks and outgoing links but never unlinked mentions.
    @State private var referenceSpotlight = SpotlightSearch()
    @State private var unlinkedMentions: [Note] = []
    @State private var showGraph = false
    @State private var showMindMap = false
    @State private var showPalette = false
    @AppStorage("dailyNoteFolder") private var dailyNoteFolder = ""
    @AppStorage("dailyDateFormat") private var dailyDateFormat = "yyyy-MM-dd"

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

    /// The collection that owns what is selected, falling back to the focused
    /// one — the Mac's `editorCollection`, and for the same reason.
    ///
    /// Everything *about the open note* has to be asked of the note's own
    /// collection, not of whichever happens to be focused: its tags, its link
    /// candidates, its git repository and history, and the corpus a backlink or
    /// an unlinked mention is searched in. Keyed on `focused`, an iPad with two
    /// collections open showed the wrong collection's tags and came back with
    /// no backlinks at all. Derived from the selection's URL rather than from a
    /// resolved `Note`, so an attachment answers with its own collection too.
    private var editorCollection: Collection? {
        if let id = selectedNoteID, let owner = library.collection(containing: id) { return owner }
        return focused
    }

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
        // Through `openChecking`, so a large folder is warned about here as it
        // is on the Mac. Vault discovery still applies to whatever survives it.
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            let vaults = ObsidianVault.discoverVaults(in: url)
            if vaults.isEmpty {
                await library.openChecking([url])
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
        return notes(in: scope)
    }

    var body: some View {
        // Split in two deliberately, the way `MacContentView`'s is. The sheet
        // stack and the scene wiring are one expression to the type checker,
        // and this chain has already defeated it once — which is why the parity
        // sheets live in a `ViewModifier`. Two opaque halves are two smaller
        // problems.
        presentations(shellCore)
            // Every failed file operation used to be invisible here. Nineteen
            // `report(…)` sites write `Collection.lastError` and exactly one
            // view presented it — a `private struct` inside `MacContentView` —
            // so on iPad renaming a note onto an existing name silently did
            // nothing at all.
            .modifier(FileOperationErrorAlert(collection: erroringCollection))
            .modifier(FolderDeleteConfirmation(folder: $pendingFolderDelete) { folder in
                if let c = collection(owningFolder: folder) {
                    Task { await c.deleteFolder(at: folder) }
                }
            })
    }

    /// The shell itself plus everything that wires it to the scene.
    private var shellCore: some View {
        AdaptiveShell(
            // **The same layout at the same size.** This was
            // `.constant(false)`, with a comment saying the iPad is never wide
            // enough for a third column — which is a claim about width, and
            // width is the one thing the shell already decides. `ShellKind`
            // resolves `.wideInspector` at 1400pt and an iPad reaches that in
            // Stage Manager and on a 13" in landscape, so the rule was not "too
            // narrow", it was "not on this OS". That is the definition of
            // non-parity: a Mac window and an iPad of the same size were
            // getting different layouts.
            //
            // Narrower shells still overlay it, on **both** platforms, because
            // `AdaptiveShell` only draws the column for `.wideInspector`.
            inspectorPresented: $inspectorPresented,
            columnVisibility: $columnVisibility,
            // Asked of the hardware, not of the OS — see `PointerPresence`. It
            // decides whether the format bar exists at all, so hard-coding it
            // per platform was the layout differing by device.
            prefersTouch: PointerPresence.shared.prefersTouch,
            sidebar: { collectionTree },
            pane: { detail(showsShellCommands: true) },
            inspector: { inspector },
            compact: { compactShell }
        )
        .task {
            // Not under a test host — see TestEnvironment.
            guard !TestEnvironment.isRunningTests else { return }
            // **External changes reach the editor.** `Library.onExternalChange`
            // defaults to a no-op and only macOS ever set it, so on iOS a note
            // edited elsewhere — Obsidian on another device, a sync landing —
            // updated the note list while the open editor kept showing the old
            // text, and a selection pointing at a note that had gone was never
            // re-checked.
            library.onExternalChange = { @MainActor in
                // **Every** open tab, not just the front one. This reconciled
                // `tabs.editor(withID: selectedNoteID)` alone, so a background
                // tab never saw a remote change, never raised `hasConflict`,
                // and its next save wrote stale text over the newer file.
                // `EditorTabs.reconcileAll()` was cross-platform all along.
                Task { await tabs.reconcileAll() }
                revalidateSelection()
            }
            // Nothing recorded opens on iOS, so the launcher's Recents and
            // Obsidian Vaults lists would have stayed permanently empty even
            // once it had somewhere to draw them. `Library.restore` calls this
            // for every restored collection too, so a relaunch re-seeds the
            // list rather than emptying it.
            // Every open tab's buffer drains before the app leaves the
            // foreground. The Mac has registered its tabs since the guard was
            // written; on iPad the guard did not exist, so up to half a second
            // of typing could be lost to a background-and-kill.
            TerminationGuard.current?.register(tabs) { [tabs] in await tabs.flushAll() }
            library.onOpened = { recents.record($0) }
            if library.isEmpty {
                await library.restore()
                if library.isEmpty && !hasSeenWelcome { pendingWelcome = true }
            }
            // Reopen the last-focused collection and the note that was open,
            // as the Mac does. `railPlace` alone was restored here, so an iPad
            // came back to the right *tree* with an empty editor, and
            // `library.focused` was left at whichever collection happened to
            // finish restoring last.
            if !restoredCollectionID.isEmpty,
               library.collections.contains(where: { $0.id == restoredCollectionID }) {
                library.focusedID = restoredCollectionID
            }
            if !restoredNotePath.isEmpty {
                let url = URL(fileURLWithPath: restoredNotePath)
                if library.allNotes.contains(where: { $0.id == url }) { selectedNoteID = url }
            }
            // A window whose rail has never been moved opens in the focused
            // collection, not on the Library place: the notes are the point.
            if railPlaceID == Self.railPlaceUnset { railPlaceID = library.focusedID ?? "" }
        }
        .task { wireTabs() }
        .task(id: docFeaturesKey) {
            // Off the main actor, memoized, and keyed on something that changes
            // at most once per autosave.
            //
            // `MarkdownParsing.mermaidBlocks` is a whole-document regex with no
            // early exit, and it used to run on the main actor every time the
            // note menu was *built* — `Menu(content:label:)` takes a
            // *non-escaping* ViewBuilder, so both scans ran on every body
            // evaluation whether or not the menu was ever opened.
            //
            // The Mac keys the same work on the text itself, debounced, because
            // its `DocStats` also carries a live word count. Nothing on iPad
            // shows one, and keying on the text here would read `editor.text`
            // during the *shell's* body — making every keystroke invalidate the
            // whole shell, which is a worse bug than the one being fixed. All
            // these two flags gate is a pair of menu rows, and an autosave
            // lands within a second of typing stopping.
            let text = editor.text
            docFeatures = await offMain { NoteDocFeatures(text: text) }
        }
        .task(id: "\(selectedNoteID?.path ?? "")|\(editorCollection?.derivedRevision ?? 0)") {
            await computeUnlinkedMentions()
        }
        .onChange(of: showSplash) { _, visible in
            // Present onboarding only after the launch splash has faded.
            if !visible && pendingWelcome {
                pendingWelcome = false
                showWelcome = true
            }
        }
        .onChange(of: library.focusedID) { _, newID in
            restoredCollectionID = newID ?? ""
            // Switching collections resets the in-collection tag filter.
            //
            // The *search* deliberately survives, as it does on the Mac: focus
            // now follows the selection, so opening a search hit that lives in
            // another collection would otherwise empty the field the hit came
            // from and drop the rest of the results with it.
            selectedTag = nil
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
        .focusedSceneValue(\.appActions, appActions)
        .onChange(of: library.allNotes) { _, notes in
            // A cached document captured which wiki-link targets existed when
            // it was built — neither the store key nor the task key names the
            // note set — so once that set changes it would go on colouring
            // `[[links]]` by a stale answer: a brand-new note stayed painted as
            // broken in every open document until the 8-entry LRU evicted it.
            documents.forgetAll()
            // Closes tabs for notes that are gone — flushing first, which is
            // the part that stops a rename or an external change taking pending
            // keystrokes with it.
            tabs.prune(keeping: Set(notes.map(\.id)))
            // The Recent Notes widget is built and embedded for iOS, and its
            // snapshot file was never written here — so it was permanently
            // empty on the one platform that puts widgets on the home screen.
            library.writeWidgetSnapshot()
            Task { await router.donateNotesToSpotlight() }   // system Spotlight
        }
        .onChange(of: selectedNoteID) { _, newID in
            restoredNotePath = newID?.path ?? ""
            // A selection that resolves to nothing must not blank the editor.
            // The same bare lookup on macOS was the "populated sidebar, clicks
            // do nothing" bug; here the failure is worse, because opening `nil`
            // actively closes the open note. Deselecting is the one case where
            // clearing is what was asked for.
            guard newID != nil else { return }
            guard let note = library.allNotes.first(where: { $0.id == newID }) else { return }
            // **Focus follows the selection**, as it does on both branches of
            // the Mac's `openSelectedNote`. `focusCollection` had no iOS caller
            // at all, and the only other writer of focus lived in the compact
            // shell — which no iPad ever shows — so with two collections open,
            // tapping a note under the second left the scope on the first. That
            // scope drives New Note, the graph, tags, Open Quickly, the note
            // list and Show Non-Note Files, so every one of them answered about
            // a collection the user was not in.
            library.focusCollection(containing: note.fileURL)
            Task { await tabs.editor(for: note) }
        }
        .onChange(of: searchText) { _, query in scheduleContentSearch(query) }
        .onChange(of: SidebarTreeModel.key(sidebarInputs), initial: true) { _, _ in
            sidebarTree.refresh(sidebarInputs)
        }
        .onChange(of: library.pendingRevealCollectionID) { _, id in
            // Something added a collection and asked us to show it —
            // `Library.openRemote` does this for a newly-connected cloud
            // collection. Unlike a passing focus change this moves the rail
            // unconditionally: the user asked for this collection by name, so
            // leaving them looking at a different tree makes a successful add
            // look like a failed one.
            guard let id else { return }
            selectedTag = nil
            library.focusedID = id
            railPlaceID = id
            library.pendingRevealCollectionID = nil
        }
        .onChange(of: library.pendingOpenNoteID) { _, id in
            // A `hellonotes://` deep link, an App Intent (Open Note, Create
            // Note, Append to Daily Note), the widget, or Quick Capture asking
            // to show a note. iOS observed none of them: the links resolved and
            // opened nothing, every Siri shortcut landed nowhere, and Quick
            // Capture appended its line and then reported success over a shell
            // that had not moved.
            guard let id else { return }
            showOpenQuickly = false
            selectedTag = nil
            searchText = ""
            selectedNoteID = id
            // The phone keeps the open note in a mini strip behind a tab bar;
            // being *asked* to open one is a request to read it.
            place = .notes
            noteIsExpanded = true
            library.pendingOpenNoteID = nil
        }
        .onChange(of: router.pendingSearch) { _, query in
            // `hellonotes://search?q=…` and the Search Notes intent.
            guard let query else { return }
            showOpenQuickly = false
            selectedTag = nil
            searchText = query
            revealSearch(focusField: false)
            router.pendingSearch = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .hnFocusLibrarySearch)) { _ in
            revealSearch(focusField: true)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                Task { await tabs.flushAll() }
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

    /// The first collection with something to say about a failed operation.
    ///
    /// The Mac binds its alert to `focused`, which is right there because every
    /// note action it offers acts on the focused collection. Here they do not:
    /// the sidebar holds one tree over *every* open collection and its note
    /// actions resolve the owner with `library.collection(containing:)`, so an
    /// alert watching only the focused one would still be silent for exactly
    /// the operations that most often fail.
    private var erroringCollection: Collection? {
        library.collections.first { $0.lastError != nil }
    }

    /// The collection a folder path belongs to. Folder ids are absolute paths
    /// and a collection's id is its standardised root path, so containment is a
    /// prefix test — the same one the Mac's folder actions use.
    private func collection(owningFolder url: URL) -> Collection? {
        library.collections.first { url.path == $0.id || url.path.hasPrefix($0.id + "/") }
    }

    /// What `docFeatures` is computed against: which note is open, and the
    /// tabs' combined save revision. Cheap to read every render, and it changes
    /// at most once per autosave rather than once per keystroke.
    private var docFeaturesKey: String {
        "\(selectedNoteID?.path ?? "")|\(tabs.totalSavedRevision)"
    }

    /// Bring the search field and its results on screen.
    ///
    /// Both live in the sidebar on iPad, so a request to search a hidden
    /// sidebar is a dead end — the same reasoning as the Mac's
    /// `hnFocusLibrarySearch` handler, which opens the panel before taking
    /// focus. On the phone the sidebar is a tab rather than a column, and the
    /// note is covering it.
    private func revealSearch(focusField: Bool) {
        if columnVisibility == .detailOnly {
            withAnimation(.easeInOut(duration: 0.18)) { columnVisibility = .all }
        }
        place = .search
        noteIsExpanded = false
        if focusField { searchFocused = true }
    }

    /// Every sheet and alert the shell owns — the second half of the split
    /// described in `body`.
    private func presentations<V: View>(_ content: V) -> some View {
        content
        // The large-folder warning, which iPad never had — see
        // `LargeFolderAlert`.
        .largeFolderAlert(library)
        // `Library` asks for a picker rather than presenting one; the shell owns
        // the picker, so the shell answers.
        .onChange(of: library.pendingFolderPick) { _, request in
            guard request != nil else { return }
            library.pendingFolderPick = nil
            showImporter = true
        }
        .onChange(of: library.pendingSubfolderPick) { _, url in
            guard url != nil else { return }
            library.pendingSubfolderPick = nil
            showImporter = true
        }
        .sheet(item: $cloudBrowser) { browser in
            NavigationStack {
                RemoteBrowserView(store: browser.makeStore(),
                                  onAddAsCollection: addRemoteCollection)
                    .navigationTitle(browser.displayName)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { cloudBrowser = nil }
                        }
                    }
            }
        }
        .sheet(isPresented: $showLauncher) {
            // The same six affordances the Mac's launcher offers, wired to the
            // iOS routes for each: the folder picker stands in for NSOpenPanel,
            // and it already starts in Obsidian's iCloud folder and expands a
            // picked folder into the vaults inside it (`handleImport`).
            LauncherView(
                recents: recents,
                libraries: libraries,
                openCollectionURLs: library.collections.map(\.rootURL),
                onOpenURL: { url in Task { await library.open(url: url) } },
                onOpenLibrary: { saved in
                    let urls = libraries.urls(for: saved)
                    Task { await library.openLibrary(urls) }
                },
                onSaveLibrary: { name in
                    libraries.save(name: name, urls: library.collections.map(\.rootURL))
                },
                onOpenCollection: { showImporter = true },
                onOpenObsidian: { showImporter = true },
                onClone: { showClone = true },
                onNewRepository: { showNewRepo = true }
            )
        }
        .sheet(isPresented: $showImporter) {
            // `UIDocumentPickerViewController`, not SwiftUI's `.fileImporter`.
            //
            // `.fileImporter` has no way to choose where the browser opens, and
            // the note in `ObsidianVault` claiming the Files picker "can't be
            // seeded with a start directory" was simply wrong: the UIKit picker
            // has had `directoryURL` since iOS 13. So the picker now opens in
            // Obsidian's iCloud folder instead of wherever Files was last.
            FolderPicker(startingAt: ObsidianVault.pickerStartDirectory) { urls in
                showImporter = false
                guard !urls.isEmpty else { return }
                Task { await openPicked(urls) }
            }
            .ignoresSafeArea()
        }
        .alert("Rename Note", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })
        ) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") {
                actions.commitRename()
            }
        } message: {
            Text("Renaming updates [[links]] in notes that point at it.")
        }
        .sheet(isPresented: $showQuickCapture) {
            NavigationStack {
                QuickCaptureView(router: router)
                    .navigationTitle("Quick Capture")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showQuickCapture = false }
                        }
                    }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showClone) {
            NavigationStack {
                CloneRepositoryView(store: gitAccounts, git: focused?.git ?? GitService()) { url in
                    Task { await library.open(url: url) }
                }
            }
        }
        .sheet(isPresented: $showNewRepo) {
            NavigationStack {
                NewRepositoryView(store: gitAccounts) { url in
                    Task { await library.open(url: url) }
                }
            }
        }
        .sheet(isPresented: $showOpenQuickly) {
            NavigationStack {
                if let search = (railCollection ?? focused)?.search {
                    OpenQuicklyView(search: search) { note in
                        showOpenQuickly = false
                        selectedTag = nil
                        searchText = ""
                        selectedNoteID = note.id
                    }
                    .navigationTitle("Open Quickly")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showOpenQuickly = false }
                        }
                    }
                }
            }
        }
        .alert("New Folder", isPresented: Binding(
            get: { newFolderCollection != nil },
            set: { if !$0 { newFolderCollection = nil } })
        ) {
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
        .modifier(ParitySheets(
            showGraph: $showGraph,
            showMindMap: $showMindMap,
            showPalette: $showPalette,
            graph: { graphSheet },
            mindMap: { mindMapSheet },
            palette: { CommandPaletteView(commands: appActions.paletteCommands) }))
        .sheet(isPresented: $showSettings) {
            iOSSettingsView(settings: appearance, git: focused?.git, accounts: gitAccounts)
        }
        // Ask Library, which iOS simply did not have. The Mac gives it a window;
        // a sheet is the same thing on a platform with one window.
        .sheet(isPresented: $showLibraryChat) { libraryChatSheet }
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
        .background {
            // ⌘W → close the active editor tab, but only while several are
            // open. The Mac guards this against falling through to File ▸ Close
            // and dismissing the window; an iPad scene has no competing Close
            // Window, so here it is simply the keyboard route to the same
            // command the tab strip and the File menu offer.
            if tabs.openNotes.count > 1, let id = selectedNoteID, tabs.editor(withID: id) != nil {
                Button("") { closeTab(id) }
                    .keyboardShortcut("w", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
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
    /// A note row in the sidebar: title, the cloud badge when it is online
    /// only, and a second line carrying the search snippet or the modification
    /// date — the same three things the Mac's `noteCell` shows, decided by the
    /// same `NoteRowContent` so the two cannot drift again.
    @ViewBuilder
    private func noteRow(_ note: Note, snippet: String? = nil) -> some View {
        let content = NoteRowContent.make(note, snippet: snippet)
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(content.title).font(.subheadline.weight(.semibold))
                if content.isOnlineOnly {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel(NoteRowContent.onlineOnlyLabel)
                }
            }
            Text(content.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .tag(note.id)
        // The tree is the only place a note has a *location*, so it is the only
        // place a move makes sense — the same rows the Mac makes draggable.
        .draggable(note.fileURL)
    }

    private var collectionTree: some View {
        // `NoteOutlineList` — the same call the Mac makes. One API over two
        // widgets: an `NSOutlineView` there, a SwiftUI `List` of
        // `SidebarItemRow` here. What is *in* the tree is `SidebarTree.roots`
        // and what a row *says* is `NoteRowContent`, both shared, so the widget
        // is the only thing left that differs.
        NoteOutlineList(
            roots: sidebarTree.roots,
            signature: sidebarTree.signature,
            selection: $selectedNoteID,
            revealID: .constant(nil),
            expandedFolders: expandedFolders,
            collapsedCollections: $collapsedCollections,
            focusedCollectionID: library.focusedID,
            accent: appearance.resolvedAccent,
            fontScale: appearance.textScale,
            scopedCollectionID: selectedTag == nil ? nil : (railCollection ?? focused)?.id,
            actions: actions.sidebarMenu,
            scopedCollection: railCollection ?? focused,
            onCloseCollection: { actions.closeCollection($0) },
            row: { note, snippet in AnyView(noteRow(note, snippet: snippet)) },
            onDropIntoFolder: { id, urls in actions.move(urls, intoFolderWithID: id) })
        .navigationTitle("Collections")
        // **The iPad had no search field at any width.** The only `.searchable`
        // in this file sits on `noteList`, which is compact-only — and
        // `AdaptiveShell` picks compact below 600pt, so no iPad has ever
        // reached it. Meanwhile ⌥⌘F cleared the selection (closing the note you
        // were reading) and Find Related could set `searchText` with no field
        // on screen to edit or clear.
        //
        // Against the panel it searches, per D9 — but a native `.searchable`
        // rather than the Mac's hand-built field: D9's two objections
        // (collapsing to a glyph at 860pt, and claiming the trailing end of the
        // band) are both AppKit behaviours. `navigationBarDrawer(.always)` is
        // how the same "must not vanish at the width it is most needed" rule is
        // spelled on iOS. The hits replace the tree in place, so field and
        // results stay together and Cancel is always there to escape them.
        .searchable(text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search all collections")
        .searchFocused($searchFocused)
        .overlay {
            // **Closing the last collection must not be a dead end.** The way
            // back in lived only in the Library place's menu, which the iPad
            // sidebar is not, so closing everything left a blank column and a
            // lone "+" whose meaning you had to already know.
            if library.isEmpty {
                ContentUnavailableView {
                    Label("No Collections", systemImage: "books.vertical")
                } description: {
                    Text("Open a folder of Markdown notes, or an Obsidian vault, to get started.")
                } actions: {
                    Button("Open Collection…") { showImporter = true }
                        .buttonStyle(.borderedProminent)
                    // The Mac's equivalent empty state offers the launcher, not
                    // the panel: after the first time, the way back in is a
                    // vault you have already opened, not a folder to re-find.
                    Button("Open Recent…") { showLauncher = true }
                        .disabled(recents.entries.isEmpty && libraries.libraries.isEmpty)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Open Collection…", systemImage: "folder.badge.plus")
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label("Open Obsidian Vault…", systemImage: "shippingbox")
                    }
                    Divider()
                    // Both views were always cross-platform — they already
                    // branch to a document picker where the Mac opens a panel.
                    // Only a way in was missing.
                    Button {
                        showClone = true
                    } label: {
                        Label("Clone Repository…", systemImage: "arrow.down.circle")
                    }
                    Button {
                        showNewRepo = true
                    } label: {
                        Label("New Repository…", systemImage: "plus.rectangle.on.folder")
                    }
                    if !library.isEmpty {
                        Divider()
                        Button {
                            openTodaysNote()
                        } label: {
                            Label("Today's Note", systemImage: "calendar")
                        }
                        Button {
                            showQuickCapture = true
                        } label: {
                            Label("Quick Capture…", systemImage: "square.and.pencil.circle")
                        }
                        Button {
                            showOpenQuickly = true
                        } label: {
                            Label("Open Quickly…", systemImage: "magnifyingglass")
                        }
                        Button {
                            // Focus the field, the way ⌥⌘F does on the Mac.
                            // This used to `select(.library)` — which runs
                            // `selectedNoteID = nil` — so "Search All
                            // Collections" closed the note you were reading and
                            // then offered no field to type into.
                            revealSearch(focusField: true)
                        } label: {
                            Label("Search All Collections", systemImage: "text.magnifyingglass")
                        }
                    }
                } label: {
                    Label("Open Collection", systemImage: "plus")
                }
            }
        }
    }
    /// Mirrors a browsed cloud folder into a sidebar collection. Captures the
    /// library itself rather than `self`, which is a view struct.
    private var addRemoteCollection: AddRemoteCollection {
        let library = self.library
        return { store, remoteRoot, displayName, progress in
            try await library.openRemote(store: store, remoteRoot: remoteRoot,
                                         displayName: displayName, progress: progress)
        }
    }

    /// Open (creating if needed) today's daily note.
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

    /// The collection and folder URL a folder item's id names.
    ///
    /// The id is the owning collection's id followed by the folder's path
    /// relative to it — namespaced exactly so equal relative paths in two
    /// collections stay distinct. Same lookup the Mac's outline makes.
    private func folder(forID id: String) -> (Collection, URL)? {
        guard let collection = library.collections.first(where: {
            id == $0.id || id.hasPrefix($0.id)
        }) else { return nil }
        return (collection, URL(fileURLWithPath: id, isDirectory: true))
    }
    /// Re-check the selection after the note set changed underneath it.
    ///
    /// Deliberately conservative: a selection that still resolves is left
    /// exactly as it is, and one that no longer resolves is *kept* rather than
    /// cleared, because clearing it would close the note the user is reading on
    /// the strength of a scan. Only the editor's content is refreshed.
    private func revalidateSelection() {
        guard let selectedNoteID else { return }
        guard library.allNotes.contains(where: { $0.id == selectedNoteID }) else { return }
        Task { await editor.reconcileWithDisk() }
    }

    private var bookmarkedNotes: [Note] {
        library.collections.flatMap { $0.bookmarks.bookmarkedNotes(from: $0.notes) }
    }

    /// One collection's notes, narrowed by whatever filter is active. Used for
    /// the *filtered* sidebar and the compact note list; the unfiltered sidebar
    /// shows the folder tree instead.
    private func notes(in collection: Collection) -> [Note] {
        if let selectedTag { return collection.search.notesTagged(selectedTag) }
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return collection.notes }
        // Both waves, in result order, from the shared engine — this used to
        // merge them here with a rule of its own.
        return search.notes(in: collection.id)
    }

    /// The search's second wave: notes whose *body* matches.
    ///
    /// Same two-stage shape as the Mac's `scheduleSearch`, and for the same
    /// reason — Spotlight names the files whose content matches, and only those
    /// few are then read, so a query costs a handful of reads rather than a pass
    /// over the whole vault. On a volume with no Spotlight index it degrades to
    /// the title/alias hits, which is how the Mac degrades. Snippets are the one
    /// thing not carried across: the sidebar's rows are single-line titles, and
    /// a snippet needs a row that can hold one.
    private func scheduleContentSearch(_ raw: String) {
        // The debounce, the two waves and the merge are `LibrarySearch`'s.
        search.update(query: raw, in: library.collections)
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
                    // Both views were always cross-platform — they already
                    // branch to a document picker where the Mac opens a panel.
                    // Only a way in was missing.
                    Button {
                        showClone = true
                    } label: {
                        Label("Clone Repository…", systemImage: "arrow.down.circle")
                    }
                    Button {
                        showNewRepo = true
                    } label: {
                        Label("New Repository…", systemImage: "plus.rectangle.on.folder")
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
                    onOpenLibrary: { showLauncher = true },
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
                // The compact shell's own field. Only one of the two
                // `.searchFocused` bindings is ever in the hierarchy —
                // `AdaptiveShell` renders compact or the column/tall shell,
                // never both — so ⌥⌘F reaches whichever field exists.
                .searchFocused($searchFocused)
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
            // The launcher, by touch. `openLauncher` reaches it from a hardware
            // keyboard's ⇧⌘O, which is not a route a keyboard-less iPad has —
            // and recents and saved libraries are the only way back to a vault
            // without navigating the Files picker to it again.
            .init(title: "Open Recent…", symbol: "clock.arrow.circlepath") { showLauncher = true },
            // The Mac reaches this from the menu bar without switching apps.
            // iOS has no such chrome, so the capture lives where the rest of
            // the library-wide commands do.
            .init(title: "Quick Capture…", symbol: "square.and.pencil.circle",
                  isEnabled: !library.isEmpty) { showQuickCapture = true },
            // Reachable deliberately, not only by selecting a phrase — the
            // question you want to ask your notes usually isn't already in one.
            .init(title: "Ask Your Library", symbol: "sparkles.rectangle.stack",
                  isEnabled: !library.allNotes.isEmpty) {
                showLibraryChat = true
            },
            .init(title: "Assistant", symbol: "sparkles", isEnabled: scope != nil) {
                showAssistant = true
            },
            .init(title: "AI Settings…", symbol: "brain") { showLLMSettings = true },
            .init(title: "Settings…", symbol: "gearshape") { showSettings = true },
        ]
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
        // The *selection's* collection, not the focused one. Every panel here
        // answers a question about the open note — its tags, its link
        // candidates, its git history, the corpus its backlinks are searched in
        // — and asking a different collection returns confidently wrong answers
        // (and, for backlinks, an empty list).
        if let collection = editorCollection {
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
                unlinkedMentions: unlinkedMentions,
                onOpenNote: { selectedNoteID = $0.id },
                // `NoteInspector` draws an enabled "Link" button per unlinked
                // mention, promising to "turn this mention into a [[link]] in
                // that note" — and this was `{ _ in }`, so on iPad it promised
                // and did nothing.
                onLinkMention: linkMention,
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
                properties: propertiesBinding,
                // Writing goes through the binding's setter, which is also the
                // path the note buffer autosaves by.
                onPropertiesChanged: {},
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
    /// `iOSLiveEditor` listens on the same bus the Mac's editor does and drives
    /// the scroll through `EditorProxy`, so this is the identical call on both.
    private func scrollToHeading(_ title: String) {
        NotificationCenter.default.post(name: .hnEditorFindQuery, object: nil,
                                        userInfo: ["query": title])
    }

    /// Front matter, read from and written straight through the note buffer.
    ///
    /// Derived rather than copied into `@State`, for the reason the Mac's
    /// `propertiesBinding` records: a copy is seeded when the selection changes,
    /// which happens before the editor has loaded that note's text, so the
    /// inspector shows the properties of nothing at all. **A binding over the
    /// buffer cannot be stale**, and writing through it autosaves by the same
    /// path typing does.
    ///
    /// Here the `@State` copy was never seeded by anything — no `onAppear`, no
    /// `task`, no selection handler — so the tab always showed zero rows and
    /// adding a single property called `FrontMatter.applying([thatOneKey], …)`,
    /// which replaces the block wholesale: title, tags and aliases destroyed,
    /// and then autosaved. Removing the last row rendered `""` and stripped the
    /// front matter entirely.
    private var propertiesBinding: Binding<[Property]> {
        Binding(
            get: { FrontMatter.properties(in: editor.text) },
            set: { updated in editor.text = FrontMatter.applying(updated, to: editor.text) }
        )
    }

    /// Turn the first plain-text mention of the open note (by title) in `note`
    /// into a `[[link]]`, writing the change to disk and re-indexing.
    ///
    /// The read *and* the write go off the main actor: both are coordinated, and
    /// a coordinated call against a File Provider blocks for as long as the
    /// provider takes. This runs from a button in the inspector, so the shell
    /// would freeze with it.
    private func linkMention(_ note: Note) {
        guard let target = editor.note, let c = editorCollection else { return }
        Task { await MentionLinker.linkFirstMention(of: target.title, in: note, collection: c) }
    }

    // MARK: - Compact: the editor is the screen

    /// Phone-sized: places in a bottom tab bar, the open note above it as a
    /// mini strip, one tap from full screen (decisions 6 and 11).
    /// The AI place — `AIPlaceList`, shared with the Mac's compact shell.
    ///
    /// This was a `private var` here, which is precisely why the Mac's compact
    /// shell had nothing to fill this tab with and so had no compact shell at
    /// all. Everything it draws comes from `AIActions` and a few optional
    /// closures, which both shells already build for the menu bar.
    private var aiPlace: some View {
        let scope = railCollection ?? focused
        return AIPlaceList(
            ai: aiActions,
            canAsk: !library.allNotes.isEmpty,
            askLibrary: { showLibraryChat = true },
            reviewLinks: editor.note != nil ? { beginLinkReview() } : nil,
            compose: scope == nil ? nil : { showCompose = true },
            assistant: { showAssistant = true },
            // iOS has no Preferences window, so AI settings needs a row here.
            aiSettings: { showLLMSettings = true },
            hasOpenNote: editor.note != nil)
    }

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
                    // Decision 7's AI place. A destination rather than a sheet,
                    // because on a phone the sheets are reached from the
                    // Library actions inside the Notes tab — two taps deep in
                    // the one place a phone user is least likely to look.
                    case .ai:     aiPlace
                    }
                }
            },
            editor: { detail(showsShellCommands: false) }
        )
    }

    // MARK: - Column 3: Editor

    /// The pane, with one toolbar over all three of its states — a non-note
    /// file, the open note, or nothing selected.
    ///
    /// The toolbar used to hang off the note branch alone, so every command in
    /// it disappeared at the one moment there was no note: the state in which
    /// "New Note" is most wanted.
    ///
    /// `showsShellCommands` is off on the phone. There the note is presented
    /// full screen by `CompactShell`, whose band already carries a collapse
    /// button and has 375pt to spend — and the same commands are a tab away in
    /// the Library place, which is the compact shell's whole point. The iPad has
    /// neither, which is why the leading item exists at all.
    private func detail(showsShellCommands: Bool) -> some View {
        detailBody
            .toolbar { detailToolbar(showsShellCommands: showsShellCommands) }
    }

    @ViewBuilder
    private var detailBody: some View {
        if let file = selectedFile {
            // The same viewer the Mac uses, and handed the same hydration
            // callbacks — so a direct-API collection fetches through its
            // provider here too rather than falling back to the iCloud watch.
            FileViewerView(
                file: file,
                isPlaceholder: { url in
                    library.collection(containing: url).map { !$0.hasContent(url) } ?? false
                },
                prepare: { url in
                    await library.collection(containing: url)?.hydrateIfNeeded(url)
                }
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(file.name)
                .navigationBarTitleDisplayMode(.inline)
                .ignoresSafeArea(.container, edges: .bottom)
        } else if let note = editor.note, let c = editorCollection {
            // `NoteEditorView`, the same editor column the Mac uses — not the
            // bare pane. The pane is banners, title and the four modes; the
            // *view* adds the find bar, the mode sheets and the bottom bar, and
            // iPad had none of that bar: no word count, no save status, no Git
            // change count. `DocStats` even carried a comment about "the word
            // count that nothing on iOS shows" — which was the gap, not the
            // reason for it.
            NoteEditorView(
                editor: editor,
                backlinks: c.linkGraph.backlinks(for: note, in: c.notes),
                outgoingLinks: c.linkGraph.outgoingLinks(for: note, in: c.notes),
                unlinkedMentions: unlinkedMentions,
                embedProvider: c.embedProvider,
                git: c.git,
                linkCandidates: c.search.linkTargets(),
                tagCandidates: c.search.allTags(),
                headingProvider: { c.search.headings(forName: $0) },
                onOpenWikiLink: { openWikiLink($0) },
                onOpenNote: { selectedNoteID = $0.id },
                onLinkMention: linkMention,
                onRenameNote: { actions.rename(note, to: $0) },
                onShowMindMap: { showMindMap = true },
                ai: aiActions,
                selectionActions: selectionActions(in: c)
            )
            // S3: the detail column is a viewport, whatever mode it is in.
            // Without the clamp the editor's or preview's ideal height sizes
            // the column, and the split view follows it past the screen.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The overlay is the *narrow* presentation. Where the shell has
            // room for the column, the column is what shows — otherwise both
            // would, which is how the same setting ends up meaning two things.
            .overlay(alignment: .trailing) {
                WhenNoInspectorColumn { inspectorOverlay }
            }
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $linkReview) { review in
                NavigationStack {
                    ReviewLinksView(
                        proposals: review.proposals,
                        noteText: review.noteText,
                        preview: { await editorCollection?.openingLines(of: $0) ?? "" },
                        onFinish: { applyAcceptedLinks($0, reviewedText: review.noteText) },
                        onDecline: { editorCollection?.declineLink($0) }
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

    @ToolbarContentBuilder
    private func detailToolbar(showsShellCommands: Bool) -> some ToolbarContent {
        // Leading — the commands that have to survive a collapsed sidebar.
        if showsShellCommands {
            ToolbarItem(placement: .topBarLeading) { shellCommandMenu }
        }
        if editor.note != nil {
            // The top line is tabs; one caret holds everything else.
            ToolbarItem(placement: .principal) { tabStrip }
            ToolbarItem(placement: .topBarTrailing) { noteMenu }
            // Trailing — the inspector, over the inspector, exactly as on the
            // Mac. iPad had no route to it at all: `inspectorPresented` was set
            // only by the AI commands, so Outline, Tags, References, Properties
            // and History existed and could not be opened by hand.
            ToolbarItem(placement: .topBarTrailing) { inspectorToggle }
        }
    }

    /// The library-wide commands, in the band over the *editor*.
    ///
    /// `shell-chrome.md` D8 and the P2 corollary: no command may live inside the
    /// collapsible panel, because collapsing it removes the command at the exact
    /// moment it is wanted. Every one of these previously lived only in
    /// `libraryActions` or `collectionsList` — both reachable solely from
    /// `compactShell`, and `AdaptiveShell` picks compact only below 600pt, so no
    /// iPad has ever shown either. **Settings in particular was unreachable at
    /// any iPad size**: the `Settings {}` scene is `#if os(macOS)` and
    /// `AppCommands` declares no `.appSettings` group, so ⌘, does nothing
    /// either — appearance, text size and the Git accounts had no route at all.
    ///
    /// One toolbar item rather than five, because at 744pt this band is also
    /// carrying the tab strip and two trailing controls. Tapping it is New Note
    /// — much the commonest of the set — and holding it is the rest, which is
    /// how iOS spells "a button that is also a menu".
    private var shellCommandMenu: some View {
        let scope = railCollection ?? focused
        return Menu {
            Button {
                newNoteInScope()
            } label: {
                Label("New Note", systemImage: "square.and.pencil")
            }
            .disabled(scope == nil)
            Button {
                actions.beginNewFolder(in: scope, folderID: nil)
            } label: {
                Label("New Folder…", systemImage: "folder.badge.plus")
            }
            .disabled(scope == nil)
            Divider()
            Button {
                openTodaysNote()
            } label: {
                Label("Today's Note", systemImage: "calendar")
            }
            .disabled(scope == nil)
            Button {
                showQuickCapture = true
            } label: {
                Label("Quick Capture…", systemImage: "square.and.pencil.circle")
            }
            .disabled(library.isEmpty)
            Button {
                showOpenQuickly = true
            } label: {
                Label("Open Quickly…", systemImage: "arrow.forward.square")
            }
            .disabled(scope?.notes.isEmpty ?? true)
            Divider()
            Button {
                showImporter = true
            } label: {
                Label("Open Collection…", systemImage: "folder.badge.plus")
            }
            Button {
                showLauncher = true
            } label: {
                Label("Open Recent…", systemImage: "clock.arrow.circlepath")
            }
            Menu {
                // The same four the Mac's File ▸ Connect Over the Web offers.
                // They were reachable on iPad only by opening Settings, which
                // is not where "open something" lives on either platform.
                ForEach(CloudBrowser.allCases) { browser in
                    Button(browser.displayName) { cloudBrowser = browser }
                }
            } label: {
                Label("Connect Over the Web", systemImage: "cloud")
            }
            Divider()
            Button {
                showLLMSettings = true
            } label: {
                Label("AI Settings…", systemImage: "brain")
            }
            Button {
                showSettings = true
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
        } label: {
            Label("New Note", systemImage: "square.and.pencil")
        } primaryAction: {
            newNoteInScope()
        }
        .accessibilityLabel("New Note, and app commands")
    }

    /// New Note in the collection the shell is scoped to.
    private func newNoteInScope() {
        guard let scope = railCollection ?? focused else { return }
        Task { if let note = await scope.createNote() { selectedNoteID = note.id } }
    }

    // MARK: - AI on the open note
    //
    // iOS has no menu bar, so the toolbar is the *only* fixed place a command
    // can live. Same four actions as the Mac, landing in the same inspector
    // tabs — the answer belongs with the thing it is about on both platforms,
    // and only the route to it differs.

    /// Review Links is its own toolbar button rather than an item in the AI
    /// menu: it is an exact text scan and works with no provider configured, so
    /// burying it under a sparkles icon would hide a working feature behind a
    /// setting it does not need.
    /// Start a composition run against the collection the rail is showing.
    private func runCompose(_ prompt: String, mode: NoteComposer.Mode, depth: Int) {
        guard let scope = railCollection ?? focused else { return }
        ComposeRun.start(prompt: prompt, mode: mode, depth: depth, in: scope,
                         composer: composer, permissions: composePermissions,
                         settings: llmSettings)
    }

    /// See the Mac's `beginLinkReview()` — proposals are generated once, up
    /// front, because every range is an offset into the text as it is now.
    private func beginLinkReview() {
        let text = editor.text
        Task {
            linkReview = await LinkReviewFlow.begin(text: text,
                                                    noteURL: editor.note?.fileURL,
                                                    in: editorCollection)
        }
    }

    private func applyAcceptedLinks(_ accepted: [LinkProposal], reviewedText: String) {
        switch LinkReviewFlow.apply(accepted, reviewedText: reviewedText,
                                    currentText: editor.text) {
        case .apply(let text):        editor.text = text
        case .stale(let message):     editorCollection?.lastError = message
        case .nothing:                break
        }
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

    /// One button that discloses the inspector, and nothing more.
    ///
    /// The Mac puts the five tabs in the band and lets them *be* the tab strip.
    /// An iPad toolbar already carries Review Links, the AI menu and the mode
    /// picker, and five more icons squeezed the mode picker to the point of
    /// unusability. So: one disclosure control here, and the tab strip moves
    /// inside the panel where there is room for it.
    private var inspectorToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { inspectorPresented.toggle() }
        } label: {
            Label("Inspector", systemImage: inspectorPresented
                  ? "sidebar.trailing" : "sidebar.right")
        }
        .accessibilityLabel(inspectorPresented ? "Hide Inspector" : "Show Inspector")
    }

    /// The inspector, over the note rather than beside it.
    ///
    /// A column needs width the iPad does not reliably have — 1400pt for a
    /// third column, and 834pt in portrait is not close. An overlay is
    /// width-independent, so the panel behaves the same in both orientations,
    /// and it is what Obsidian does here.
    @ViewBuilder
    private var inspectorOverlay: some View {
        if inspectorPresented {
            ZStack(alignment: .trailing) {
                // Tap anywhere on the note to dismiss — the panel is modal over
                // the note, so there is no reason to hunt for the close button.
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) { inspectorPresented = false }
                    }
                VStack(spacing: 0) {
                    inspectorHeader
                    Divider()
                    inspector
                }
                .frame(width: 360)
                .background(.regularMaterial)
                .overlay(alignment: .leading) { Divider() }
                .transition(.move(edge: .trailing))
            }
        }
    }

    /// The panel's own chrome: the tab's name, a way out, and the five tabs as
    /// buttons.
    ///
    /// Buttons rather than a dropdown — a tap should not cost a menu when there
    /// are only five destinations. But the dropdown was right about one thing
    /// worth keeping: it *names* the view. Five bare icons make you learn what
    /// "list.bullet.indent" means, so the name stays, on its own line where
    /// there is room for it.
    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(inspectorTab.title)
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { inspectorPresented = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Close Inspector")
            }
            HStack(spacing: 0) {
                ForEach(InspectorTab.allCases) { tab in
                    Button {
                        inspectorTabRaw = tab.rawValue
                    } label: {
                        Image(systemName: tab.systemImage)
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(tab == inspectorTab ? Color.accentColor : .secondary)
                    .background(
                        tab == inspectorTab ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .accessibilityLabel(tab.title)
                    .accessibilityAddTraits(tab == inspectorTab ? [.isSelected] : [])
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// The same wiring the Mac gives its tabs: a save reindexes its collection
    /// rather than triggering a rescan, opening hydrates a cloud note first,
    /// and a write into a folder that has gone away is refused rather than
    /// lost.
    private func wireTabs() {
        tabs.onNoteSaved = { @MainActor url, text in
            library.collection(containing: url)?.noteDidSave(url, text: text)
        }
        tabs.prepareToOpen = { @MainActor url in
            await library.collection(containing: url)?.hydrateIfNeeded(url)
        }
        tabs.saveBlocked = { @MainActor url in
            guard let collection = library.collection(containing: url),
                  case .unavailable(let reason) = collection.state else { return nil }
            let title = url.deletingPathExtension().lastPathComponent
            return "Can’t save “\(title)” — \(reason.explanation) Your changes are kept here until it’s back."
        }
    }

    /// The open notes, in the band over the editor. `EditorTabBar` is the
    /// Mac's too — this was written inline here and had drifted from it: the
    /// close button had an accessibility label and the Mac's did not, and
    /// neither read the height the layout contract states for a tab bar.
    private var tabStrip: some View {
        EditorTabBar(
            notes: tabs.openNotes,
            activeID: selectedNoteID,
            onSelect: { selectedNoteID = $0 },
            // Through the same path as File ▸ Close Tab and ⌘W, so closing a
            // *background* tab doesn't move the selection off the note you are
            // reading.
            onClose: { closeTab($0) })
    }

    /// Everything the top bar used to spread across four controls.
    ///
    /// One caret, because tabs need the width and because every command here is
    /// also in the menu bar now — this is the touch route to the same set, not
    /// a second vocabulary.
    private var noteMenu: some View {
        Menu {
            Picker("View", selection: modeBinding) {
                ForEach(EditorMode.platformCases) { m in
                    Label(m.label, systemImage: m.symbol).tag(m)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { inspectorPresented.toggle() }
            } label: {
                Label(inspectorPresented ? "Hide Inspector" : "Show Inspector",
                      systemImage: "sidebar.right")
            }
            if editor.note != nil {
                Divider()
                Button { beginLinkReview() } label: {
                    Label("Review Links…", systemImage: "link.badge.plus")
                }
                // **The way in to the mind map.** `showMindMap` was bound into
                // `ParitySheets` with a full sheet behind it and was never once
                // set to `true` anywhere in the codebase — every write was a
                // dismissal — so the whole surface was dead code on iOS. The Mac
                // reaches it from the editor's bottom bar; the bar's iPad
                // equivalent is this menu.
                Button { showMindMap = true } label: {
                    Label("Mind Map", systemImage: "brain")
                }
                // Read from the memoized, off-main scan rather than computed
                // here: `Menu(content:label:)` takes a *non-escaping*
                // ViewBuilder, so anything in this closure runs at construction
                // time on the main actor whether or not the menu is ever opened.
                if docFeatures.isMarp {
                    Button { NotificationCenter.default.post(name: .hnShowSlides, object: nil) } label: {
                        Label("Present as Slides", systemImage: "rectangle.on.rectangle")
                    }
                }
                // Only when there is one to preview — the Mac's bar button is
                // always there, but a menu row that opens an empty sheet reads
                // as a broken command rather than an empty note.
                if docFeatures.hasMermaid {
                    Button { NotificationCenter.default.post(name: .hnShowMermaid, object: nil) } label: {
                        Label("Mermaid Diagrams", systemImage: "chart.xyaxis.line")
                    }
                }
            }
            if let ai = aiActions {
                Divider()
                Section("Using \(ai.providerName)") {
                    Button { ai.summarize() } label: { Label("Summarise Note", systemImage: "text.append") }
                    Button { ai.suggestTags() } label: { Label("Suggest Tags", systemImage: "number") }
                    Button { ai.suggestLinks() } label: { Label("Suggest Links", systemImage: "link") }
                    Button { ai.rewriteNote() } label: { Label("Rewrite or Expand…", systemImage: "wand.and.stars") }
                }
            }
        } label: {
            Image(systemName: "chevron.down.circle")
        }
        .accessibilityLabel("Note Actions")
    }

    /// The non-note file the selection points at, if any.
    ///
    /// Checked before `editor.note` because a selection change reaches this
    /// view before the editor has finished opening — without the ordering, a
    /// tap on a PDF shows the previous note until the load settles.
    private var selectedFile: CollectionFile? {
        guard let id = selectedNoteID else { return nil }
        guard library.allNotes.first(where: { $0.id == id }) == nil else { return nil }
        for collection in library.collections {
            if let file = collection.attachments.first(where: { $0.url == id }) { return file }
        }
        return nil
    }

    /// Ask Your Library — `LibraryChatWindowView`, the same view the Mac's
    /// window hosts, seeded from the same pending question.
    ///
    /// This used to be a second construction of `LibraryChatView` with a local
    /// `chatSeed`, so anything that called `Library.requestAsk` other than the
    /// selection action reached the Mac's chat and not this one.
    private var libraryChatSheet: some View {
        NavigationStack {
            LibraryChatWindowView(onOpenNote: { note in
                showLibraryChat = false
                selectedNoteID = note.id
            })
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showLibraryChat = false }
                }
            }
        }
    }

    /// The link graph — `GraphPane`, the same view the Mac's graph window
    /// hosts. This used to be its own reduced copy: `GraphData.build(for:)`
    /// with every parameter defaulted, so iPad had no scope, no link depth, and
    /// no word when the node cap dropped notes from a large collection.
    private var graphSheet: some View {
        GraphPane(onOpen: { url in
            showGraph = false
            if let note = library.allNotes.first(where: { $0.fileURL == url }) {
                selectedNoteID = note.id
            }
        })
    }

    /// The open note as a mind map — `MindMapPane`, the same view the Mac's
    /// mind-map window hosts.
    ///
    /// This used to be its own copy that omitted `onShowSection`, which
    /// defaults to a no-op — so tapping a heading node did nothing here while
    /// on the Mac it opened the note and scrolled to that section. The bus it
    /// needs is the one the inspector's outline already uses.
    @ViewBuilder
    private var mindMapSheet: some View {
        if let note = editor.note {
            MindMapPane(
                rootURL: note.fileURL,
                // The live buffer, not the file: a sheet sits over the open
                // note, so the map should reflect unsaved edits.
                text: editor.text,
                onOpenNote: { url in
                    showMindMap = false
                    if let n = library.allNotes.first(where: { $0.fileURL == url }) {
                        selectedNoteID = n.id
                    }
                },
                onShowSection: { heading in
                    showMindMap = false
                    guard let heading else { return }
                    scrollToHeading(heading)
                })
        } else {
            ContentUnavailableView("No Note Open",
                                   systemImage: "point.topleft.down.curvedto.point.bottomright.up",
                                   description: Text("Open a note to see its mind map."))
        }
    }

    /// Notes whose text mentions this note's title or aliases without linking
    /// to it. Same shape as the Mac's: Spotlight narrows the corpus, then each
    /// candidate is read and checked with the word-boundary scanner, off the
    /// main actor. Degrades to nothing on a volume with no Spotlight index,
    /// which is the same way the Mac degrades.
    private func computeUnlinkedMentions() async {
        // The open note's own collection — a mention is a fact about the corpus
        // the note lives in, and searching a different one comes back empty.
        guard let note = editor.note, let c = editorCollection else { unlinkedMentions = []; return }
        let names = [note.title] + c.search.aliases(of: note.fileURL)
        let excluded = Set(c.linkGraph.backlinks(for: note, in: c.notes).map(\.fileURL))
            .union([note.fileURL])

        var candidatePaths: Set<String> = []
        for name in names {
            let hits = await referenceSpotlight.search(name, in: [c.rootURL])
            guard !Task.isCancelled else { return }
            candidatePaths.formUnion(hits.map { $0.standardizedFileURL.path })
        }
        let candidates = c.notes.filter {
            candidatePaths.contains($0.fileURL.standardizedFileURL.path) && !excluded.contains($0.fileURL)
        }
        let found = await offMain { () -> [Note] in
            candidates.compactMap { candidate in
                guard let text = try? FileIO.readString(at: candidate.fileURL),
                      MentionScanner.containsMention(of: names, in: text) else { return nil }
                return candidate
            }
        }
        guard !Task.isCancelled else { return }
        unlinkedMentions = found
    }

    /// The AI commands, or nil when there is nothing they could do.
    ///
    /// A greyed item says "not now"; an enabled one that always errors says
    /// "this app is broken", and the second is the lie. Same gate as the Mac.
    private var aiActions: AIActions? {
        guard editor.note != nil else { return nil }
        let intelligence = IntelligenceService(settings: llmSettings)
        guard intelligence.isAvailable else { return nil }
        return AIActions(
            providerName: intelligence.providerName,
            summarize: { askInspector(.summarize) },
            suggestTags: { askInspector(.suggestTags) },
            suggestLinks: { askInspector(.suggestLinks) },
            rewriteNote: { NotificationCenter.default.post(name: .hnRewriteNote, object: nil) })
    }

    /// What this window offers the menu bar.
    ///
    /// The same value the Mac publishes, so both platforms drive one command
    /// set and cannot drift on what a command means. Anything iPad has no
    /// answer for stays `nil` and the menu item disables itself — which is why
    /// the type's optionals exist, and better than an item that is present and
    /// inert.
    private var appActions: AppActions {
        let scope = railCollection ?? focused
        return AppActions(
            canNewNote: scope != nil,
            newNote: { newNoteInScope() },
            todaysNote: { openTodaysNote() },
            openLauncher: { showLauncher = true },
            canOpenQuickly: !(scope?.notes.isEmpty ?? true),
            openQuickly: { showOpenQuickly = true },
            canGraph: !(scope?.notes.isEmpty ?? true),
            graphView: { showGraph = true },
            // Asking the library needs notes to ask *about*, not a collection to
            // stand in — the Mac's rule, and iOS's own `libraryActions` row used
            // it while this one used a third, looser one.
            canAsk: !library.allNotes.isEmpty,
            askLibrary: { showLibraryChat = true },
            assistant: { showAssistant = true },
            // File ▸ Close Tab exists on iPad now that the `#if os(macOS)` gate
            // around it is gone, and this hard-coded `false` would have left it
            // permanently greyed over a `tabStrip` full of real, closable tabs.
            canCloseTab: tabs.openNotes.count > 1 && selectedNoteID != nil,
            closeTab: { if let id = selectedNoteID { closeTab(id) } },
            format: editor.note.map { note in
                { (action: FormatAction) in
                    NotificationCenter.default.post(
                        name: .hnFormat(action.kind, documentId: note.fileURL.path),
                        object: nil, userInfo: action.userInfo)
                }
            },
            note: editor.note.map { note in
                NoteMenuActions(
                    isBookmarked: actions.isBookmarked(note),
                    rename: { actions.beginRename(note) },
                    duplicate: { actions.duplicate(note) },
                    toggleBookmark: {
                        library.collection(containing: note.fileURL)?.bookmarks.toggle(note)
                    },
                    copyWikiLink: { Clipboard.copy(note.wikiLink) },
                    // Same command as the Mac's, through `FileReveal` — this
                    // was nil on iOS because the menu item was gated away.
                    revealInFileManager: FileReveal.canReveal(note.fileURL)
                        ? { FileReveal.reveal(note.fileURL) } : nil,
                    // Was nil, so File ▸ Open in New Window and the palette's
                    // "Open in New Window" both drew, enabled, and did nothing.
                    openInNewWindow: { openWindow(value: NoteRef(note.fileURL)) },
                    exportHTML: { EditorExport.exportHTML(markdown: actions.text(of: note), title: note.title) },
                    exportPDF: { EditorExport.exportPDF(markdown: actions.text(of: note), title: note.title) },
                    printNote: { EditorExport.printNote(markdown: actions.text(of: note), title: note.title) },
                    moveToTrash: { actions.delete(note) })
            },
            rescan: scope.map { c in { c.rescan() } },
            showsNonNoteFiles: scope?.showsNonNoteFiles,
            setShowsNonNoteFiles: scope.map { c in { (on: Bool) in c.showsNonNoteFiles = on } },
            openCloudFolder: { showImporter = true },
            refreshCloudCollection: (scope?.isRemote ?? false)
                ? { Task { await scope?.refreshFromProvider() } } : nil,
            commandPalette: { showPalette = true },
            ai: aiActions,
            reviewLinks: editor.note != nil ? { beginLinkReview() } : nil,
            // Needs a collection to put the note in. Unconditional, ⌃⌘N opened
            // a composer on iPad that then died on `guard let scope` in both
            // `runCompose` and the sheet's `onCreate` — a live command that
            // cannot complete, where the Mac greys the item out and says so.
            composeNote: (railCollection ?? focused) == nil ? nil : { showCompose = true },
            // iPadOS makes a second scene from the same call the Mac uses.
            newWindow: { openWindow(id: "main") },
            find: editor.note.map { note in
                { NotificationCenter.default.post(name: .hnFind(documentId: note.fileURL.path), object: nil) }
            },
            // ⌥⌘F focuses the search field. It used to `select(.library)`,
            // which clears `selectedNoteID` — so the shortcut closed the note
            // you were reading and offered nothing to type into.
            searchAllCollections: {
                NotificationCenter.default.post(name: .hnFocusLibrarySearch, object: nil)
            },
            // The four direct-API browsers exist on iOS and were reachable only
            // from Settings, so File ▸ Connect Over the Web did nothing.
            connectOverWeb: { cloudBrowser = $0 },
            editorMode: mode,
            setEditorMode: { storedMode = $0.rawValue }
        )
    }

    /// Close a tab and move to its neighbour, dropping the parsed document with
    /// it — closing is the user saying they are done with the note.
    private func closeTab(_ id: Note.ID) {
        Task {
            let next = await tabs.close(id)
            documents.forget(path: id.path)
            if selectedNoteID == id { selectedNoteID = next }
        }
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
                // Show the field and the results. This used to set `searchText`
                // and stop, which at iPad width flipped the tree into a filtered
                // state with no field on screen to edit or clear — and on the
                // phone the list is behind the editor, so a search whose results
                // are on another screen has to bring you to that screen.
                revealSearch(focusField: false)
            },
            explain: { phrase in
                library.askAboutSelection(phrase)
                showLibraryChat = true
            }
        )
    }

    /// Follow a `[[wiki link]]`.
    ///
    /// The *decision* — web scheme, `[[#heading]]` meaning this note, the link
    /// graph's aliases and paths, a case-insensitive title match, create-on-miss
    /// — is shared with the Mac in `WikiLinkNavigation`. This used to be six
    /// lines of title comparison against the Mac's forty-five: the same command,
    /// the same gesture, a different feature. What stays here is the platform
    /// half: which API opens a URL, and how this shell moves its selection.
    private func openWikiLink(_ target: String) {
        Task {
            switch await WikiLinkNavigation.resolve(target: target,
                                                    in: editorCollection,
                                                    current: editor.note) {
            case .web(let url):
                // `await`: inside a Task this resolves to the async overload,
                // and the completion-handler one is deprecated.
                await UIApplication.shared.open(url)
            case .note(let destination, let heading):
                let switching = selectedNoteID != destination.id
                selectedNoteID = destination.id
                if let heading {
                    // The tab has to exist before anything can scroll inside it,
                    // and a fresh one needs a beat to lay out.
                    await tabs.editor(for: destination)
                    if switching { try? await Task.sleep(for: .milliseconds(350)) }
                    scrollToHeading(heading)
                }
            case .none:
                break
            }
        }
    }

}

/// Shows its content only where the shell has no inspector *column* to put the
/// inspector in.
///
/// Its own view because `@Environment` on `iOSContentView` resolves at that
/// struct's position in the view graph — above `AdaptiveShell`, which is what
/// sets `\.shell`. A property of the content view therefore cannot see the
/// shell it is being rendered inside; a child view can.
private struct WhenNoInspectorColumn<Content: View>: View {
    @Environment(\.shell) private var shell
    @ViewBuilder var content: () -> Content

    var body: some View {
        if shell.kind != .wideInspector { content() }
    }
}

/// What the open note *is*, as far as the note menu needs to know.
///
/// The Mac's `DocStats`, minus the word count that nothing on iOS shows. It
/// exists as its own type because both scans are whole-document passes and the
/// menu that reads them is built on every body evaluation: computing them there
/// put a regex over the entire note on the main actor, run or not.
/// `nonisolated` so it can cross `offMain`, which requires `Sendable`.
private nonisolated struct NoteDocFeatures: Equatable, Sendable {
    var isMarp = false
    var hasMermaid = false

    init() {}

    init(text: String) {
        isMarp = MarpSlides.isMarp(text)
        hasMermaid = !MarkdownParsing.mermaidBlocks(in: text).isEmpty
    }
}

/// The surfaces that were macOS-only until the parity audit: Graph, Mind Map
/// and the command palette.
///
/// A `ViewModifier` rather than three more `.sheet` calls in `body` — that
/// chain is already long enough to defeat the type-checker, which it did the
/// first time these were added. Bindings and builders are passed explicitly:
/// a modifier holding the host struct would be looking at a copy of its state.
private struct ParitySheets<Graph: View, Mind: View, Palette: View>: ViewModifier {
    @Binding var showGraph: Bool
    @Binding var showMindMap: Bool
    @Binding var showPalette: Bool
    @ViewBuilder let graph: () -> Graph
    @ViewBuilder let mindMap: () -> Mind
    @ViewBuilder let palette: () -> Palette

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showGraph) {
                NavigationStack {
                    graph()
                        .navigationTitle("Graph")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showGraph = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showMindMap) {
                NavigationStack {
                    mindMap()
                        .navigationTitle("Mind Map")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showMindMap = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showPalette) { palette() }
    }
}


#endif
