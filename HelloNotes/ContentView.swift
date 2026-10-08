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
    /// Shared with the Settings scene — see `HelloNotesApp`.
    @Environment(GitAccountsStore.self) private var gitAccounts
    /// The two voluntary purchases, for the Settings sheet.
    @Environment(StoreService.self) private var store

    @State private var showGitSettings = false

    @State private var showClone = false

    /// The "open" launcher and its backing stores (recents + saved libraries).
    @State private var recents = RecentsStore()

    @State private var libraries = LibrariesStore()

    /// Connected cloud accounts, and the mounted cloud folders already used.
    @State private var cloudAccounts = CloudAccountsStore()

    @State private var showLauncher = false

    /// The "which cloud?" modal — see `CloudAccountPicker`.
    @State private var showCloudPicker = false

    /// Licences and credits, opened from About rather than Settings.
    @State private var showAcknowledgements = false

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

    /// Which model does what (the Assistant and Ask Library windows own their
    /// models; the editor's writing tools read this directly).
    @Environment(IntelligenceSettings.self) private var intelligenceSettings

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

    /// Width of the note list, which decides whether a row's date sits in a
    /// trailing column or on a second line (`ShellMetrics.noteRowTwoColumn`).
    @State private var outlineWidth: CGFloat = 0

    /// The container whose notes the tall band's right pane is showing.
    /// Unused by the column shells, which show one tree.
    @State private var bandContainerID: String?
    /// Whether the band is on screen — the container it chose is New Note's
    /// folder only then (`ShellActions.newNoteFolder`).
    @State private var bandIsShowing = false

    /// Width of the compact shell's note list, for the same two-column rule the
    /// sidebar follows (`ShellMetrics.noteRowTwoColumn`). An iPhone is under it
    /// and stacks; a compact-width iPad window can be over it.
    @State private var compactListWidth: CGFloat = 0
    private var compactRowIsWide: Bool { compactListWidth >= ShellMetrics.noteRowTwoColumn }

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
    /// rebuild — the one drawn list reads it, on both.
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

    /// Whether the left region is put away — the band on the tall shell, the
    /// sidebar column on the column shells. Per scene, like the inspector — a
    /// window remembers whether you were reading or navigating.
    ///
    /// **One stored value.** The toggle wrote this and a `@State` column
    /// visibility beside it, which a relaunch forgot: a column window came
    /// back showing the sidebar while the bar read Show Sidebar and kept the
    /// traffic lights' inset, and the first click only dropped the inset
    /// (primary.md §12, item 1; implemented.md §51.36). The key keeps its
    /// old name, so a window's remembered choice survives.
    @SceneStorage("bandHidden") private var bandHidden = false

    /// The column shells' form of `bandHidden`, for the shell that takes one.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { bandHidden ? .detailOnly : .all },
                set: { bandHidden = $0 == .detailOnly })
    }

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
    @AppStorage("sidePanel") private var panelRaw = SidePanel.outline.rawValue

    /// What the right panel is showing — the outline of this note, or the
    /// Assistant, or any of the others. One panel, one thing in it.
    private var panel: SidePanel {
        get { SidePanel(rawValue: panelRaw) ?? .outline }
        nonmutating set { panelRaw = newValue.rawValue }
    }

    /// The last AI request sent to the inspector from a menu command or the
    /// palette. See `InspectorRequest` — the counter inside it is what lets the
    /// same command run twice.
    @State private var inspectorRequest: InspectorRequest?
    /// Numbers the requests: one is cleared once it has run, so the next can
    /// no longer count on from it.
    @State private var inspectorRequests = 0

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
    @State private var shellSize: CGSize = .zero

    /// Show something in the right panel. Every command that produces
    /// something ancillary — the graph, a conversation, the note's own facts —
    /// ends here, because that is the one place ancillary things go.
    private func showPanel(_ choice: SidePanel) {
        withAnimation(.easeInOut(duration: 0.18)) {
            panel = choice
            inspectorPresented = true
        }
    }

    private func togglePanel() {
        withAnimation(.easeInOut(duration: 0.18)) { inspectorPresented.toggle() }
    }

    /// The right panel: its own header — what it is showing, a way to change
    /// it, a way to close it — over whichever view that is.
    private var trailingPanel: some View {
        VStack(spacing: 0) {
            SidePanelHeader(
                panel: Binding(get: { panel },
                               set: { choice in
                                   withAnimation(.easeInOut(duration: 0.18)) { panel = choice }
                               }),
                hasNote: activeEditor?.note != nil,
                accent: appearance.resolvedAccent,
                onClose: { togglePanel() })
            // The header draws its own rule, as the bar does.
            panelContent
        }
        .background(Chrome.Colour.chrome)
    }

    @ViewBuilder
    private var panelContent: some View {
        switch panel {
        case .graph:
            GraphPanel()
        case .askLibrary:
            LibraryChatPanel()
        case .assistant:
            AssistantPanel()
        case .mindMap:
            if let editor = activeEditor, let url = editor.note?.fileURL {
                MindMapPanel(rootURL: url, editorID: editor.editorID)
            } else {
                ChromeEmptyState("No Note", systemImage: "doc.text",
                                       description: Text("Open a note to map it."))
            }
        default:
            // The five that are facts about the open note.
            inspector
        }
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
    /// scroll inside it. The Mac's jumped straight to the heading, which on a
    /// note that was not already open scrolled nothing. And opening a web link
    /// was `NSWorkspace` on one and `UIApplication` on the other, which is
    /// `FileReveal.openInDefaultApp`.
    ///
    /// The tab then needed "a beat to lay out", which was a fixed 350ms before
    /// the jump; a tab that took longer scrolled nowhere. The jump waits for
    /// the tab instead (`EditorBus.requestHeadingJump`): whichever of its
    /// surfaces comes up first shows it.
    private func openWikiLink(_ target: String) {
        Task {
            switch await WikiLinkNavigation.resolve(target: target,
                                                    in: editorCollection,
                                                    current: activeEditor?.note) {
            case .web(let url):
                FileReveal.openInDefaultApp(url)
            case .note(let destination, let heading):
                selectedNoteID = destination.id
                if let heading {
                    // The destination's own editor — the jump is addressed to
                    // it, not to whichever editor is active by the time it lands.
                    let target = await tabs.editor(for: destination)
                    scrollToHeading(heading, in: target)
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

    /// Jump the editor to a heading, by name — a link carries a name and
    /// nothing else.
    private func scrollToHeading(_ title: String, in editor: EditorModel) {
        // The heading is found in the buffer and jumped to in the editor, so
        // the buffer has to hold what the editor holds.
        editor.carryLiveEdits()
        let text = editor.text
        let editorID = editor.editorID
        Task { await hnJumpToHeading(titled: title, in: text, editor: editorID) }
    }

    private func beginLinkReview() {
        guard let editor = activeEditor else { return }
        // Proposals are offsets into this text: it has to be what is on screen.
        editor.carryLiveEdits()
        let text = editor.text
        let version = editor.textVersion
        Task {
            // `editorCollection`, not `focused`: the proposals are offsets into
            // *this* note's text and are looked up in *its* index.
            linkReview = await LinkReviewFlow.begin(text: text,
                                                    version: version,
                                                    noteURL: editor.note?.fileURL,
                                                    in: editorCollection)
        }
    }

    private func applyAcceptedLinks(_ accepted: [LinkProposal], reviewed: LinkReviewFlow.Request) {
        guard let editor = activeEditor else { return }
        // The version after `applyEdit` has carried what is on screen: the
        // review stands only if nothing has moved since it began.
        editor.applyEdit { current in
            switch LinkReviewFlow.apply(accepted, reviewed: reviewed.version,
                                        now: editor.textVersion, to: current) {
            case .apply(let text):    return text
            case .stale(let message): editorCollection?.lastError = message; return nil
            case .nothing:            return nil
            }
        }
    }

    /// Open the inspector on the tab that answers `kind`.
    private func askInspector(_ kind: InspectorRequest.Kind) {
        inspectorRequests &+= 1
        let request = InspectorRequest(kind: kind, token: inspectorRequests)
        panel = request.tab
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
            .onGeometryChange(for: CGSize.self) { $0.size } action: { shellSize = $0 }
            // `Library` asks for a picker rather than presenting one; the shell
            // owns the picker, so the shell answers — **with what was asked
            // for**. The request carries where to start and what to say, and
            // discarding that is how "add a mounted cloud folder" opened
            // nowhere near the providers and "choose a subfolder" reopened
            // outside the folder it was narrowing.
            #if os(macOS)
            // Not a `.sheet`: hosting `NSOpenPanel` inside a SwiftUI sheet's
            // `.onAppear` layers three windows for what should be one — the
            // main window, an invisible SwiftUI sheet host, and the panel
            // itself — and every symptom chased here (a presentation race, a
            // panel that never became visible, a blank host window left on
            // screen) was that layering, not any one bug inside it. Trigger
            // the panel directly from the state change; nothing SwiftUI
            // hosts it, so there is no host window to race or go blank.
            .onChange(of: library.pendingFolderPick) { _, request in
                guard let request else { return }
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = true
                panel.canCreateDirectories = request.allowsCreatingFolders
                panel.prompt = request.prompt
                panel.message = request.message
                panel.directoryURL = request.startDirectory
                panel.begin { response in
                    library.pendingFolderPick = nil
                    guard response == .OK, let url = panel.urls.first else { return }
                    // A relocate request re-grants one specific collection —
                    // it must not fall into `openPicked`, which only ever adds.
                    if case .relocate(let collectionID, _) = request {
                        Task { await library.relocate(collectionID: collectionID, to: url) }
                    } else {
                        Task { await library.openPicked(panel.urls) }
                    }
                }
            }
            #else
            .sheet(item: Binding(get: { library.pendingFolderPick },
                                 set: { library.pendingFolderPick = $0 })) { request in
                FolderPicker(startingAt: request.startDirectory,
                             prompt: request.prompt,
                             message: request.message) { urls in
                    library.pendingFolderPick = nil
                    guard let url = urls.first else { return }
                    // A relocate request re-grants one specific collection —
                    // it must not fall into `openPicked`, which only ever adds.
                    if case .relocate(let collectionID, _) = request {
                        Task { await library.relocate(collectionID: collectionID, to: url) }
                    } else {
                        Task { await library.openPicked(urls) }
                    }
                }
            }
            #endif
    }


    private var shellCore: some View {
        AdaptiveShell(
            inspectorPresented: $inspectorPresented,
            bandHidden: $bandHidden,
            columnVisibility: columnVisibility,
            sidebar: { collectionTree },
            // **One editor column, on both platforms.** This was the last slot
            // drawn per platform — `editorColumn` with its own toolbar on the
            // Mac, `detail` with a different one on iOS — and it is the reason
            // the two had different buttons in different places. The bar over
            // it is `shellBar`, drawn by the app, so it is the same pixels.
            pane: { detail(showsShellCommands: true) },
            inspector: { trailingPanel },
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
            if sidebarHidden {
                withAnimation(.easeInOut(duration: 0.18)) { bandHidden = false }
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
            // Once per process: the overlay below, on both platforms. It was a
            // floating window on the Mac and this overlay on iOS — two
            // presentations, two sizes and two timings of one picture.
            if !Self.didShowSplash {
                Self.didShowSplash = true
                presentSplash(autoDismiss: true)
            }
            wireTabs()
            TerminationGuard.current?.register(tabs) { [tabs] lettingGo in await tabs.flushAll(lettingGo: lettingGo) }
            library.onOpened = { recents.record($0) }
            if library.isEmpty {
                await library.restore()
                // Nothing restored and we have never seeded: this is a genuine
                // first run, so open the collection that ships with the app.
                // "Choose a folder" is a strange first instruction for someone
                // who has not yet seen what the app does with one — and a
                // reviewer given no collection cannot review the app at all.
                //
                // Gated on `hasSeeded`, not on the folder existing, so a user
                // who closes it *and* deletes the files is not given it back
                // every launch. `Open Default Collection` still restores it.
                if library.isEmpty, !DefaultCollection.hasSeeded,
                   let seeded = DefaultCollection.seedIfNeeded() {
                    _ = await library.open(url: seeded)
                }
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
            railPlaceID = RailPlaceStorage.following(railPlaceID, focus: newID)
        }
        .onChange(of: library.collections.count) { was, now in
            // Opening the first collection should land you in it rather than
            // leaving you on the Library place looking at quick actions.
            if was == 0, now > 0, railPlace == .library { railPlaceID = library.focusedID ?? "" }
        }
        .onChange(of: library.collections.map(\.id)) { _, open in
            // The collection the rail stood in has closed: with the focus.
            railPlaceID = RailPlaceStorage.keeping(railPlaceID, open: open, focused: library.focusedID)
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
        // About or Acknowledgements, asked for with no window open: this one
        // shows it — as it appears, or if it is open when it is asked.
        .onAppear { takeWindowRequest() }
        .onChange(of: WindowRequest.shared.pending) { _, _ in takeWindowRequest() }
        .onChange(of: library.pendingOpenNoteID) { _, id in
            // A right-panel view (graph, mind map, Ask Library) or
            // `NavigationRouter` asked us to show a note.
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
            // **Only when the set of notes actually changed.**
            //
            // `Note` is `Hashable` over `lastModified` and `fileSize`, so
            // `allNotes` changes on *every save of any note* — which used to
            // run all five of these, per save. Comparing identities instead
            // means a save is not news and only a genuine add or remove is.
            let ids = Set(notes.map(\.id))
            guard ids != knownNoteIDs else { return }
            knownNoteIDs = ids

            // A cached document captured which wiki-link targets existed when
            // it was built, so once the note set changes it would colour
            // [[links]] by a stale answer — but **never the open note**.
            // Forgetting that one rebuilds its text view, which drops first
            // responder: creating a note ejected you from the note you were
            // typing in. Nothing may take focus that the user did not.
            documents.forgetAll(except: editor.note?.fileURL.path)
            tabs.prune(keeping: ids)
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

    /// What a main window does when an open collection changes on disk: its
    /// tabs reconciled — a clean one reloads, one with unsaved edits raises the
    /// conflict banner — and its selection revalidated. Each window's own, for
    /// as long as it is open (`Library.observeExternalChanges(of:_:)`).
    ///
    /// **Nothing here holds the window.** The tabs are handed in by the
    /// library, which holds them weakly; the selection is a binding to one
    /// value of the window's state; the library is held weakly. It took the
    /// shell's `actions`, a value built from the whole view — whose state holds
    /// the tabs — so the library's weak hold on them held nothing.
    ///
    /// And it catches up: what changed while the window was not listening is
    /// looked at as it starts — nothing, the first time, with no tabs open.
    static func observeExternalChanges(of library: Library, tabs: EditorTabs, selection: Binding<Note.ID?>) {
        library.observeExternalChanges(of: tabs) { [weak library] tabs in
            Task { await tabs.reconcileAll() }
            if let library { ShellActions.revalidate(selection, in: library, tabs: tabs) }
        }
        Task { [weak tabs] in await tabs?.reconcileAll() }
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
            TerminationGuard.current?.register(tabs) { [tabs] lettingGo in await tabs.flushAll(lettingGo: lettingGo) }
            // A note changed on disk reaches this window's tabs — every open
            // window's, not the last one opened.
            Self.observeExternalChanges(of: library, tabs: tabs, selection: $selectedNoteID)
        }
        .onDisappear {
            library.stopObservingExternalChanges(of: tabs)
            // A window closing lets go of its tabs. Only unregistered, a tab
            // holding a conflict went with the window and kept mine nowhere,
            // and a tab left dirty by a write the app made was never saved —
            // and a quit waits for it as for a window still open: flushed in a
            // task nothing awaited, ⌘W and then ⌘Q during a slow write ended
            // the process with the save unfinished (`FlushRegistry.letGo`).
            if let termination = TerminationGuard.current {
                termination.letGo(tabs) { [tabs] in await tabs.flushAll(lettingGo: true) }
            } else {
                Task { [tabs] in await tabs.flushAll(lettingGo: true) }
            }
        }
        .task(id: docFeaturesKey) {
            // Off the main actor, memoized, and keyed on something that changes
            // at most once per autosave.
            //
            // `MarkdownParsing.mermaidBlocks` is a whole-document parse with no
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
            // A notification rather than a read of `showSplash`, from the days
            // the Mac's splash was a window of its own and never set that flag
            // — a fresh install then got no Welcome sheet at all. One
            // presentation now, and the signal is kept: it is the one thing
            // onboarding waits on.
            splashFinished = true
            if pendingWelcome {
                pendingWelcome = false
                showWelcome = true
            }
        }


        .overlay {
            if showSplash {
                SplashScreenView { dismissSplashOverlay() }
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .task(id: splashAutoDismisses) {
                        guard splashAutoDismisses else { return }
                        // **Long enough not to flash, and not one moment
                        // longer.** This was 2.8 seconds, plus a half-second
                        // fade — over three seconds of an app that was ready
                        // in far less, every single launch. A splash earns its
                        // place while there is genuinely nothing to show; past
                        // that it is a toll.
                        try? await Task.sleep(for: .milliseconds(500))
                        dismissSplashOverlay()
                    }
            }
        }
    }

    /// Raise the splash over this window — at launch, fading itself; from
    /// About, until dismissed.
    private func presentSplash(autoDismiss: Bool) {
        splashAutoDismisses = autoDismiss
        withAnimation(.easeIn(duration: 0.2)) { showSplash = true }
    }

    /// Take the splash overlay down and say so — the shell has work waiting on
    /// it (onboarding).
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
        .sheet(isPresented: $showSettings, onDismiss: { settingsPage = nil }) {
            AppSettingsView(intelligenceSettings: intelligenceSettings, appearance: appearance,
                            git: focused?.git, accounts: gitAccounts, store: store,
                            page: settingsPage)
        }
        .sheet(isPresented: $showPalette) {
            CommandPaletteView(commands: appActions.paletteCommands)
        }
        // One presentation. It was declared in the shell's sheet stack *and*
        // again on the editor column, so on iPad the same review could be
        // presented twice over itself.
        .sheet(item: $linkReview) { review in
            // Its own header is its bar; a `NavigationStack` here added the
            // platform's empty one above it on iOS.
            ReviewLinksView(
                proposals: review.proposals,
                noteText: review.noteText,
                preview: { await editorCollection?.openingLines(of: $0) ?? "" },
                onFinish: { applyAcceptedLinks($0, reviewed: review) },
                onDecline: { editorCollection?.declineLink($0) }
            )
        }
        .sheet(isPresented: $showCompose, onDismiss: { composer.reset() }) {
            ComposeNoteView(
                composer: composer,
                availability: { NoteComposer.unavailableReason(for: $0, settings: intelligenceSettings) },
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
            // The collection it is enabled for (`canOpenQuickly`): the
            // sidebar's, as everything keyed on a collection is. It searched
            // the focused one, so with two open it could be enabled for one
            // and search the other (menu.md §8, item 5; implemented.md §51.36).
            if let c = railCollection ?? focused {
                OpenQuicklyView(search: c.search) { selectedNoteID = $0.id }
            }
        }
        .sheet(isPresented: $showGitSettings) {
            // The repository the Git pane shows (`gitCollection`).
            if let c = gitCollection {
                // The Settings page, for this collection's repository, with a
                // bar of its own — the page has no title bar to lend it.
                VStack(spacing: 0) {
                    ChromeSheetBar("Git") {
                        EmptyView()
                    } trailing: {
                        Button("Done") { showGitSettings = false }
                            .keyboardShortcut(.cancelAction)
                    }
                    GitSettingsView(store: gitAccounts, git: c.git)
                }
                .chromeSheetFrame(width: AppSettingsView.size.width, height: AppSettingsView.size.height)
            }
        }
        .sheet(isPresented: $showClone) {
            CloneRepositoryView(store: gitAccounts, git: focused?.git ?? GitService()) { url in
                Task { await library.open(url: url) }
            }
        }
        .sheet(isPresented: $showWelcome, onDismiss: { hasSeenWelcome = true }) {
            WelcomeView(add: addCollectionActions,
                        onDismiss: { showWelcome = false })
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
                add: addCollectionActions
            )
        }
        .sheet(isPresented: $showAcknowledgements) {
            AcknowledgementsView()
        }
        .sheet(isPresented: $showCloudPicker) {
            CloudCollectionsManager(
                accounts: cloudAccounts,
                // Cloud-backed collections: mirrored from a provider's API, or
                // sitting in a folder its desktop client syncs here. Both are
                // "cloud folders" to the person who added them, however
                // differently the app reaches them.
                collections: library.collections.filter {
                    $0.isRemote || CloudProvider.name(for: $0.rootURL) != nil
                },
                makeModel: { account in
                    RemoteBrowserModel(store: account.provider.makeStore(accountID: account.id),
                                       onAdd: library.addRemoteCollection)
                },
                // On iOS the Files browser lists every enabled File Provider in
                // its own sidebar, so there is no separate place to point a
                // picker at — the same picker as "Open Folder" is the honest
                // answer there.
                onChooseSyncedFolder: {
                    #if os(macOS)
                    library.requestOpenCloudFolder()
                    #else
                    library.requestOpenFolder()
                    #endif
                },
                // Through the shell's close, which lets go of the selection
                // and the tabs in it first (tabs.md §2.5, item 15).
                onRemoveCollection: { actions.closeCollection($0) }
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

    /// Show what a menu command asked for with no window to ask
    /// (`WindowRequest`).
    private func takeWindowRequest() {
        switch WindowRequest.shared.take() {
        case .about: presentSplash(autoDismiss: false)
        case .acknowledgements: showAcknowledgements = true
        case nil: break
        }
    }

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
            openDefaultCollection: closingOpenQuickly { openDefaultCollection() },
            canOpenQuickly: !(scope?.notes.isEmpty ?? true),
            openQuickly: { showOpenQuickly = true },
            canGraph: !(scope?.notes.isEmpty ?? true),
            graphView: closingOpenQuickly { showPanel(.graph) },
            // Asking the library needs notes to ask *about*, not a collection
            // to stand in.
            canAsk: !library.allNotes.isEmpty,
            askLibrary: closingOpenQuickly { showPanel(.askLibrary) },
            assistant: closingOpenQuickly { showPanel(.assistant) },
            canCloseTab: tabs.openNotes.count > 1 && activeEditor != nil,
            closeTab: closingOpenQuickly { if let id = selectedNoteID { closeTab(id) } },
            // Format and Note commands target the note *behind* the palette
            // (Rename would even stack an alert on the sheet), so they grey
            // out while it's presented instead of dismissing it.
            // Addressed to the active *editor*: by the note's path, a second
            // window on the same note — its own editor — bolded along with it.
            format: showOpenQuickly ? nil : activeEditor.flatMap { editor in
                editor.note.map { _ in
                    { (action: FormatAction) in
                        NotificationCenter.default.post(
                            name: EditorBus.format(action.kind, editor: editor.editorID),
                            object: nil, userInfo: action.userInfo)
                    }
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
            // Every command that changes what is behind the palette, or puts
            // a sheet over it, closes it first — they neither greyed out nor
            // dismissed it, so their sheets opened on top of it (menu.md §8,
            // item 4; implemented.md §51.36).
            rescan: scope.map { collection in closingOpenQuickly { collection.rescan() } },
            showsNonNoteFiles: scope?.showsNonNoteFiles,
            setShowsNonNoteFiles: scope.map { collection in
                { shows in closingOpenQuickly { collection.showsNonNoteFiles = shows }() }
            },
            addCollection: addCollectionActions.closing(closingOpenQuickly),
            acknowledgements: closingOpenQuickly { showAcknowledgements = true },
            about: closingOpenQuickly { presentSplash(autoDismiss: false) },
            openSettings: closingOpenQuickly { showSettings = true },
            refreshCloudCollection: scope.flatMap { collection in
                collection.isRemote ? closingOpenQuickly { Task { await collection.refreshFromProvider() } } : nil
            },
            // Quick Capture writes into today's daily note, so it needs a
            // collection to write into.
            quickCapture: library.isEmpty ? nil : closingOpenQuickly { showQuickCapture = true },
            templates: Templates.available(in: scope, folder: templatesFolder),
            // Into the note behind the palette, which it inserted into unseen:
            // greyed out while the palette is up, as Format and Note are.
            insertTemplate: showOpenQuickly || activeEditor == nil ? nil : { actions.insertTemplate($0) },
            commandPalette: closingOpenQuickly { showPalette = true },
            ai: aiActions,
            reviewLinks: (!showOpenQuickly && activeEditor?.note != nil && editorCollection != nil)
                ? { beginLinkReview() } : nil,
            // Needs a collection to put the note in, but no note open and no
            // particular provider: the sheet itself says which modes can run,
            // which is more useful than a menu item that is simply absent.
            composeNote: scope == nil ? nil : closingOpenQuickly { showCompose = true },
            newWindow: closingOpenQuickly { openWindow(id: "main") },
            // Find targets the note *behind* the palette, so it greys out while
            // that is up rather than toggling a find bar nobody can see.
            // `hnEditorToggleFind` is what `NoteEditorView` listens on, and
            // `NoteEditorView` is the editor column on both platforms — the
            // iPad posted `hnFind(documentId:)` instead, which nothing in the
            // shell receives. Addressed to the active editor: posted to no
            // one, ⌘F here toggled the find bar in every window.
            find: showOpenQuickly ? nil : activeEditor.flatMap { editor in
                editor.note.map { _ in
                    { NotificationCenter.default.post(name: .hnEditorToggleFind(editor: editor.editorID),
                                                      object: nil) }
                }
            },
            searchAllCollections: closingOpenQuickly {
                NotificationCenter.default.post(name: .hnFocusLibrarySearch, object: nil)
            },
            editorMode: EditorMode.mode(storedMode),
            setEditorMode: { mode in closingOpenQuickly { storedMode = mode.rawValue }() }
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
                         settings: intelligenceSettings)
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
        guard !showOpenQuickly, let active = activeEditor, active.note != nil else { return nil }
        let intelligence = IntelligenceService(settings: intelligenceSettings)
        guard intelligence.isAvailable else { return nil }
        return AIActions(
            modelName: intelligence.modelName,
            summarize: { askInspector(.summarize) },
            suggestTags: { askInspector(.suggestTags) },
            suggestLinks: { askInspector(.suggestLinks) },
            // This window's editor: posted to none, every window opened a
            // rewrite sheet over its own note.
            rewriteNote: { NotificationCenter.default.post(name: .hnRewriteNote(editor: active.editorID), object: nil) }
        )
    }

    /// Bring the search field and its results on screen.
    ///
    /// Called by Find Related, which used to set `searchText` and stop — which
    /// at iPad width flipped the tree into a filtered state with no field on
    /// screen to edit or clear, and on a phone left the results on a screen you
    /// were not looking at. The Mac's copy of Find Related did not call this at
    /// all, so a collapsed sidebar there had the same problem.
    private func revealSearch(focusField: Bool) {
        if sidebarHidden {
            withAnimation(.easeInOut(duration: 0.18)) { bandHidden = false }
        }
        place = .search
        // As Back does (see `compactShell`): the note's panel goes with it,
        // or it would come up over the field this is about to focus. Only
        // then — the column shells never expand a note, and search must not
        // close their panel.
        if noteIsExpanded { inspectorPresented = false }
        noteIsExpanded = false
        if focusField { searchFocused = true }
    }

    /// What the editor's selection menu offers over a selection in
    /// `collection`. All three are things Writing Tools structurally cannot
    /// do, because they are about this vault rather than about this sentence.
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
                showPanel(.askLibrary)
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
        // Opening into nothing picks the platform's default mode; opening
        // alongside something already open inherits whatever that is.
        if tabs.editors.isEmpty { storedMode = EditorMode.platformDefault.rawValue }
        if let note = library.allNotes.first(where: { $0.id == newID }) {
            // **An empty note always opens in Edit, on every platform.**
            //
            // iOS defaults to Preview because a note reached by tapping is
            // usually one you meant to read. A note you just made is the
            // opposite case and the reasoning inverts: there is nothing to
            // preview, no keyboard, and the first thing anyone does is type. On
            // iPad this shipped as a new note opening to a blank Preview pane —
            // and because the mode is then *inherited*, every subsequent new
            // note stayed wrong too.
            //
            // Keyed on emptiness rather than on a "was just created" flag
            // because `createNote` writes `Data()` — every one of the fifteen
            // creation paths (menu, folder's New Note Here, quick capture,
            // wiki-link miss, composer, App Intent, …) produces a 0-byte file,
            // so one rule covers all of them and cannot be forgotten by the
            // sixteenth. An existing empty note opening in Edit is right for
            // the same reason.
            if note.fileSize == 0 { storedMode = EditorMode.edit.rawValue }
            library.focusCollection(containing: note.fileURL)
            Task { await tabs.editor(for: note) }
            return
        }
        // **An attachment is the viewer's, never an editor's.** A PDF or a
        // picture is not in the note list either, and fell through to here: it
        // was made a `Note`, so an editor tab opened for it, titled without its
        // extension, and Note Actions offered Rename and Duplicate for it while
        // the viewer drew the file (tabs.md §2.5, item 5; implemented.md
        // §51.36). The detail column shows the viewer for it (`selectedFile`).
        guard Collection.isMarkdown(newID, contentType: nil) else {
            library.focusCollection(containing: newID)
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
            // Putting the note away puts its panel away with it, in the same
            // transaction. The panel over an expanded note sits below the
            // note's own bar, so Back is in reach while it is up — and the
            // places carry the panel too (below), so one left showing would
            // follow you back to the list.
            noteIsExpanded: Binding(
                get: { noteIsExpanded },
                set: { expanded in
                    if !expanded { inspectorPresented = false }
                    noteIsExpanded = expanded
                }),
            places: { place in
                // Each place draws its own bar (`CompactPlaceBar`) — there is
                // no `NavigationStack` here, whose bar is the platform's.
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
            },
            editor: { detail(showsShellCommands: false) }
        )
        // The panel over the places, when no note is up to carry it. The
        // expanded note carries its own (the detail's overlay); with the note
        // put away nothing drew the panel at all, so Graph View, Ask Your
        // Library and the Assistant — from the Library place or the AI place
        // — set it showing and showed nothing, and it came up over the next
        // note opened instead. `noteIsExpanded` only picks which of the two
        // draws it; it is not a second condition on whether it shows.
        .sidePanelOverlay(presented: Binding(
            get: { inspectorPresented && !noteIsExpanded },
            set: { inspectorPresented = $0 })) { trailingPanel }
    }

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
    private func searchField(maxWidth: CGFloat = Chrome.Metric.searchWidth,
                             prompt: String = "Search") -> some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(Chrome.Typeface.rowIcon)
                .foregroundStyle(Chrome.Colour.secondaryLabel)
                .accessibilityHidden(true)
            // The prompt is drawn by the app: a system placeholder is a
            // different grey on each platform.
            TextField("", text: $searchText)
                .textFieldStyle(.plain)
                .foregroundStyle(Chrome.Colour.label)
                .focusEffectDisabled()
                .focused($searchFocused)
                .onSubmit { searchFocused = false }
                .chromePlaceholder(prompt, showing: searchText.isEmpty)
                .accessibilityLabel("Search all collections")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Chrome.Typeface.rowIcon)
                        .foregroundStyle(Chrome.Colour.tertiaryLabel)
                }
                .buttonStyle(ChromePlainStyle())
                .accessibilityLabel("Clear search")
            }
        }
        .font(Chrome.Typeface.body)
        .padding(.horizontal, 8)
        // A range, so a narrow bar squeezes the field before it squeezes any
        // button; drawn at the same height as every other control in the bar.
        .frame(minWidth: 120, maxWidth: maxWidth)
        .frame(height: Chrome.Metric.control)
        .background(Chrome.Colour.fill, in: RoundedRectangle(cornerRadius: Chrome.Metric.radius))
    }

    /// The sidebar: Recents and Bookmarks pinned above every open collection,
    /// each expanding into its own folder tree (`docs/shell-chrome.md` D2/D4).
    ///
    /// One construction, drawn by `NoteOutlineList` — one drawn list on both
    /// platforms. What is *in* the tree is `SidebarTree.roots` and what a row
    /// *says* is `NoteRowContent`.
    private var collectionTree: some View {
        VStack(spacing: 0) {
            // A search over a half-built index comes back short. A false
            // negative is the most damaging thing a knowledge tool can produce,
            // because you cannot notice the note that did not come back — see
            // `CollectionStatusStrips`.
            SearchCompletenessNotice(collections: library.collections,
                                     isSearching: isSearching)
            // **Two panes in a band, one tree in a column.** Both are
            // `SidebarTree.roots`; the band splits it because it is 834pt wide
            // and 320pt tall, where a single list runs out of height in eight
            // rows and spends its width on nothing. See `BandTwoPane`.
            SidebarLayout {
                outlineList
            } band: {
                BandTwoPane(
                    roots: sidebarTree.roots,
                    containerID: $bandContainerID,
                    selection: $selectedNoteID,
                    expandedFolders: expandedFolders,
                    collapsedCollections: $collapsedCollections,
                    focusedCollectionID: library.focusedID,
                    accent: appearance.resolvedAccent,
                    actions: actions.sidebarMenu,
                    onCloseCollection: { actions.closeCollection($0) },
                    row: { note, snippet in
                        // Always the wide layout: the band's right pane is
                        // never narrow, which is the whole reason for splitting
                        // it.
                        AnyView(noteRow(note, snippet: snippet, wide: true))
                    },
                    onDropIntoFolder: { id, urls in actions.move(urls, intoFolderWithID: id) })
                    .onAppear { bandIsShowing = true }
                    .onDisappear { bandIsShowing = false }
            }
        }
        .overlay { SidebarEmptyState(
            library: library, search: search, searchText: searchText,
            selectedTag: selectedTag, scope: railCollection ?? focused,
            hasRecents: !(recents.entries.isEmpty && libraries.libraries.isEmpty),
            openCollection: { library.requestOpenFolder() },
            openRecent: { showLauncher = true },
            newNote: { actions.createNote(in: railCollection ?? focused, folderID: nil) }) }
        // The sidebar's own header row, at the bar's height, so the columns
        // share one top edge. It was a navigation bar — a title and a toolbar
        // item the OS drew at each platform's own size — and the band's large
        // "Collections" title spent 52pt saying what the list already shows.
        // The `+` is the contract's one exception to "no command in the
        // sidebar": everything in it adds a source of notes to this list.
        .safeAreaInset(edge: .top, spacing: 0) { sidebarHeader }
        .background(Chrome.Colour.chrome)
    }

    /// The top of the sidebar: empty at the leading end — where the Mac's
    /// window buttons sit — and the Add Collection menu at the trailing end.
    private var sidebarHeader: some View {
        HStack(spacing: Chrome.Metric.barSpacing) {
            Spacer(minLength: 0)
            ChromeMenuButton(title: "Add Collection", systemImage: "plus",
                             accent: appearance.resolvedAccent) {
                addCollectionItems
            }
        }
        .padding(.horizontal, Chrome.Metric.barPadding)
        .frame(height: Chrome.Metric.barHeight)
        .background(Chrome.Colour.chrome.windowDraggable())
        .overlay(alignment: .bottom) {
            Rectangle().fill(Chrome.Colour.separator).frame(height: 1)
        }
    }

    /// Every way to add a collection, rendered as menu items.
    ///
    /// The *set* lives in `AddCollectionActions.options`, not here: four menus
    /// draw it (the sidebar's `+`, the File menu — which iPadOS builds into a
    /// real menu bar too — the compact shell's `…` and the command palette)
    /// and two onboarding surfaces draw the same set as cards. Describing it
    /// once and rendering it several ways is what keeps them from drifting,
    /// which they had: the welcome screen offered two ways in while the
    /// toolbar offered eight.
    @ViewBuilder
    private var addCollectionItems: some View {
        ForEach(AddCollectionGroup.allCases, id: \.self) { group in
            Menu {
                ForEach(addCollectionActions.options(in: group)) { option in
                    Button {
                        option.run()
                    } label: {
                        Label("\(option.menuTitle)…", systemImage: option.symbol)
                    }
                }
            } label: {
                Label(group.title, systemImage: group.symbol)
            }
        }
        Divider()
        Button {
            showLauncher = true
        } label: {
            Label("Open Recent…", systemImage: "clock.arrow.circlepath")
        }
        // Also `File ▸ Open Default Collection`, which iPadOS builds from
        // `.commands` — but a menu bar needs a hardware keyboard to reach, so
        // on a bare iPad that route does not exist. This is the touch one, and
        // `addCollectionItems` is used by all three menus (sidebar +, compact
        // overflow, New Note) so adding it here adds it everywhere at once.
        Button {
            openDefaultCollection()
        } label: {
            Label("Open Default Collection", systemImage: "books.vertical")
        }
    }

    /// The one definition of what "add a collection" can mean.
    var addCollectionActions: AddCollectionActions {
        AddCollectionActions(
            openFolder: { library.requestOpenFolder() },
            openObsidianVault: { library.requestOpenObsidianVault() },
            openiCloudDrive: { library.requestOpeniCloudDrive() },
            // On iOS the Files browser lists every enabled File Provider in
            // its own sidebar, so there is no separate place to point a picker
            // at — this is deliberately the same picker as "Open Folder", and
            // the item stays for menu parity across platforms.
            openCloudFolder: { showCloudPicker = true },
            newCollection: { library.requestNewCollection() },
            cloneRepository: { showClone = true },
            newRepository: { showNewRepo = true }
        )
    }



    /// "What is this, and what touches it?" — outline, tags, references,
    /// properties and history, in one place instead of four (decisions 1, 8, 10).
    @ViewBuilder
    private var inspector: some View {
        if let collection = editorCollection {
            // The model's calls only when there is a model to answer them —
            // as the Note menu asks (`aiActions`). Always handed over, the
            // summary section and both Suggest buttons were drawn with no
            // model, and pressing one showed an error; `nil` hides them
            // (secondary.md §9, item 3; implemented.md §51.36).
            let hasModel = IntelligenceService(settings: intelligenceSettings).isAvailable
            NoteInspector(
                // The editor, not its text: reading the text here made the
                // whole shell redraw on every keystroke in Markdown and Split.
                editor: activeEditor,
                // The ordinal the outline already drew — no parse here, and
                // nothing that can go stale between the draw and the tap.
                onSelectHeading: { ordinal, heading in
                    guard let editor = activeEditor else { return }
                    hnJumpToHeading(ordinal: ordinal, title: heading.title, editor: editor.editorID)
                },
                summarize: !hasModel ? nil : { text in
                    try await IntelligenceService(settings: intelligenceSettings).summarize(text)
                },
                onInsertSummary: { saveSummary($0) },
                allTags: collection.search.allTags(),
                noteCount: { collection.search.noteCountTagged($0) },
                selectedTag: Binding(
                    get: { selectedTag },
                    // Selecting a tag in the right rail filters the list in the
                    // left one — and a filter and a search would fight, so the
                    // search field yields.
                    set: { selectedTag = $0; if $0 != nil { searchText = "" } }
                ),
                suggestTags: !hasModel ? nil : { text, existing in
                    try await IntelligenceService(settings: intelligenceSettings)
                        .suggestTags(for: text, existing: existing)
                },
                onInsertTag: { insertTag($0) },
                backlinks: references.backlinks,
                outgoingLinks: references.outgoingLinks,
                unlinkedMentions: references.unlinkedMentions,
                onOpenNote: { selectedNoteID = $0.id },
                onLinkMention: linkMention,
                linkCandidates: collection.search.linkTargets(),
                suggestLinks: !hasModel ? nil : { text, _ in
                    // Candidates come from the retrieval index, not from the
                    // full title list. Handing a model 2,000 titles does not fit
                    // any context window, and the ones that *did* fit were
                    // whichever happened to sort first — so the feature quietly
                    // got worse as a vault grew, which is the opposite of what
                    // a link suggester is for.
                    try await suggestLinks(for: text, in: collection)
                },
                onInsertLink: { insertLink($0) },
                onPropertiesChanged: { properties, note in
                    // Into the note the rows were taken from, which a tab
                    // switch may have left — and written, by that editor's
                    // own save (`setProperties`).
                    tabs.editors.first { $0.editorID == note.editor }?.setProperties(properties)
                },
                fileURL: selectedNote?.fileURL,
                git: collection.git,
                onRestoreRevision: { restored in activeEditor?.applyEdit { _ in restored } },
                tab: panel,
                request: inspectorRequest,
                // Cleared once run, or the note's views would run it again
                // each time one of them appeared (`NoteInspector.run`).
                onRequestHandled: { handled in
                    if inspectorRequest == handled { inspectorRequest = nil }
                }
            )
        } else {
            ChromeEmptyState("No Collection", systemImage: "sidebar.right",
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
        return try await IntelligenceService(settings: intelligenceSettings)
            .suggestLinks(for: text, candidates: neighbours.map(\.title))
    }

    /// Write a suggested tag into the open note. See `NoteEdits`.
    private func insertTag(_ tag: String) {
        activeEditor?.applyEdit { NoteEdits.addingTag(tag, to: $0) }
    }

    /// Write an accepted link suggestion into the open note. See `NoteEdits`.
    private func insertLink(_ title: String) {
        activeEditor?.applyEdit { NoteEdits.addingRelatedLink(title, to: $0) }
    }

    /// Record a summary in the note's `summary:` property. See `NoteEdits`.
    private func saveSummary(_ text: String) {
        activeEditor?.applyEdit { NoteEdits.settingSummary(text, in: $0) }
    }

    // MARK: - Git section (the rail's collection)

    /// Git acts on the collection the rail is standing in; on the Library place
    /// it falls back to the focused one, so the button is never a dead end.
    private var gitCollection: Collection? { railCollection ?? focused }

    // MARK: - Column 3: Editor (with tabs)




    /// Bottom status bar shown when a collection is open but no note is selected.
    private var noNoteStatusBar: some View {
        HStack(spacing: 8) {
            if let focused {
                Label(focused.name, systemImage: "folder").foregroundStyle(Chrome.Colour.secondaryLabel)
                ChromeStatusSeparator()
                Text("\(focused.notes.count) note\(focused.notes.count == 1 ? "" : "s")")
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                let tagCount = focused.search.allTags().count
                if tagCount > 0 {
                    ChromeStatusSeparator()
                    Text("\(tagCount) tag\(tagCount == 1 ? "" : "s")").foregroundStyle(Chrome.Colour.secondaryLabel)
                }
                // Where this collection actually lives. It used to be on the
                // sidebar's collection card, which the rail replaced — and a
                // vault in Dropbox behaves differently enough (online-only
                // files, Git guarded) that it must be visible somewhere.
                if let remote = focused.remote {
                    ChromeStatusSeparator()
                    Label("\(remote.store.providerName) (direct)", systemImage: "network")
                        .foregroundStyle(Chrome.Colour.secondaryLabel)
                        .help("A direct \(remote.store.providerName) collection over the provider's API. Note contents download as you open them, and edits sync back automatically.")
                    // A cache goes stale by definition, so asking is a command
                    // the user must be able to reach.
                    Button("Refresh") { Task { await focused.refreshFromProvider() } }
                        .buttonStyle(ChromePlainStyle())
                        .foregroundStyle(appearance.resolvedAccent)
                        .help("Ask \(remote.store.providerName) what has changed since the last check.")
                } else if let provider = CloudProvider.name(for: focused.rootURL) {
                    ChromeStatusSeparator()
                    Label(provider, systemImage: CloudProvider.symbol)
                        .foregroundStyle(Chrome.Colour.secondaryLabel)
                        .help("This collection is stored in \(provider). Online-only notes download on demand.")
                }
                let onlineOnly = focused.notes.lazy.filter(\.isOnlineOnly).count
                if onlineOnly > 0 {
                    ChromeStatusSeparator()
                    Label("\(onlineOnly) online-only", systemImage: "icloud.and.arrow.down")
                        .foregroundStyle(Chrome.Colour.secondaryLabel)
                        .help("\(onlineOnly) note\(onlineOnly == 1 ? " is" : "s are") in the cloud but not downloaded. They appear in the list but aren't indexed until opened or downloaded.")
                }

                // A scan long enough to be worth mentioning. Nothing appears for
                // an ordinary vault, which finishes in well under the threshold.
                if focused.showsScanProgress, let scan = focused.scanProgress {
                    ChromeStatusSeparator()
                    if let fraction = scan.fraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(ChromeProgressStyle(kind: .linear))
                            .frame(width: 56)
                    } else {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    }
                    Text("Scanning \(scan.itemsSeen) item\(scan.itemsSeen == 1 ? "" : "s")…")
                        .foregroundStyle(Chrome.Colour.secondaryLabel)
                        .monospacedDigit()
                    Button("Stop") { focused.cancelScan() }
                        .buttonStyle(ChromePlainStyle())
                        .foregroundStyle(appearance.resolvedAccent)
                        .help("Stop scanning. What's been found is kept, and scanning resumes from here next time.")
                }

                // Say when the folder can't be read, and offer the two things
                // that make sense: look again, or let it go. Removing is the
                // user's call — a drive unplugged for an afternoon is not a
                // reason for the app to forget a collection.
                if case .unavailable(let reason) = focused.state {
                    ChromeStatusSeparator()
                    Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Chrome.Colour.orange)
                        .help("\(reason.explanation) The notes listed are the last ones seen; edits are held until it's back.")
                    Button("Try Again") { Task { await library.retry(focused) } }
                        .buttonStyle(ChromePlainStyle())
                        .foregroundStyle(appearance.resolvedAccent)
                    Button("Locate…") { library.requestRelocate(focused) }
                        .buttonStyle(ChromePlainStyle())
                        .foregroundStyle(appearance.resolvedAccent)
                    Button("Remove") { actions.closeCollection(focused) }
                        .buttonStyle(ChromePlainStyle())
                        .foregroundStyle(appearance.resolvedAccent)
                } else if !focused.showsNonNoteFiles, focused.hiddenFileCount > 0 {
                    ChromeStatusSeparator()
                    Label("\(focused.hiddenFileCount) file\(focused.hiddenFileCount == 1 ? "" : "s") hidden",
                          systemImage: "eye.slash")
                        .foregroundStyle(Chrome.Colour.secondaryLabel)
                        .help("Non-note files (PDFs, images, documents) aren't listed in this collection. Turn them back on in View ▸ Show Non-Note Files.")
                } else if let reason = focused.staleReason {
                    ChromeStatusSeparator()
                    Label(reason.summary, systemImage: reason.symbol)
                        .foregroundStyle(reason.isPermanent ? Chrome.Colour.orange : Chrome.Colour.secondaryLabel)
                        .help(reason.explanation)
                }
            }

            Spacer(minLength: 12)

            gitStatusButton
            statusBarButton("New note", "square.and.pencil") { newNote() }
            statusBarButton("Today's note", "calendar") { openTodaysNote() }
            statusBarButton("Graph view", "point.3.connected.trianglepath.dotted") { showPanel(.graph) }
                .disabled(focused?.notes.isEmpty ?? true)
                // The tip used to hang off the sidebar's Graph button; the
                // status bar is where that command still lives on screen.
                .popoverTip(GraphTip())
            statusBarButton("Ask your library", "sparkles.rectangle.stack") { showPanel(.askLibrary) }
                .disabled(library.allNotes.isEmpty)
            statusBarButton("Assistant", "sparkles") { showPanel(.assistant) }
        }
        // The same strip as the editor's bottom bar, from the same tokens:
        // it was `.callout` over `.bar`, both resolved per OS.
        .font(Chrome.Typeface.status)
        .foregroundStyle(Chrome.Colour.secondaryLabel)
        .padding(.horizontal, 10)
        .frame(height: Chrome.Metric.statusRow)
        .padding(.vertical, 5)
        .background(Chrome.Colour.chrome)
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
                        Circle().fill(Chrome.Colour.orange).frame(width: 6, height: 6)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(ChromePlainStyle())
            .foregroundStyle(Chrome.Colour.secondaryLabel)
            .help("Git — branch, status, commit and sync for “\(collection.name)”")
            .popover(isPresented: $showGitPanel, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    GitPane(collection: gitCollection) { showGitSettings = true }
                }
                    .padding(12)
                    .frame(width: 300)
                    // See `NoteEditorView.bottomBar`: without this a compact
                    // width turns the popover into a sheet and centres a
                    // 300pt panel in it.
                    .presentationCompactAdaptation(.popover)
            }
            ChromeStatusSeparator()
        }
    }

    private func statusBarButton(_ help: String, _ systemImage: String, action: @escaping () -> Void) -> some View {
        ChromeStatusButton(help: help, systemImage: systemImage, action: action)
    }

    private func closeTab(_ id: Note.ID) {
        Task {
            let next = await tabs.close(id)
            // A tab holding what it could not save stays open, its banner
            // saying why (`EditorTabs.close`) — and keeps its document.
            guard tabs.editor(withID: id) == nil else { return }
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
            // The empty space below the rows names a collection only when the
            // whole outline is one collection's — a tag filter's rows, or the
            // one collection open. With several, it was the scope collection,
            // which the click does not name, and New Note there landed in it
            // (primary.md §12, item 7; implemented.md §51.36).
            scopedCollection: selectedTag != nil || library.collections.count == 1
                ? railCollection ?? focused : nil,
            onCloseCollection: { actions.closeCollection($0) },
            row: { note, snippet in
                AnyView(noteRow(note, snippet: snippet,
                                wide: outlineWidth >= ShellMetrics.noteRowTwoColumn))
            },
            onDropIntoFolder: { id, urls in actions.move(urls, intoFolderWithID: id) }
        )
        // **Measured once for the list, not once per row.** `ViewThatFits`
        // would decide per row, so two neighbours could disagree and the column
        // would come and go down the list; it also re-measures on every content
        // change, which is the shape of the bar that re-measured per keystroke.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { outlineWidth = $0 }
    }

    // MARK: - Actions

    /// Open (and if necessary restore) the collection that ships with the app.
    ///
    /// Seeding is idempotent and never overwrites, so this is safe to invoke
    /// with the collection already open, already edited, or partially deleted.
    private func openDefaultCollection() {
        guard let url = DefaultCollection.seedIfNeeded() else { return }
        Task {
            let collection = await library.open(url: url)
            library.focusCollection(containing: collection.rootURL)
        }
    }

    /// New Note, **into the folder you are looking at**.
    ///
    /// This created at the collection root whatever was selected. On the tall
    /// shell that is wrong in a way that reads as "nothing happened": the
    /// band's left pane *is* a folder picker and its right pane lists that
    /// folder, so a note created at the root lands outside the only list on
    /// screen. You then name it — renaming a file you cannot see — and look for
    /// it where you made it, and it is not there.
    ///
    /// `bandContainerID` is the container that pane is showing, and it is the
    /// same identifier the folder row's own **New Note Here** passes; the
    /// column shells set none, so `nil` keeps their behaviour. The folder is
    /// expanded first for the reason `ShellActions.expand` gives — a note
    /// created into a closed folder is a selection you cannot see.
    private func newNote() {
        let folderID = ShellActions.newNoteFolder(band: bandContainerID, bandShowing: bandIsShowing,
                                                  collectionIDs: library.collections.map(\.id))
        if let folderID { actions.expand(folderID) }
        actions.createNote(in: railCollection ?? focused, folderID: folderID)
    }

    /// Settings, at its AI page — the only AI settings screen there is.
    private func openAISettings() {
        #if os(macOS)
        UserDefaults.standard.set(SettingsPage.ai.rawValue, forKey: SettingsPage.storageKey)
        openSettings()
        #else
        settingsPage = .ai
        showSettings = true
        #endif
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
    /// The note identities last seen, so a save — which changes a `Note`'s
    /// `lastModified` and therefore `allNotes` — is not mistaken for the note
    /// set changing.
    @State private var knownNoteIDs: Set<URL> = []

    @State private var noEditor = EditorModel()

    private var editor: EditorModel { actions.activeEditor ?? noEditor }

    @State private var showSettings = false
    /// The page the Settings sheet opens at — `nil` is the top. See `openAISettings`.
    @State private var settingsPage: SettingsPage?
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #else
    // iOS has no Settings window to open: `openAISettings` presents the
    // Settings sheet at its AI page instead.
    #endif

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
    /// the main actor — and `mermaidBlocks` is a whole-document parse with no
    /// early exit. Computed once here instead, off-main, against
    /// `docFeaturesKey`, which is the Mac's memoized `DocStats` with a cheaper
    /// key (see the `.task` for why the text itself is the wrong one here).
    @State private var docFeatures = NoteDocFeatures()

    /// The splash overlay — at launch it fades after a beat, from About it
    /// waits for a tap. Raised by `presentSplash(autoDismiss:)`.
    @State private var showSplash = false

    /// The launch splash fades itself; the one About raises waits to be tapped.
    @State private var splashAutoDismisses = true
    /// The whole-note rewrite sheet, raised from the editor's toolbar menu.

    /// Ask Library, and the question it should open with (`nil` = ask fresh).

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
    /// menu with "View Diagram" and "Present as Slides" both missing, and
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
    ///
    /// `wide` is the list's width, not the device's: over
    /// `ShellMetrics.noteRowTwoColumn` the date moves up beside the title and
    /// the row becomes one line, which is most of a row's height back. Under
    /// it — a 280pt sidebar column — the two cannot share a line without the
    /// title truncating, so the layout stays stacked.
    @ViewBuilder
    private func noteRow(_ note: Note, snippet: String? = nil, wide: Bool = false) -> some View {
        // `ChromeNoteRow`: the Mac outline's 13pt semibold title over 11pt, on
        // both platforms. It was `.subheadline` and `.caption` — 11/10pt on the
        // Mac and 15/12pt on iOS under the same names.
        ChromeNoteRow(content: NoteRowContent.make(note, snippet: snippet), wide: wide)
            .contentShape(.rect)
            .tag(note.id)
            // The tree is the only place a note has a *location*, so it is the
            // only place a move makes sense.
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

    private var collectionsList: some View {
        VStack(spacing: 0) {
            CompactPlaceBar("Library") {
                ChromeMenuButton(title: "More", systemImage: "ellipsis.circle",
                                 accent: appearance.resolvedAccent, spokenName: "More actions") {
                    if !library.isEmpty {
                        Button {
                            guard let c = focused else { return }
                            Task { if let note = await c.createNote() { selectedNoteID = note.id } }
                        } label: {
                            Label("New Note", systemImage: "square.and.pencil")
                        }
                    }
                    // The compact shell has no sidebar, so no `+`. On a narrow
                    // Mac window or a narrowed iPad the menu bar is still
                    // there behind it; on **iPhone** there is no menu bar at
                    // all, and this menu is the only route to adding a source.
                    // The same items, from the same place, so it cannot fall
                    // behind the other three.
                    addCollectionItems
                    Divider()
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings…", systemImage: "gearshape")
                    }
                }
            }
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if library.isEmpty {
                        Button("Open Folder…") { library.requestOpenFolder() }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    } else {
                        compactHeader("Collections")
                        ForEach(library.collections) { collection in
                            collectionRow(collection)
                        }
                        compactHeader(nil)
                        filterRow(title: "All Notes", systemImage: "tray.full", isSelected: selectedTag == nil) {
                            selectedTag = nil
                        }
                        // Tags are not here. The library rail answers "where is it?";
                        // tags are cross-cutting and belong to the inspector, or to
                        // their own place in the compact tab bar (decision 1).
                    }
                }
                .padding(.bottom, 8)
            }
            .viewport()
            .background(Chrome.Colour.chrome)
        }
    }

    /// A group's heading in a compact place — or, untitled, the gap between
    /// groups. The list's section headers, drawn.
    @ViewBuilder
    private func compactHeader(_ title: String?) -> some View {
        if let title {
            ChromeLine(title, size: 11, weight: .semibold, colour: Chrome.Colour.secondaryLabel)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)
        } else {
            Color.clear.frame(height: 12)
        }
    }

    /// A collection row: tap to focus it (and show its notes); `…` and a
    /// right-click or long-press for its commands, Close among them. It had a
    /// swipe to close as well, which a `List` gives and a drawn list does not —
    /// and the swipe was never the only route, which is the rule it kept.
    private func collectionRow(_ collection: Collection) -> some View {
        let isFocused = collection.id == focused?.id
        let items = SidebarMenu.items(for: NoteOutlineItem(id: collection.id, kind: .collection(collection)),
                                      actions: actions.sidebarMenu)
        // What the sidebar's rows say about a collection, said here too: an
        // unreadable one, one still scanning, and a repository's state. This
        // row drew none of them, so on a phone an unreadable collection looked
        // healthy (primary.md §12, item 12; implemented.md §51.36).
        let content = CollectionRowContent.make(collection, focusedID: focused?.id)
        return ChromeRowFrame(height: Chrome.Metric.rowNote, accent: appearance.resolvedAccent) {
            HStack(spacing: 6) {
                Image(systemName: content.symbol)
                    .font(Chrome.Typeface.rowIcon)
                    .foregroundStyle(content.isDimmed ? Chrome.Colour.orange : Chrome.Colour.secondaryLabel)
                    .frame(width: 16)
                ChromeLine(collection.name, size: 13, weight: isFocused ? .semibold : .regular,
                           colour: content.isDimmed ? Chrome.Colour.tertiaryLabel : Chrome.Colour.label)
                if content.isScanning {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel(content.scanningLabel)
                }
                if let clean = content.gitIsClean {
                    Circle()
                        .fill(clean ? Chrome.Colour.tertiaryLabel : Chrome.Colour.orange)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel(content.gitLabel ?? "")
                }
                Spacer(minLength: 8)
                ChromeLine("\(collection.notes.count)", size: 12, colour: Chrome.Colour.secondaryLabel,
                           monospacedDigits: true)
                if isFocused {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tint)
                }
                RowActionsMenu(name: collection.name, items: items)
            }
        }
        .onTapGesture {
            // Compact has no rail, but it shares the rail's scope: without
            // this the list would keep showing whichever collection the rail
            // was left on at iPad size.
            select(.collection(collection.id))
            library.focus(collection)
        }
        .contextMenu { SidebarMenuItems(items: items) }
        .help(content.help ?? "")
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isFocused ? [.isSelected] : [])
    }

    private func filterRow(title: String, systemImage: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        ChromeRowFrame(height: Chrome.Metric.rowNote, accent: appearance.resolvedAccent) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(Chrome.Typeface.rowIcon)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                    .frame(width: 16)
                ChromeLine(title, size: 13)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tint)
                }
            }
        }
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { action() }
    }

    // MARK: - Column 2: Note list

    private var noteList: some View {
        VStack(spacing: 0) {
            CompactPlaceBar(noteListTitle) {
                if !library.isEmpty {
                    ChromeButton(title: "New Note", systemImage: "square.and.pencil",
                                 accent: appearance.resolvedAccent) {
                        guard let c = railCollection ?? focused else { return }
                        Task { if let note = await c.createNote() { selectedNoteID = note.id } }
                    }
                    .disabled(focused == nil)
                }
            }
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
                // The compact shell's own field — the bar's, full width. Only
                // one of the two is ever in the hierarchy (`AdaptiveShell`
                // renders compact or the column/tall shell, never both, and
                // the expanded note's bar leaves search to this place), so
                // ⌥⌘F reaches whichever field exists.
                searchField(maxWidth: .infinity, prompt: "Search \(railCollection?.name ?? "notes")")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        // **The shared row, not a third one.** This built its
                        // own — title, badge, and `.dateTime.year().month()…`
                        // — so the compact shell was the one place that never
                        // got the compact date or the two-column layout, and
                        // iPhone showed "3 Sep 2026 at 12:00 pm" where every
                        // other surface showed "12:00 pm". `NoteRowContent`'s
                        // own note says a row that gains a field gains it on
                        // both platforms or neither; this list was quietly the
                        // exception.
                        ForEach(displayedNotes) { note in
                            compactNoteRow(note)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .viewport()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { compactListWidth = $0 }
                .overlay {
                    if displayedNotes.isEmpty {
                        ChromeEmptyState("No Notes", systemImage: "doc.text")
                    }
                }
            }
        }
        // A list place, like the others and the sidebar: the chrome colour.
        .background(Chrome.Colour.chrome)
    }

    /// A note in the compact list: the shared row, selected in the accent at
    /// 30%, with the tree's menu on a right-click or long-press. That menu has
    /// Download for a note that is online only, which a leading swipe used to
    /// offer here as well — a swipe is a `List`'s, and was never the only route.
    private func compactNoteRow(_ note: Note) -> some View {
        let item = NoteOutlineItem(id: note.fileURL.path, kind: .note(note, snippet: nil))
        return ChromeRowFrame(height: Chrome.Metric.rowNote, isSelected: selectedNoteID == note.id,
                              accent: appearance.resolvedAccent) {
            noteRow(note, wide: compactRowIsWide)
        }
        .onTapGesture { selectedNoteID = note.id }
        .contextMenu { SidebarMenuItems(items: SidebarMenu.items(for: item, actions: actions.sidebarMenu)) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selectedNoteID == note.id ? [.isButton, .isSelected] : .isButton)
    }

    private var noteListTitle: String {
        if let selectedTag { return "#\(selectedTag)" }
        return railCollection?.name ?? "Library"
    }

    /// Hide or show the tall shell's navigation band.
    ///
    /// A child view, not an `if` out here: `@Environment` resolves at the
    /// position of the view that *declares* it, and `ContentView` sits above
    /// `AdaptiveShell` — so a `shell.kind` read here is always the default
    /// `.wide` and the branch would never be taken. `BandTwoPane` documents the
    /// same trap; this is the toolbar's copy of it.

    /// Library-wide commands, shown in the Library place: the compact shell's
    /// stand-in for the bar's More menu, which the phone does not draw (see
    /// `detail(showsShellCommands:)`). A command in neither has no route on a
    /// phone at all, and Graph View was one. The list began as the iPad's
    /// short one, when Graph, Ask Library and the Assistant were Mac windows;
    /// the two AI entries were added because iOS had no way to them at all,
    /// and the graph, which had an iPad sheet of its own then, was not.
    private var libraryActions: [LibraryPlace.Action] {
        let scope = railCollection ?? focused
        return [
            .init(title: "New Note", symbol: "square.and.pencil", isEnabled: scope != nil) {
                guard let scope else { return }
                Task { if let note = await scope.createNote() { selectedNoteID = note.id } }
            },
            .init(title: "New Note from a Prompt…", symbol: "sparkles.square.filled.on.square",
                  isEnabled: scope != nil) { showCompose = true },
            .init(title: "Open Folder", symbol: "folder.badge.plus") { library.requestOpenFolder() },
            // The launcher, by touch. `openLauncher` reaches it from a hardware
            // keyboard's ⌘O, which is not a route a keyboard-less iPad has —
            // and recents and saved libraries are the only way back to a vault
            // without navigating the Files picker to it again.
            .init(title: "Open Recent…", symbol: "clock.arrow.circlepath") { showLauncher = true },
            // The Mac reaches this from the menu bar without switching apps.
            // iOS has no such chrome, so the capture lives where the rest of
            // the library-wide commands do.
            .init(title: "Quick Capture…", symbol: "square.and.pencil.circle",
                  isEnabled: !library.isEmpty) { showQuickCapture = true },
            .init(title: "Graph View", symbol: "point.3.connected.trianglepath.dotted",
                  isEnabled: !(scope?.notes.isEmpty ?? true)) {
                showPanel(.graph)
            },
            // Reachable deliberately, not only by selecting a phrase — the
            // question you want to ask your notes usually isn't already in one.
            .init(title: "Ask Your Library", symbol: "sparkles.rectangle.stack",
                  isEnabled: !library.allNotes.isEmpty) {
                showPanel(.askLibrary)
            },
            .init(title: "Assistant", symbol: "sparkles", isEnabled: scope != nil) {
                showPanel(.assistant)
            },
            .init(title: "Settings…", symbol: "gearshape") { showSettings = true },
        ]
    }

    /// Tags as their own place in the compact tab bar — the phone has no
    /// inspector rail to keep them in, and they are still how people navigate
    /// across a vault rather than down it.
    private var tagList: some View {
        VStack(spacing: 0) {
            CompactPlaceBar("Tags")
            if tags.isEmpty {
                ChromeEmptyState("No Tags", systemImage: "number",
                                 description: Text("Tags you write as #tag in a note appear here."))
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
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
                    .padding(.vertical, 4)
                }
                .viewport()
            }
        }
        .background(Chrome.Colour.chrome)
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
        return VStack(spacing: 0) {
            CompactPlaceBar("AI")
            aiPlaceList(scope: scope)
        }
    }

    private func aiPlaceList(scope: Collection?) -> some View {
        AIPlaceList(
            ai: aiActions,
            canAsk: !library.allNotes.isEmpty,
            askLibrary: { showPanel(.askLibrary) },
            reviewLinks: editor.note != nil ? { beginLinkReview() } : nil,
            compose: scope == nil ? nil : { showCompose = true },
            assistant: { showPanel(.assistant) },
            aiSettings: { openAISettings() },
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
            .safeAreaInset(edge: .top, spacing: 0) { shellBar(showsShellCommands: showsShellCommands) }
            .background(Chrome.Colour.content)
    }

    /// The bar over the editor — **the same pixels on both platforms**:
    /// Search · Sidebar · New Note · More ⋯ | tabs | Note Actions ⌄ · Panel.
    ///
    /// It was a system toolbar, and a system toolbar is the platform's drawing:
    /// NSToolbar at the Mac's metrics, UINavigationBar at iPadOS's, and a
    /// different builder on each (`editorToolbar` and `detailToolbar`), so the
    /// two had different buttons as well as different sizes. Everything here
    /// is `Chrome`: fixed sizes, fixed colours, no system button styles.
    ///
    /// Narrow, the tabs give way first — they scroll inside whatever the
    /// buttons leave — so the buttons never move and never fold away.
    private func shellBar(showsShellCommands: Bool) -> some View {
        let accent = appearance.resolvedAccent
        return HStack(spacing: Chrome.Metric.barSpacing) {
            // On the phone the Search place has the field; a second one here,
            // bound to the same focus, would be two fields answering ⌥⌘F.
            if showsShellCommands { searchField() }
            if showsShellCommands {
                ChromeButton(title: sidebarHidden ? "Show Sidebar" : "Hide Sidebar",
                             systemImage: "sidebar.leading", accent: accent) { toggleSidebar() }
                    .accessibilityIdentifier("shell.bandToggle")
                ChromeButton(title: "New Note", systemImage: "square.and.pencil", accent: accent) { newNote() }
                    .disabled((railCollection ?? focused) == nil)
                shellCommandMenu
            }
            Group {
                if editor.note != nil {
                    ViewThatFits(in: .horizontal) {
                        tabStrip.fixedSize()
                        ScrollView(.horizontal, showsIndicators: false) { tabStrip.fixedSize() }
                    }
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(maxWidth: .infinity)
            if editor.note != nil { noteMenu }
            ChromeButton(title: inspectorPresented ? "Hide Panel" : "Show Panel",
                         systemImage: "sidebar.trailing", isOn: inspectorPresented, accent: accent) {
                togglePanel()
            }
        }
        .padding(.horizontal, Chrome.Metric.barPadding)
        // With the sidebar away the bar is the window's top-left corner, where
        // the Mac's traffic lights are.
        .padding(.leading, sidebarHidden ? WindowControls.leadingInset : 0)
        .frame(height: Chrome.Metric.barHeight)
        .background(Chrome.Colour.chrome.windowDraggable())
        .overlay(alignment: .bottom) {
            Rectangle().fill(Chrome.Colour.separator).frame(height: 1)
        }
    }

    /// Whether the left region is put away — the band on the tall shell, the
    /// sidebar column on the column shells. One answer for both.
    private var sidebarHidden: Bool { bandHidden }

    /// Show or hide the left region. `NavigationSplitView` used to supply this
    /// button to the column shells and the band had its own; there is one
    /// toggle now, in the same place, doing the same thing to whichever left
    /// region the shell has.
    private func toggleSidebar() {
        let hide = !sidebarHidden
        withAnimation(.easeInOut(duration: 0.18)) { bandHidden = hide }
    }

    @ViewBuilder
    private var detailBody: some View {
        VStack(spacing: 0) {
        // A collection that went unavailable said nothing here — the note
        // simply stopped saving. Same strip the Mac has always drawn.
        CollectionConditionBar(collection: railCollection ?? focused,
                               hasSelection: selectedNoteID != nil,
                               onRetry: { c in Task { await library.retry(c) } },
                               onLocate: { c in library.requestRelocate(c) })
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
                .ignoresSafeArea(.container, edges: .bottom)
        } else if editor.note != nil, let c = editorCollection {
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
                // One route on both: the Git settings sheet, which the Mac
                // used and the iPad reached only through the whole of Settings.
                onGitSettings: { showGitSettings = true },
                linkCandidates: c.search.linkTargets(),
                tagCandidates: c.search.allTags(),
                headingProvider: { c.search.headings(forName: $0) },
                onOpenWikiLink: { openWikiLink($0) },
                onOpenNote: { selectedNoteID = $0.id },
                onLinkMention: linkMention,
                // **Resolved when the rename happens, not captured now.**
                //
                // `note` here is whatever the body saw when this closure was
                // made, and a rename changes the note's `fileURL` — that *is*
                // the rename. So the captured value went stale the instant the
                // first one succeeded, and every rename after it addressed a
                // path with no file at it. It failed silently, which is why it
                // looked like renaming simply stopped working after once.
                onRenameNote: { title in
                    guard let current = editor.note else { return }
                    actions.rename(current, to: title)
                },
                onShowMindMap: {
                    guard editor.note != nil else { return }
                    showPanel(.mindMap)
                },
                ai: aiActions,
                selectionActions: selectionActions(in: c)
            )
            // S3: the detail column is a viewport, whatever mode it is in.
            // Without the clamp the editor's or preview's ideal height sizes
            // the column, and the split view follows it past the screen.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Not `ContentUnavailableView`, which the OS draws at its own
            // sizes — 20pt on macOS, 22pt on iOS. The Mac's collection strip
            // comes along: it was only on the Mac's copy of this screen.
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Chrome.Colour.tertiaryLabel)
                    Text("Select a Note")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Chrome.Colour.label)
                    Text("Choose a note from the list, or create a new one.")
                        .font(Chrome.Typeface.body)
                        .foregroundStyle(Chrome.Colour.secondaryLabel)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if focused != nil {
                    Rectangle().fill(Chrome.Colour.separator).frame(height: 1)
                    noNoteStatusBar
                }
            }
        }
        }
        // The panel, where the shell has no column for it. Shared — the Mac
        // had no overlay at all, so its own default 1100pt window showed no
        // panel however many times you pressed the toggles. Over the whole
        // detail, not the note alone: it hung off the note's branch, so with
        // no note open a command that showed the panel turned the toggle on
        // and drew nothing. And on the stack, not a branch, so it stays one
        // view when the branch changes — opening a note from the graph does
        // not rebuild the graph under it.
        .sidePanelOverlay(presented: $inspectorPresented) { trailingPanel }
    }



    private var shellCommandMenu: some View {
        let scope = railCollection ?? focused
        return ChromeMenuButton(title: "More", systemImage: "ellipsis.circle",
                                accent: appearance.resolvedAccent, spokenName: "More actions") {
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
            // What the Mac's status bar and the phone's AI place carry. On iPad
            // they were in the menu bar and the palette only — both out of
            // sight — so the Assistant had no button at all.
            Button {
                showPanel(.assistant)
            } label: {
                Label("Assistant", systemImage: "sparkles")
            }
            .disabled(scope == nil)
            Button {
                showPanel(.askLibrary)
            } label: {
                Label("Ask Your Library", systemImage: "sparkles.rectangle.stack")
            }
            .disabled(library.allNotes.isEmpty)
            Button {
                showCompose = true
            } label: {
                Label("New Note from a Prompt…", systemImage: "sparkles.square.filled.on.square")
            }
            .disabled(scope == nil)
            Button {
                showPanel(.graph)
            } label: {
                Label("Graph View", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .disabled(scope?.notes.isEmpty ?? true)
            Divider()
            // One Settings — AI is a page of it. Above the folder and collection
            // commands, not after them: a menu from a toolbar in the middle of
            // a portrait iPad is capped at about 520pt, and last place put
            // Settings below the fold, which is where this menu came in to get
            // it out of. Those commands also have visible homes of their own,
            // the band's `+` and each collection's `…`.
            Button {
                showSettings = true
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            Divider()
            Button {
                actions.beginNewFolder(in: scope, folderID: nil)
            } label: {
                Label("New Folder…", systemImage: "folder.badge.plus")
            }
            .disabled(scope == nil)
            // The same items the sidebar's `+`, the File menu and the compact
            // shell offer, from the same definition.
            //
            // This is **not** the iPad's menu bar: iPadOS 26 builds a real one
            // from the scene's own `.commands`, ungated, so these commands are
            // already there on both platforms (see `HelloNotesApp`). This is
            // the touch-reachable duplicate of it, one caret from the note
            // being edited rather than a swipe to the top of the screen. A
            // duplicate is fine; a duplicate that has drifted is not.
            addCollectionItems
        }
    }

    // MARK: - AI on the open note
    //
    // The toolbar is the *touch*-reachable place a command can live — not the
    // only place, which is what this said. iPadOS 26 builds a real menu bar
    // from the scene's `.commands`, ungated (`HelloNotesApp`), so the iPad has
    // the same menus and shortcuts the Mac does; iPhone is the platform with
    // no menu bar. Same four actions as the Mac, landing in the same inspector
    // tabs — the answer belongs with the thing it is about on both platforms,
    // and only the route to it differs.


    /// Tabs are wired to the library as a note window is (`EditorWiring`): a
    /// save reindexes its collection rather than triggering a rescan, opening
    /// hydrates a cloud note first, and a write into a folder that has gone
    /// away is refused rather than lost.
    private func wireTabs() {
        tabs.wiring = EditorWiring(library: library)
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
            onClose: { closeTab($0) },
            accent: appearance.resolvedAccent)
    }

    /// Everything the top bar used to spread across four controls.
    ///
    /// One caret, because tabs need the width and because every command here is
    /// also in the menu bar now — this is the touch route to the same set, not
    /// a second vocabulary.
    private var noteMenu: some View {
        ChromeMenuButton(title: "Note Actions", systemImage: "chevron.down.circle",
                         accent: appearance.resolvedAccent) {
            Picker("View", selection: modeBinding) {
                ForEach(EditorMode.platformCases) { m in
                    Label(m.label, systemImage: m.symbol).tag(m)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button {
                togglePanel()
            } label: {
                Label(inspectorPresented ? "Hide Panel" : "Show Panel",
                      systemImage: "sidebar.right")
            }
            if editor.note != nil {
                Divider()
                // **The way in to the mind map.** It was bound into a sheet and
                // never once
                // set to `true` anywhere in the codebase — every write was a
                // dismissal — so the whole surface was dead code on iOS. The Mac
                // reaches it from the editor's bottom bar; the bar's iPad
                // equivalent is this menu.
                Button { showPanel(.mindMap) } label: {
                    Label("Mind Map", systemImage: "brain")
                }
                // Read from the memoized, off-main scan rather than computed
                // here: `Menu(content:label:)` takes a *non-escaping*
                // ViewBuilder, so anything in this closure runs at construction
                // time on the main actor whether or not the menu is ever opened.
                if docFeatures.isMarp {
                    Button { NotificationCenter.default.post(name: .hnShowSlides(editor: editor.editorID), object: nil) } label: {
                        Label("Present as Slides", systemImage: "rectangle.on.rectangle")
                    }
                }
                // Only when the note has a diagram, as the bar's button is: a
                // row that opened on nothing would read as a broken command
                // rather than a note without diagrams.
                if docFeatures.hasMermaid {
                    Button { NotificationCenter.default.post(name: .hnShowMermaid(editor: editor.editorID), object: nil) } label: {
                        Label("View Diagram", systemImage: "chart.xyaxis.line")
                    }
                }
            }
            if let ai = aiActions {
                Divider()
                Section("Using \(ai.modelName)") {
                    Button { ai.summarize() } label: { Label("Summarise Note", systemImage: "text.append") }
                    Button { ai.suggestTags() } label: { Label("Suggest Tags", systemImage: "number") }
                    Button { ai.suggestLinks() } label: { Label("Suggest Links", systemImage: "link") }
                    Button { ai.rewriteNote() } label: { Label("Rewrite or Expand…", systemImage: "wand.and.stars") }
                }
            }
            // Everything a long-press on this note's row offers — Rename,
            // Duplicate, Bookmark, Export, Move to Trash and the rest, Review
            // Links among them — from the row's own list. Those were reachable
            // on iPad only by holding the row, or from a menu bar that stays
            // out of sight; the open note is where Mail puts a message's
            // commands too. Last, so Move to Trash ends the menu.
            if let note = editor.note {
                Divider()
                SidebarMenuItems(items: SidebarMenu.items(
                    for: NoteOutlineItem(id: note.fileURL.path, kind: .note(note, snippet: nil)),
                    actions: actions.sidebarMenu))
            }
        }
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
