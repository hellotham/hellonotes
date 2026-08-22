//
//  ContentView.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  The shell — one struct, both platforms.
//
//  This was `MacContentView` and `iOSContentView`: two files, each wrapped in a
//  one-sided `#if`, so nothing in either could be seen from the other. Every
//  divergence this session turned up lived in that gap — a cache key naming a
//  different set of inputs, one name over two opposite implementations of
//  `revalidateSelection`, a Git pane one platform had and the other did not, a
//  search that warned you on one and stayed silent on the other. Review cannot
//  catch those, because reading one file never shows you the other.
//
//  So the two are one. `AdaptiveShell` already chose the *layout* by the axis
//  of abundance rather than by device; this makes the shell that fills it one
//  implementation too. What is still gated is gated **with both branches
//  present**: a gate that supplies both shares the behaviour, and only a gate
//  that supplies one loses it.
//

import SwiftUI
import MarkdownEditor
import UniformTypeIdentifiers
import CoreTransferable
import TipKit
#if canImport(AppKit)
import AppKit
#else
// Explicit, for `URL: Transferable` — the payload the sidebar's drag-to-move
// carries. It arrives transitively through SwiftUI, and a conformance that
// happens to be visible is not the same as one that is imported.
import UIKit
#endif

/// The app's shell: a sidebar holding one tree, the editor, and an inspector
/// where there is room — arranged by `AdaptiveShell`, which chooses by the size
/// it is given and never by the platform.
struct ContentView: View {
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

    /// The folder picker for "Open Collection". A presented sheet on both
    /// platforms — the Mac ran an `NSOpenPanel` inline, which is why its open
    /// path and the iPad's were two functions that had drifted apart.
    /// Quick Capture. The menu-bar extra is not the only way in any more — it
    /// was, which meant hiding the menu-bar icon hid the feature.
    @State private var showQuickCapture = false

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

    /// The editor presentation mode. Published through `AppActions` so the View
    /// menu, the palette and the editor's own picker all read one value.
    @AppStorage(EditorMode.storageKey) private var storedMode = EditorMode.edit.rawValue

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
    /// Searching the library — the same implementation the iPad runs.
    ///
    /// This was four `@State` fields and a `scheduleSearch` written once here
    /// and once in `iOSContentView`, with two debounces, two minimum query
    /// lengths and two merge rules. The iPad's discarded its snippets and never
    /// collected attachment hits at all, so a phrase inside a PDF was
    /// unfindable there. See `LibrarySearch`.
    @State private var search = LibrarySearch()

    /// A separate Spotlight query for the references panel's unlinked-mention
    /// candidates, so selecting a note never cancels an in-flight sidebar search
    /// (each SpotlightSearch supersedes its own previous query).
    @State private var referenceSpotlight = SpotlightSearch()

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

    /// Backlinks, outgoing links and unlinked mentions, computed off the
    /// typing path — see `NoteReferences`. Shared, because the iPad built the
    /// first two inline in `body`.
    @State private var references = NoteReferences()

    /// Which compact place is showing, and whether the note is full-screen.
    /// Only read below the compact threshold, which a Mac window reaches only
    /// when the OS forces it past the declared minimum.
    @SceneStorage(CompactPlace.storageKey) private var compactPlaceRaw = CompactPlace.notes.rawValue

    @State private var noteIsExpanded = false

    /// Sidebar expansion, held by the shell so both platforms keep it across a
    /// rebuild. The AppKit outline manages its own and ignores these; they are
    /// here so the call site is one call site.
    @SceneStorage("expandedFolders") private var expandedFolderIDs = ""

    @State private var collapsedCollections: Set<Collection.ID> = []

    private var place: CompactPlace {
        get { CompactPlace(rawValue: compactPlaceRaw) ?? .notes }
        nonmutating set { compactPlaceRaw = newValue.rawValue }
    }

    /// The same binding the other shell hands `CompactShell`.
    private var compactPlace: Binding<CompactPlace> {
        Binding(get: { CompactPlace(rawValue: compactPlaceRaw) ?? .notes },
                set: { compactPlaceRaw = $0.rawValue })
    }

    @State private var showOpenQuickly = false

    /// ⌘⇧P — every command, findable by name. See `CommandPalette.swift`.
    @State private var showPalette = false

    /// An in-progress link review, with the text the proposals were generated
    /// against so stale ranges can be detected rather than applied.
    @State private var linkReview: LinkReviewFlow.Request?

    /// ⌃⌘N — write or research a new note. The composer owns the run so that
    /// closing the sheet mid-research cancels it rather than orphaning it.
    @State private var composer = NoteComposer()

    @State private var showCompose = false

    /// Research only calls read-only tools, so this broker is never consulted;
    /// it exists because `ToolContext` requires one.
    @State private var composePermissions = PermissionBroker()

    /// Rename-note prompt state (set via the context menu or the Note menu).
    @State private var renameTarget: Note?

    @State private var renameText = ""

    /// New-folder prompt state (set via the note-list context menu).
    @State private var newFolderCollection: Collection?

    @State private var newFolderParent: URL?

    @State private var newFolderName = ""

    /// Active tag filter, if any (within the focused collection). Set from the
    /// inspector's Tags tab — the rails cooperate across the shell (decision 1).
    @State private var selectedTag: String?

    /// The right inspector rail. Per window, and remembered, because it is a
    /// place the user works in rather than something they summon (decision 10).
    /// Whether the inspector is showing. **`false` by default, on both.**
    ///
    /// It was `true` on the Mac and `false` on iOS — one key, two answers — and
    /// picking the Mac's created a worse problem: below 1400pt there is no
    /// inspector *column*, so a stored `true` meant the window opened with a
    /// modal panel over the note. Suppressing that with a hidden "opened by
    /// hand this session" flag made the toolbar toggle draw as selected while
    /// nothing was on screen — a control saying on with nothing shown, which is
    /// the defect this whole pass exists to remove.
    ///
    /// `false` is the only value with no inconsistency: a fresh scene has the
    /// toggle off and no panel, turning it on gives a column where there is
    /// room and an overlay where there is not, and the toggle always reports
    /// what is actually visible. The cost is that a wide Mac no longer opens
    /// with the inspector already showing, which is a real change and worth it
    /// for a control that never lies.
    @SceneStorage("inspectorPresented") private var inspectorPresented = false

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
    @SceneStorage(RailPlaceStorage.key) private var railPlaceID = RailPlaceStorage.unset

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
    /// The scene's width, for `AuxiliaryPresentation`. Measured here rather
    /// than read from `\.shell`, because this view *supplies* the shell's slots
    /// and so sits outside the context the shell publishes.
    @State private var shellWidth: CGFloat = 0

    /// An auxiliary surface presented as a sheet, when the canvas is too narrow
    /// for a window. `nil` is the ordinary case on any full-size window.
    @State private var auxiliarySheet: AuxiliarySurface?

    /// Open Graph / Ask Library / Assistant — a window where there is room for
    /// one, a sheet where there is not. The decision is `AuxiliaryPresentation`
    /// and it is keyed on width, never on the platform.
    private var auxiliary: AuxiliaryOpener {
        AuxiliaryOpener(openWindow: openWindow, width: shellWidth) { auxiliarySheet = $0 }
    }

    /// The editor showing the selected note, if any. `ShellActions` owns it, so
    /// the two shells cannot resolve "the open editor" differently.
    private var activeEditor: EditorModel? { actions.activeEditor }

    /// The collection the editor's note belongs to, falling back to the focused
    /// one. Resolved from the selection's URL rather than from a `Note` lookup:
    /// an attachment has no `Note`, and the Mac's version returned the *focused*
    /// collection for one.
    private var editorCollection: Collection? {
        if let id = selectedNoteID, let owner = library.collection(containing: id) { return owner }
        return focused
    }

    /// Follow a `[[wiki link]]`.
    ///
    /// The decision is `WikiLinkNavigation`'s. What was left here was written
    /// twice and had drifted: only the iPad's awaited `tabs.editor(for:)`
    /// before scrolling, because the tab has to exist before anything can
    /// scroll inside it and a fresh one needs a beat to lay out. The Mac's
    /// jumped straight to the heading, which on a note that was not already
    /// open scrolled nothing. And opening a web link was `NSWorkspace` on one
    /// and `UIApplication` on the other, which is `FileReveal.openInDefaultApp`.
    private func openWikiLink(_ target: String) {
        Task {
            switch await WikiLinkNavigation.resolve(target: target,
                                                    in: editorCollection,
                                                    current: activeEditor?.note) {
            case .web(let url):
                FileReveal.openInDefaultApp(url)
            case .note(let destination, let heading):
                let switching = selectedNoteID != destination.id
                selectedNoteID = destination.id
                if let heading {
                    await tabs.editor(for: destination)
                    if switching { try? await Task.sleep(for: .milliseconds(350)) }
                    scrollToHeading(heading)
                }
            case .none:
                break
            }
        }
    }

    /// Turn the first mention of the open note in `note` into a link.
    private func linkMention(_ note: Note) {
        guard let target = activeEditor?.note, let c = editorCollection else { return }
        Task { await MentionLinker.linkFirstMention(of: target.title, in: note, collection: c) }
    }

    /// Jump the editor to a heading — and clear the highlight afterwards, which
    /// the iPad's copy of this never did, so a jumped-to heading stayed
    /// highlighted until something else happened to clear it.
    private func scrollToHeading(_ title: String) {
        hnJumpToHeadingInEditor(titled: title)
    }

    private func beginLinkReview() {
        guard let editor = activeEditor else { return }
        let text = editor.text
        Task {
            // `editorCollection`, not `focused`: the proposals are offsets into
            // *this* note's text and are looked up in *its* index.
            linkReview = await LinkReviewFlow.begin(text: text,
                                                    noteURL: editor.note?.fileURL,
                                                    in: editorCollection)
        }
    }

    private func applyAcceptedLinks(_ accepted: [LinkProposal], reviewedText: String) {
        guard let editor = activeEditor else { return }
        switch LinkReviewFlow.apply(accepted, reviewedText: reviewedText,
                                    currentText: editor.text) {
        case .apply(let text):    editor.text = text
        case .stale(let message): editorCollection?.lastError = message
        case .nothing:            break
        }
    }

    private var propertiesBinding: Binding<[Property]> {
        Binding(
            get: { FrontMatter.properties(in: activeEditor?.text ?? "") },
            set: { updated in
                guard let editor = activeEditor else { return }
                editor.text = FrontMatter.applying(updated, to: editor.text)
            }
        )
    }

    /// Open the inspector on the tab that answers `kind`.
    private func askInspector(_ kind: InspectorRequest.Kind) {
        let request = InspectorRequest(kind: kind, token: (inspectorRequest?.token ?? 0) + 1)
        inspectorTabRaw = request.tab.rawValue
        inspectorPresented = true
        inspectorRequest = request
    }

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

    /// The attachment file the current selection points at, if any.
    private var selectedAttachment: CollectionFile? {
        library.collections.lazy.compactMap { c in c.attachments.first { $0.url == selectedNoteID } }.first
    }

    // MARK: - Note list rows

    /// A collection paired with its full-text search hits (for grouped results).
    /// `fileRows` are attachments (PDFs, documents, …) whose *content* matched,
    /// found via the system Spotlight index rather than the app's own index.

    /// Recompute the debounced search results. Runs at most once per ~200 ms of
    /// typing (not per keystroke), and computes the groups once (they used to be
    /// recomputed twice per body — for the rows and the empty-state check).


    // MARK: - Editor derived data (for the selection's collection)

    var body: some View {
        // Split in two deliberately: the scene wiring (a dozen `onChange`
        // handlers, a `task`, and a stack of sheets and alerts) is one
        // expression to the type checker, and this chain has already defeated
        // it once. Two opaque halves are two smaller problems.
        presentations(sceneLifecycle(sceneWiring(shellCore)))
            // **`erroringCollection`, not `focused`.** Nineteen `report(…)`
            // sites write `Collection.lastError`, and the sidebar holds one
            // tree over *every* open collection whose note actions resolve
            // their owner with `library.collection(containing:)` — so an alert
            // watching only the focused collection stays silent for exactly the
            // operations that most often fail. The Mac watched `focused`.
            .modifier(FileOperationErrorAlert(collection: erroringCollection))
            .modifier(FolderDeleteConfirmation(folder: $pendingFolderDelete) { folder in
                if let c = collection(owningFolder: folder) {
                    Task { await c.deleteFolder(at: folder) }
                }
            })
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { shellWidth = $0 }
            // `Library` asks for a picker rather than presenting one; the shell
            // owns the picker, so the shell answers — **with what was asked
            // for**. The request carries where to start and what to say, and
            // discarding that is how "add a mounted cloud folder" opened
            // nowhere near the providers and "choose a subfolder" reopened
            // outside the folder it was narrowing.
            .sheet(item: Binding(get: { library.pendingFolderPick },
                                 set: { library.pendingFolderPick = $0 })) { request in
                FolderPicker(startingAt: request.startDirectory,
                             prompt: request.prompt,
                             message: request.message) { urls in
                    library.pendingFolderPick = nil
                    guard !urls.isEmpty else { return }
                    Task { await library.openPicked(urls) }
                }
            }
            // An auxiliary surface where the canvas is too narrow for a window.
            // A Mac window dragged below the shell's compact threshold has no
            // more room for a second window than an iPhone does; the rule is
            // the canvas, not the OS.
            .sheet(item: $auxiliarySheet) { surface in
                AuxiliarySheet(surface: surface,
                               addRemoteCollection: library.addRemoteCollection)
            }
    }


    private var shellCore: some View {
        AdaptiveShell(
            inspectorPresented: $inspectorPresented,
            columnVisibility: $columnVisibility,
            // Asked of the hardware, not of the OS — see `PointerPresence`. It
            // decides whether the format bar exists at all, so hard-coding it
            // per platform was the layout differing by device.
            prefersTouch: PointerPresence.shared.prefersTouch,
            sidebar: { collectionTree },
            // The one slot still drawn per platform, and the gate has both
            // branches: each supplies an editor column, and what differs is
            // the *toolbar* over it — `shell-chrome.md` Part 5 measures the
            // Mac's positions in ChromeLab, and the touch column carries the
            // tab strip and note menu the same contract asks for at that size.
            pane: {
                #if os(macOS)
                editorColumn
                #else
                detail(showsShellCommands: true)
                #endif
            },
            inspector: { inspector },
            compact: { compactShell }
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
    }

    /// Everything that wires the shell to its scene — the `onChange` handlers,
    /// the launch `task`, the receivers and the splash overlay.
    ///
    /// Its own function because the chain is one expression to the type
    /// checker, and joined to `shellCore` it trips "unable to type-check in
    /// reasonable time". The two shells each carried a note predicting exactly
    /// that; merging them proved it.
    private func sceneWiring<V: View>(_ content: V) -> some View {
        content
        .onReceive(NotificationCenter.default.publisher(for: .hnFocusLibrarySearch)) { _ in
            // Opening the sidebar too: a search whose results land in a hidden
            // panel is a dead end, and ⌥⌘F is a request to *look* for something.
            if columnVisibility == .detailOnly {
                withAnimation(.easeInOut(duration: 0.18)) { columnVisibility = .all }
            }
            searchFocused = true
        }
        .declaredWindowMinimum()
        .task {
            // A hosted test bundle launches this app to run in. Restoring the
            // user's real library there is both a privacy surprise and the
            // reason the suite crawled: 2,000 notes of coordinated cloud I/O
            // land on the same main actor the tests run on. See TestEnvironment.
            guard !TestEnvironment.isRunningTests else { return }
            // Once per process, through `SplashPresenter` — a floating window
            // on one platform and the overlay below on the other.
            if !Self.didShowSplash {
                Self.didShowSplash = true
                SplashPresenter.show(autoDismiss: true)
            }
            library.onExternalChange = { @MainActor in
                Task { await tabs.reconcileAll() }
                actions.revalidateSelection()
            }
            wireTabs()
            TerminationGuard.current?.register(tabs) { [tabs] in await tabs.flushAll() }
            library.onOpened = { recents.record($0) }
            if library.isEmpty {
                await library.restore()
                // First run with nothing to restore: onboard a brand-new user,
                // otherwise (welcome already seen) go straight to the launcher.
                if library.isEmpty {
                    // `pendingWelcome`, not `showWelcome`: onboarding opened
                    // *over* the launch splash on one platform. And the
                    // launcher, which the other platform never offered — an
                    // empty library with onboarding already seen got a blank
                    // shell and no prompt.
                    // `splashFinished` matters because the restore can outrun
                    // the splash *or* trail it: a 2,000-note vault takes longer
                    // than the 3.5s linger, and pending a handoff that has
                    // already happened strands onboarding just as surely as
                    // waiting on a signal that never comes.
                    if hasSeenWelcome {
                        showLauncher = true
                    } else if splashFinished {
                        showWelcome = true
                    } else {
                        pendingWelcome = true
                    }
                }
            }
            // Reopen the last-focused collection + note (if still present).
            if !restoredCollectionID.isEmpty,
               library.collections.contains(where: { $0.id == restoredCollectionID }) {
                library.focusedID = restoredCollectionID
            }
            // Unattended diagnostics: drive the reported-slow paths against the
            // real vault, with the real views observing, and log what happens.
            // Inert unless HN_SELFTEST is set on a Debug build.
            if DiagnosticSelfTest.isEnabled, let collection = library.focused ?? library.collections.first {
                let hooks = DiagnosticSelfTest.Hooks(
                    select: { selectedNoteID = $0 },
                    editor: { await tabs.editor(for: $0) },
                    close: { _ = await tabs.close($0) })
                Task { await DiagnosticSelfTest.run(on: collection, hooks: hooks) }
            }
            if !restoredNotePath.isEmpty {
                let url = URL(fileURLWithPath: restoredNotePath)
                if library.allNotes.contains(where: { $0.id == url }) { selectedNoteID = url }
            }
            // A window that has never had its rail moved opens in the focused
            // collection, not on the Library place: the notes are the point.
            if railPlaceID == RailPlaceStorage.unset {
                railPlaceID = library.focusedID ?? ""
            }
        }
        .onChange(of: selectedNoteID) { _, newID in
            restoredNotePath = newID?.path ?? ""
            openSelectedNote(newID)
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
            actions.revalidateSelection()
            library.writeWidgetSnapshot()   // refresh the recent-notes widget
            Task { await router.donateNotesToSpotlight() }   // system Spotlight
        }
        .onChange(of: searchText) { _, q in search.update(query: q, in: library.collections) }
        .onChange(of: router.pendingSearch) { _, query in
            guard let query else { return }
            showOpenQuickly = false
            selectedTag = nil
            searchText = query
            router.pendingSearch = nil
        }
        // Rebuild the (cached) note-list outline only when its structural inputs
        // change — not on every unrelated body re-eval (selection, git, accent).
        .onChange(of: SidebarTreeModel.key(sidebarInputs), initial: true) { _, _ in
            MainActorWatchdog.measure("rebuildOutline") { sidebarTree.refresh(sidebarInputs) }
        }
        // Recompute the references panel off-main when the selection or index
        // changes — never inline in the body (would scan all notes on selection).
        .task(id: NoteReferences.key(note: selectedNote, in: editorCollection)) {
            await references.refresh(note: selectedNote, in: editorCollection,
                                     spotlight: referenceSpotlight)
        }
        // A save schedules an auto-commit (if enabled) and a debounced status
        // refresh. The rules are `GitService.noteDidSave`'s — they were fifteen
        // lines here and nothing at all in the other shell.
        .onChange(of: tabs.totalSavedRevision) { _, _ in
            guard let c = editorCollection else { return }
            c.git.noteDidSave(autoCommitEnabled: autoCommit,
                              isCloudBacked: CloudProvider.name(for: c.rootURL) != nil)
        }
    }

    /// The second half of the wiring. Split for the same reason as the first:
    /// SwiftUI modifier chains are one expression, and this one is long.
    private func sceneLifecycle<V: View>(_ content: V) -> some View {
        content
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                // Through the guard, so the drain runs under a background-task
                // assertion rather than racing suspension. A bare
                // `Task { await tabs.flushAll() }` here is exactly the
                // unprotected flush the guard was written to replace.
                Task { await TerminationGuard.current?.flushUnderAssertion() }
            }
        }
        .onAppear {
            // On ⌘Q, drain this window's pending autosaves before exit
            // (terminateLater handshake) so no debounced edit is lost.
            TerminationGuard.current?.register(tabs) { [tabs] in await tabs.flushAll() }
        }
        .onDisappear { TerminationGuard.current?.unregister(tabs) }
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

        .onReceive(NotificationCenter.default.publisher(for: .hnSplashDidFinish)) { _ in
            // Present onboarding only after the launch splash has gone.
            //
            // Driven by the notification both presentations post, not by
            // `showSplash`: that flag is the *overlay's*, and only the platform
            // with an overlay ever sets it. Reading it here meant the Mac — a
            // separate splash window, flag never true — never reached this at
            // all, so a fresh install got no Welcome sheet and, since
            // `hasSeenWelcome` is written only when that sheet is dismissed, no
            // launcher on any launch afterwards either.
            splashFinished = true
            if pendingWelcome {
                pendingWelcome = false
                showWelcome = true
            }
        }

        .onReceive(NotificationCenter.default.publisher(for: .hnOpenAISettings)) { _ in
            showLLMSettings = true
        }

        .onReceive(NotificationCenter.default.publisher(for: .hnShowSplash)) { note in
            splashAutoDismisses = note.userInfo?["autoDismiss"] as? Bool ?? true
            withAnimation(.easeIn(duration: 0.2)) { showSplash = true }
        }

        .overlay {
            if showSplash {
                SplashScreenView { dismissSplashOverlay() }
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .task(id: splashAutoDismisses) {
                        guard splashAutoDismisses else { return }
                        try? await Task.sleep(for: .seconds(2.8))
                        dismissSplashOverlay()
                    }
            }
        }
    }

    /// Take the splash overlay down and say so, on the same channel the Mac's
    /// splash window uses — the shell has work waiting on it (onboarding).
    private func dismissSplashOverlay() {
        guard showSplash else { return }
        withAnimation(.easeOut(duration: 0.5)) { showSplash = false }
        NotificationCenter.default.post(name: .hnSplashDidFinish, object: nil)
    }




    /// Every sheet, alert and scene value the window owns — the second half of
    /// the split described in `body`.
    private func presentations<V: View>(_ content: V) -> some View {
        content
        // The large-folder warning. It was an `NSAlert` inside `Library`, which
        // is what kept it off the other platform entirely.
        .largeFolderAlert(library)
        // Settings as a sheet. On the Mac ⌘, opens the `Settings` scene and
        // this is a second route to the same screen; on iOS there is no such
        // scene, so it is the only one. `AppSettingsView` is the name that
        // lets this line exist without a gate around it.
        .sheet(isPresented: $showSettings) {
            AppSettingsView(llmSettings: llmSettings, appearance: appearance,
                            git: focused?.git, accounts: gitAccounts)
        }
        .sheet(isPresented: $showLLMSettings) {
            NavigationStack {
                LLMSettingsView(settings: llmSettings)
            }
        }
        .sheet(isPresented: $showPalette) {
            CommandPaletteView(commands: appActions.paletteCommands)
        }
        // One presentation. It was declared in the shell's sheet stack *and*
        // again on the editor column, so on iPad the same review could be
        // presented twice over itself.
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
        .sheet(isPresented: $showCompose, onDismiss: { composer.reset() }) {
            ComposeNoteView(
                composer: composer,
                availability: { NoteComposer.unavailableReason(for: $0, settings: llmSettings) },
                onRun: { prompt, mode, depth in runCompose(prompt, mode: mode, depth: depth) },
                onCreate: { draft in
                    // `railCollection ?? focused`, matching `runCompose`. Asking
                    // `focused` alone meant that with two collections open,
                    // Create wrote the note into a different one than Run did —
                    // two buttons in one sheet disagreeing about where the note
                    // lands.
                    guard let c = railCollection ?? focused else { return }
                    Task {
                        if let note = await composer.create(draft, in: c) {
                            selectedNoteID = note.id
                        }
                    }
                })
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
                onOpenObsidian: { showWelcome = false; library.requestOpenCollections() },
                onDismiss: { showWelcome = false }
            )
        }
        .sheet(isPresented: $showQuickCapture) {
            QuickCaptureView(router: router)
                .panelFrame(width: 460, height: 320)
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
                onOpenObsidian: { library.requestOpenCollections() },
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
            TextField("Title", text: $renameText)
            Button("Rename") { actions.commitRename() }
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
    ///
    /// One value on both platforms, so a command cannot mean two things. Where
    /// the two versions of this disagreed, the disagreements were bugs:
    ///
    ///   · the Mac scoped New Note, Open Quickly, Graph and Rescan to
    ///     `library.focused` and the iPad to the sidebar's selection. CLAUDE.md
    ///     says the sidebar's selection, and with two collections open the
    ///     Mac's commands acted on the wrong one.
    ///   · the iPad ran commands without dismissing the Open Quickly palette,
    ///     so Rename stacked an alert on the sheet and Find toggled a bar
    ///     nobody could see.
    ///   · Quick Capture was unconditional on the Mac; it writes to today's
    ///     daily note, which needs a collection.
    ///   · `canCloseTab` asked only whether a note was selected on the iPad, so
    ///     ⌘W was enabled over a tab that had no editor behind it yet.
    private var appActions: AppActions {
        let scope = railCollection ?? focused
        return AppActions(
            canNewNote: scope != nil,
            newNote: closingOpenQuickly { newNote() },
            todaysNote: closingOpenQuickly { openTodaysNote() },
            openLauncher: closingOpenQuickly { showLauncher = true },
            canOpenQuickly: !(scope?.notes.isEmpty ?? true),
            openQuickly: { showOpenQuickly = true },
            canGraph: !(scope?.notes.isEmpty ?? true),
            graphView: closingOpenQuickly { auxiliary.open(.graph) },
            // Asking the library needs notes to ask *about*, not a collection
            // to stand in.
            canAsk: !library.allNotes.isEmpty,
            askLibrary: closingOpenQuickly { auxiliary.open(.askLibrary) },
            assistant: closingOpenQuickly { auxiliary.open(.assistant) },
            canCloseTab: tabs.openNotes.count > 1 && activeEditor != nil,
            closeTab: closingOpenQuickly { if let id = selectedNoteID { closeTab(id) } },
            // Format and Note commands target the note *behind* the palette
            // (Rename would even stack an alert on the sheet), so they grey
            // out while it's presented instead of dismissing it.
            format: showOpenQuickly ? nil : activeEditor?.note.map { note in
                { (action: FormatAction) in
                    NotificationCenter.default.post(
                        name: .hnFormat(action.kind, documentId: note.fileURL.path),
                        object: nil, userInfo: action.userInfo)
                }
            },
            note: showOpenQuickly ? nil : activeEditor?.note.map { note in
                NoteMenuActions(
                    isBookmarked: actions.isBookmarked(note),
                    rename: { actions.beginRename(note) },
                    duplicate: { actions.duplicate(note) },
                    toggleBookmark: {
                        library.collection(containing: note.fileURL)?.bookmarks.toggle(note)
                    },
                    copyWikiLink: { Clipboard.copy(note.wikiLink) },
                    revealInFileManager: FileReveal.canReveal(note.fileURL)
                        ? { FileReveal.reveal(note.fileURL) } : nil,
                    openInNewWindow: { openWindow(value: NoteRef(note.fileURL)) },
                    // `actions.export`, not the active editor's buffer: read
                    // that way, exporting or printing a note that was not open
                    // in an editor did nothing at all. The shared action prefers
                    // the live buffer, downloads a cloud note that has never
                    // been opened, and reports rather than writing a blank file
                    // when there is nothing to export.
                    exportHTML: { actions.export(note, as: .html) },
                    exportPDF: { actions.export(note, as: .pdf) },
                    printNote: { actions.export(note, as: .print) },
                    moveToTrash: { actions.delete(note) }
                )
            },
            rescan: scope.map { collection in { collection.rescan() } },
            showsNonNoteFiles: scope?.showsNonNoteFiles,
            setShowsNonNoteFiles: scope.map { collection in
                { collection.showsNonNoteFiles = $0 }
            },
            openCloudFolder: { library.requestOpenCloudFolder() },
            refreshCloudCollection: scope.flatMap { collection in
                collection.isRemote ? { Task { await collection.refreshFromProvider() } } : nil
            },
            // Quick Capture writes into today's daily note, so it needs a
            // collection to write into.
            quickCapture: library.isEmpty ? nil : { showQuickCapture = true },
            templates: Templates.available(in: scope, folder: templatesFolder),
            insertTemplate: activeEditor == nil ? nil : { actions.insertTemplate($0) },
            commandPalette: { showPalette = true },
            ai: aiActions,
            reviewLinks: (!showOpenQuickly && activeEditor?.note != nil && editorCollection != nil)
                ? { beginLinkReview() } : nil,
            // Needs a collection to put the note in, but no note open and no
            // particular provider: the sheet itself says which modes can run,
            // which is more useful than a menu item that is simply absent.
            composeNote: scope == nil ? nil : closingOpenQuickly { showCompose = true },
            newWindow: { openWindow(id: "main") },
            // Find targets the note *behind* the palette, so it greys out while
            // that is up rather than toggling a find bar nobody can see.
            // `hnEditorToggleFind` is what `NoteEditorView` listens on, and
            // `NoteEditorView` is the editor column on both platforms — the
            // iPad posted `hnFind(documentId:)` instead, which nothing in the
            // shell receives.
            find: (showOpenQuickly || activeEditor?.note == nil) ? nil : {
                NotificationCenter.default.post(name: .hnEditorToggleFind, object: nil)
            },
            searchAllCollections: closingOpenQuickly {
                NotificationCenter.default.post(name: .hnFocusLibrarySearch, object: nil)
            },
            connectOverWeb: { auxiliary.open(.cloud($0)) },
            editorMode: EditorMode.mode(storedMode),
            setEditorMode: { storedMode = $0.rawValue }
        )
    }

    /// Start a composition run against the focused collection.
    private func runCompose(_ prompt: String, mode: NoteComposer.Mode, depth: Int) {
        // The sidebar's selection, per CLAUDE.md — anything keyed on a
        // collection reads it. This asked `focused`, so with two collections
        // open Compose wrote the new note into the wrong one.
        guard let scope = railCollection ?? focused else { return }
        ComposeRun.start(prompt: prompt, mode: mode, depth: depth, in: scope,
                         composer: composer, permissions: composePermissions,
                         settings: llmSettings)
    }

    /// The AI commands, or `nil` when they would only disappoint — no note
    /// open, or no provider that can actually answer. A greyed-out menu item
    /// says "not now"; an enabled one that always errors says "this app is
    /// broken", and the second is the lie.
    private var aiActions: AIActions? {
        // `!showOpenQuickly` as every sibling in `appActions` has: each of these
        // runs `askInspector`, which mutates the inspector's tab and
        // presentation underneath a sheet that is already up. The merge kept
        // the note check and dropped this one.
        guard !showOpenQuickly, activeEditor?.note != nil else { return nil }
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
    /// Bring the search field and its results on screen.
    ///
    /// Called by Find Related, which used to set `searchText` and stop — which
    /// at iPad width flipped the tree into a filtered state with no field on
    /// screen to edit or clear, and on a phone left the results on a screen you
    /// were not looking at. The Mac's copy of Find Related did not call this at
    /// all, so a collapsed sidebar there had the same problem.
    private func revealSearch(focusField: Bool) {
        if columnVisibility == .detailOnly {
            withAnimation(.easeInOut(duration: 0.18)) { columnVisibility = .all }
        }
        place = .search
        noteIsExpanded = false
        if focusField { searchFocused = true }
    }

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
                revealSearch(focusField: false)
            },
            explain: { phrase in
                library.askAboutSelection(phrase)
                auxiliary.open(.askLibrary)
            }
        )
    }

    /// Drop the selection if the note (or attachment) it pointed at is gone.
    /// Open the selected note — and **never fail silently**.
    ///
    /// This is the only path from a sidebar click to an open editor, and it used
    /// to be a bare `if let` over `library.allNotes` with no `else`. When the id
    /// was not in that list the selection was written and nothing else happened:
    /// no tab, no message, no log. The detail column fell through to "No Note
    /// Selected" and the app looked dead — a populated sidebar where every click
    /// did nothing, with an idle main thread and no way to tell why.
    ///
    /// Any mismatch between what the sidebar draws and what `allNotes` holds
    /// arrived at the user as that symptom. So the fallback opens the file the
    /// row actually names, and if even that is impossible it says so rather than
    /// shrugging.
    private func openSelectedNote(_ newID: URL?) {
        guard let newID else { return }
        if let note = library.allNotes.first(where: { $0.id == newID }) {
            library.focusCollection(containing: note.fileURL)
            Task { await tabs.editor(for: note) }
            return
        }
        // The sidebar named a note the list does not have. The file is usually
        // still there — a stale row, or two spellings of the same URL — so open
        // it by URL rather than discarding the click.
        guard FileManager.default.fileExists(atPath: newID.path) else {
            focused?.lastError = "“\(newID.lastPathComponent)” is no longer in this collection."
            return
        }
        library.focusCollection(containing: newID)
        let note = Note(title: newID.deletingPathExtension().lastPathComponent,
                        fileURL: newID,
                        lastModified: (try? FileManager.default.attributesOfItem(atPath: newID.path)[.modificationDate] as? Date) ?? Date())
        Task { await tabs.editor(for: note) }
    }

    // MARK: - Column 1: the collection tree

    /// The compact shell, at the sizes the OS can force *either* platform into.
    ///
    /// A bottom tab bar of places, with the open note persisting above it like
    /// a now-playing track (decision 6). The Mac used to fill this slot with
    /// `EditorPaneContainer { editorColumn }` — the editor alone — on the
    /// reading of decision 9 that says "degrade to the editor rather than an
    /// error". That was right when there was no compact shell to degrade *to*;
    /// the consequence was a window squeezed into a Stage Manager tile with **no
    /// way to reach another note at all**, while an iPad at the same 250pt
    /// showed the tab bar. `ShellKind` calls both `.compact`, in the contract's
    /// own scene table, so that was the contract broken rather than honoured.
    ///
    /// It then filled the slot with a compact shell whose places were not the
    /// same places: Notes and Search both drew the whole sidebar tree, and Tags
    /// drew the *inspector* with its tab forced over. Four places that are
    /// really two is not the architecture decision 6 describes, and it is not
    /// what the other platform showed at the same width.
    private var compactShell: some View {
        CompactShell(
            place: compactPlace,
            openNoteTitle: activeEditor?.note?.title,
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

    /// The sidebar: Recents and Bookmarks pinned above every open collection,
    /// each expanding into its own folder tree (`docs/shell-chrome.md` D2/D4).
    ///
    /// One construction, drawn by `NoteOutlineList` — an `NSOutlineView` on one
    /// platform and a SwiftUI `List` on the other, which is the same split
    /// `FileViewerView` makes for PDFs. What is *in* the tree is
    /// `SidebarTree.roots` and what a row *says* is `NoteRowContent`, both
    /// shared, so the widget is the only thing that differs.
    /// The library search field.
    ///
    /// **In the toolbar, leading, on both platforms**, which is what CLAUDE.md
    /// and `shell-chrome.md` D9 both say: commands live in the toolbar, search
    /// at the leading end, and never inside the collapsible column — a hidden
    /// command is an unreachable one.
    ///
    /// It was briefly `.searchable(placement: .sidebar)` here, in the name of
    /// using a native field on both platforms. That was one implementation, but
    /// it put search *inside* the sidebar and reversed a decision the docs
    /// record with two measured reasons (D9: `.searchable` collapses to a glyph
    /// at 860pt — the width where search matters most — and claims the trailing
    /// end of the band, pushing the inspector's tabs off the panel they belong
    /// to). Parity is not a licence to overrule the chrome contract; the answer
    /// that satisfies both is one hand-built field, placed leading, shared.
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
        // A *range*, not a fixed 190pt. Pinned, it did not fit a 335pt sidebar
        // navigation bar beside the toggle, and iPadOS moved it into the `•••`
        // overflow — the field vanished, which is the exact failure D9 records
        // for `.searchable` collapsing to a glyph. A minimum paired with a
        // maximum, as the layout contract requires everywhere else.
        .frame(minWidth: 120, idealWidth: 190, maxWidth: 260)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Search all collections")
    }

    private var collectionTree: some View {
        VStack(spacing: 0) {
            // A search over a half-built index comes back short. A false
            // negative is the most damaging thing a knowledge tool can produce,
            // because you cannot notice the note that did not come back — see
            // `CollectionStatusStrips`.
            SearchCompletenessNotice(collections: library.collections,
                                     isSearching: isSearching)
            outlineList
        }
        .navigationTitle("Collections")
        .overlay { SidebarEmptyState(
            library: library, search: search, searchText: searchText,
            selectedTag: selectedTag, scope: railCollection ?? focused,
            hasRecents: !(recents.entries.isEmpty && libraries.libraries.isEmpty),
            openCollection: { library.requestOpenCollections() },
            openRecent: { showLauncher = true },
            newNote: { actions.createNote(in: railCollection ?? focused, folderID: nil) }) }
        // The contract's one exception to "no command in the sidebar" is an
        // action whose subject *is* the sidebar's content, and these are all
        // "open something into this list". In the sidebar's own toolbar, which
        // is where the contract puts commands.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        library.requestOpenCollections()
                    } label: {
                        Label("Open Collection…", systemImage: "folder.badge.plus")
                    }
                    Button {
                        library.requestOpenCollections()
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

    // MARK: - Git section (the rail's collection)

    /// Git acts on the collection the rail is standing in; on the Library place
    /// it falls back to the focused one, so the button is never a dead end.
    private var gitCollection: Collection? { railCollection ?? focused }

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
            // The inspector, where the shell has no column for it. Shared —
            // the Mac had no overlay at all, so its own default 1100pt window
            // showed no inspector however many times you pressed the toggles.
            .inspectorOverlay(presented: $inspectorPresented) {
                VStack(spacing: 0) {
                    InspectorOverlayHeader(tabRaw: $inspectorTabRaw) {
                        inspectorPresented = false
                    }
                    Divider()
                    inspector
                }
            }
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
        // Search, at the leading end of the *editor* column's toolbar — the
        // window toolbar on macOS, the detail navigation bar on iOS. Not the
        // sidebar's own bar: that is inside the collapsible column, which the
        // contract forbids ("a hidden command is an unreachable command"), and
        // it is too narrow to hold a field beside the toggle. Here it also
        // survives the sidebar being collapsed, which is when P2 needs it.
        ToolbarItem(placement: .barLeading) { searchField }
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
        // Search is on `collectionTree`'s toolbar — the sidebar's own, which
        // is the panel it searches — at the leading end, on both platforms.

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

    @ViewBuilder
    private var editorPaneBody: some View {
        VStack(spacing: 0) {
            CollectionConditionBar(collection: focused,
                                  hasSelection: selectedNoteID != nil,
                                  onRetry: { c in Task { await library.retry(c) } })
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
                    gitCollection: c,
                    onGitSettings: { showGitSettings = true },
                    linkCandidates: c.search.linkTargets(),
                    tagCandidates: c.search.allTags(),
                    headingProvider: { c.search.headings(forName: $0) },
                    onOpenWikiLink: openWikiLink,
                    onOpenNote: { selectedNoteID = $0.id },
                    onLinkMention: linkMention,
                    onRenameNote: { title in selectedNote.map { actions.rename($0, to: title) } },
                    onShowMindMap: {
                        if let url = selectedNote?.fileURL { auxiliary.open(.mindMap(url)) }
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
                        .buttonStyle(.borderless)
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
                        .buttonStyle(.borderless)
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
                        .buttonStyle(.borderless)
                    Button("Remove") { library.close(focused) }
                        .buttonStyle(.borderless)
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
            statusBarButton("Graph view", "point.3.connected.trianglepath.dotted") { auxiliary.open(.graph) }
                .disabled(focused?.notes.isEmpty ?? true)
                // The tip used to hang off the sidebar's Graph button; the
                // status bar is where that command still lives on screen.
                .popoverTip(GraphTip())
            statusBarButton("Ask your library", "sparkles.rectangle.stack") { auxiliary.open(.askLibrary) }
                .disabled(library.allNotes.isEmpty)
            statusBarButton("Assistant", "sparkles") { auxiliary.open(.assistant) }
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
                VStack(alignment: .leading, spacing: 8) {
                    GitPane(collection: gitCollection) { showGitSettings = true }
                }
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
            roots: sidebarTree.roots,
            signature: sidebarTree.signature,
            selection: $selectedNoteID,
            revealID: $revealOutlineID,
            // Expansion state is the shell's on both platforms now — the
            // outline used to keep its own inside the representable, which is
            // why it survived a rebuild there and not on iPad.
            expandedFolders: expandedFolders,
            collapsedCollections: $collapsedCollections,
            focusedCollectionID: library.focusedID,
            accent: appearance.resolvedAccent,
            fontScale: appearance.textScale,
            // Every mode now shows collection group rows — the tree holds all
            // of them at once (D2) — so the owning collection is always read
            // from the group a node hangs under. The one exception is a tag
            // filter, whose rows are bare notes from the focused collection.
            scopedCollectionID: selectedTag == nil ? nil : (railCollection ?? focused)?.id,
            actions: actions.sidebarMenu,
            scopedCollection: railCollection ?? focused,
            onCloseCollection: { actions.closeCollection($0) },
            row: { note, snippet in AnyView(noteRow(note, snippet: snippet)) },
            onDropIntoFolder: { id, urls in actions.move(urls, intoFolderWithID: id) }
        )
    }

    // MARK: - Outline items (NSOutlineView data)

    // MARK: - Actions

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

    private var mode: EditorMode { EditorMode.mode(storedMode) }

    private var modeBinding: Binding<EditorMode> { EditorMode.binding($storedMode) }

    /// Stands in when no note is open, so the 30-odd `editor.` call sites do
    /// not each have to answer "and if there is nothing open?". The detail
    /// column shows `ContentUnavailableView` in that state anyway.
    @State private var noEditor = EditorModel()

    private var editor: EditorModel { actions.activeEditor ?? noEditor }

    @State private var showSettings = false

    /// Onboarding is queued during launch but only presented once the splash
    /// has gone, so it doesn't pop up over the splash.
    @State private var pendingWelcome = false

    /// Whether the launch splash has already finished — see `hnSplashDidFinish`.
    /// The restore that queues onboarding can land on either side of it.
    @State private var splashFinished = false

    /// Whether the open note is a Marp deck / holds Mermaid fences.
    ///
    /// Both used to be computed inline in `noteMenu`'s builder. `Menu(content:)`
    /// takes a non-escaping `ViewBuilder`, so both ran at construction time on
    /// the main actor — and `mermaidBlocks` is a whole-document regex with no
    /// early exit. Computed once here instead, off-main, against
    /// `docFeaturesKey`, which is the Mac's memoized `DocStats` with a cheaper
    /// key (see the `.task` for why the text itself is the wrong one here).
    @State private var docFeatures = NoteDocFeatures()

    /// Launch splash overlay; fades out after a beat (or on tap).
    /// Starts hidden on both. The launch splash is raised by
    /// `SplashPresenter.show(autoDismiss:)` in `shellCore`, which opens a
    /// window on one platform and posts to this overlay on the other — so a
    /// default of `true` would have drawn the overlay *and* the window.
    @State private var showSplash = false

    /// The launch splash fades itself; the one About raises waits to be tapped.
    @State private var splashAutoDismisses = true
    /// The whole-note rewrite sheet, raised from the editor's toolbar menu.

    /// Ask Library, and the question it should open with (`nil` = ask fresh).
    /// The agentic assistant, and the provider/key settings it needs. Both were
    /// macOS-only until 1.3 — and without the second, an iPad had no way to
    /// enter an API key at all, so every provider but Apple was unreachable.
    @State private var showLLMSettings = false

    /// Search and a tag filter are questions about the library and override the
    /// rail's scope; otherwise the Library place owns the note-list column.
    private var showsLibraryPlace: Bool {
        railPlace == .library && searchText.isEmpty && selectedTag == nil
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

    /// What `docFeatures` is computed against: which note is open, the tabs'
    /// combined save revision, and their combined *load* revision. Cheap to
    /// read every render, and it changes at most once per open or autosave
    /// rather than once per keystroke.
    ///
    /// `totalLoadRevision` is here because selecting a note runs this task
    /// *before* the tab exists: `EditorTabs.editor(for:)` appends the model
    /// only after awaiting the read, so the task body — which reads
    /// `editor.text` synchronously — saw the empty placeholder. Opening a note
    /// saves nothing, so neither of the other two components moved afterwards
    /// and the task never re-ran: a note full of Mermaid fences reached the
    /// menu with "Mermaid Diagrams" and "Present as Slides" both missing, and
    /// they stayed missing until something unrelated saved.
    private var docFeaturesKey: String {
        "\(selectedNoteID?.path ?? "")|\(tabs.totalSavedRevision)|\(tabs.totalLoadRevision)"
    }

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

    // `folder(forID:)` used to sit here: a third copy of the folder-id →
    // collection lookup with no callers, and the only one of the three that
    // tested `id.hasPrefix($0.id)` without the `"/"` separator — so
    // `/Vault` would have claimed a folder in `/VaultArchive`. The live
    // answers are `collection(owningFolder:)` above and
    // `ShellActions.collection(forFolderID:)`.

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

    /// Moving the rail is a navigation: it clears whatever was narrowing the
    /// note list, so switching collections never lands in the previous one's
    /// empty tag filter.
    private func select(_ place: RailPlace) {
        selectedTag = nil
        searchText = ""
        selectedNoteID = nil
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
                    Button("Open Collection") { library.requestOpenCollections() }
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
            ToolbarItem(placement: .barTrailing) {
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
                        library.requestOpenCollections()
                    } label: {
                        Label("Open Collection", systemImage: "folder.badge.plus")
                    }
                    Button {
                        library.requestOpenCollections()
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
                                // Through the collection: it knows whether this
                                // is a File-Provider placeholder or a mirror
                                // entry, and `FileIO.download` only handles the
                                // first — it threw for every direct-API
                                // provider and the `try?` swallowed it.
                                actions.download(note)
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
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if !library.isEmpty {
                ToolbarItem(placement: .barTrailing) {
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
            .init(title: "Open Collection", symbol: "folder.badge.plus") { library.requestOpenCollections() },
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
                auxiliary.open(.askLibrary)
            },
            .init(title: "Assistant", symbol: "sparkles", isEnabled: scope != nil) {
                auxiliary.open(.assistant)
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
        .toolbarTitleDisplayMode(.inline)
    }

    // MARK: - The inspector rail (right)

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
            askLibrary: { auxiliary.open(.askLibrary) },
            reviewLinks: editor.note != nil ? { beginLinkReview() } : nil,
            compose: scope == nil ? nil : { showCompose = true },
            assistant: { auxiliary.open(.assistant) },
            // iOS has no Preferences window, so AI settings needs a row here.
            aiSettings: { showLLMSettings = true },
            hasOpenNote: editor.note != nil)
    }

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
        VStack(spacing: 0) {
        // A collection that went unavailable said nothing here — the note
        // simply stopped saving. Same strip the Mac has always drawn.
        CollectionConditionBar(collection: railCollection ?? focused,
                               hasSelection: selectedNoteID != nil,
                               onRetry: { c in Task { await library.retry(c) } })
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
                .toolbarTitleDisplayMode(.inline)
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
                backlinks: references.backlinks,
                outgoingLinks: references.outgoingLinks,
                unlinkedMentions: references.unlinkedMentions,
                embedProvider: c.embedProvider,
                git: c.git,
                gitCollection: c,
                // The iPad's Git identity and accounts live inside Settings;
                // the Mac's are a sheet. Same screen, each platform's route.
                onGitSettings: { showSettings = true },
                linkCandidates: c.search.linkTargets(),
                tagCandidates: c.search.allTags(),
                headingProvider: { c.search.headings(forName: $0) },
                onOpenWikiLink: { openWikiLink($0) },
                onOpenNote: { selectedNoteID = $0.id },
                onLinkMention: linkMention,
                onRenameNote: { actions.rename(note, to: $0) },
                onShowMindMap: { auxiliary.open(.mindMap(note.fileURL)) },
                ai: aiActions,
                selectionActions: selectionActions(in: c)
            )
            // S3: the detail column is a viewport, whatever mode it is in.
            // Without the clamp the editor's or preview's ideal height sizes
            // the column, and the split view follows it past the screen.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The inspector, where the shell has no column for it. Shared —
            // the Mac had no overlay at all, so its own default 1100pt window
            // showed no inspector however many times you pressed the toggles.
            .inspectorOverlay(presented: $inspectorPresented) {
                VStack(spacing: 0) {
                    InspectorOverlayHeader(tabRaw: $inspectorTabRaw) {
                        inspectorPresented = false
                    }
                    Divider()
                    inspector
                }
            }
            .toolbarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView(
                "Select a Note",
                systemImage: "doc.text",
                description: Text("Choose a note from the list, or create a new one.")
            )
        }
        }
    }

    @ToolbarContentBuilder
    private func detailToolbar(showsShellCommands: Bool) -> some ToolbarContent {
        // Search, at the leading end of the *editor* column's toolbar — the
        // window toolbar on macOS, the detail navigation bar on iOS. Not the
        // sidebar's own bar: that is inside the collapsible column, which the
        // contract forbids ("a hidden command is an unreachable command"), and
        // it is too narrow to hold a field beside the toggle. Here it also
        // survives the sidebar being collapsed, which is when P2 needs it.
        ToolbarItem(placement: .barLeading) { searchField }
        // Leading — the commands that have to survive a collapsed sidebar.
        if showsShellCommands {
            ToolbarItem(placement: .barLeading) { shellCommandMenu }
        }
        if editor.note != nil {
            // The top line is tabs; one caret holds everything else.
            ToolbarItem(placement: .principal) { tabStrip }
            ToolbarItem(placement: .barTrailing) { noteMenu }
            // Trailing — the inspector, over the inspector, exactly as on the
            // Mac. iPad had no route to it at all: `inspectorPresented` was set
            // only by the AI commands, so Outline, Tags, References, Properties
            // and History existed and could not be opened by hand.
            ToolbarItem(placement: .barTrailing) { inspectorToggle }
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
                newNote()
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
                library.requestOpenCollections()
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
                    Button(browser.displayName) { auxiliary.open(.cloud(browser)) }
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
            newNote()
        }
        .accessibilityLabel("New Note, and app commands")
    }

    // MARK: - AI on the open note
    //
    // iOS has no menu bar, so the toolbar is the *only* fixed place a command
    // can live. Same four actions as the Mac, landing in the same inspector
    // tabs — the answer belongs with the thing it is about on both platforms,
    // and only the route to it differs.

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
                // **The way in to the mind map.** It was bound into a sheet and
                // never once
                // set to `true` anywhere in the codebase — every write was a
                // dismissal — so the whole surface was dead code on iOS. The Mac
                // reaches it from the editor's bottom bar; the bar's iPad
                // equivalent is this menu.
                Button { if let url = editor.note?.fileURL { auxiliary.open(.mindMap(url)) } } label: {
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
    }}

/// What the open note *is*, as far as the note menu needs to know.
///
/// Its own type because both scans are whole-document passes and the menu that
/// reads them is built on every body evaluation: computing them there put a
/// regex over the entire note on the main actor, run or not. `nonisolated` so
/// it can cross `offMain`, which requires `Sendable`.
private nonisolated struct NoteDocFeatures: Equatable, Sendable {
    var isMarp = false
    var hasMermaid = false

    init() {}

    init(text: String) {
        isMarp = MarpSlides.isMarp(text)
        hasMermaid = !MarkdownParsing.mermaidBlocks(in: text).isEmpty
    }
}
