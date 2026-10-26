//
//  Library.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//

import Foundation

#if os(macOS)
import AppKit
#endif

/// The workspace: several `Collection`s open at once. The library tracks which
/// collection is *focused* (the one the editor, Git panel, and note-level
/// actions operate on) and persists the set of open collections so they reopen
/// on the next launch. Collections themselves stay isolated — the library only
/// aggregates them for library-wide search and reopening.
/// A run launched only to be captured (`scripts/window-parity.sh`, with
/// `-HNCaptureSession YES`): it changes nothing the person keeps — not the
/// open collections, not the recents, and not what the system holds for them:
/// the notes donated to Spotlight and the widget's recent notes, both of which
/// a capture of the sample collection replaced with the sample's until 1.3.3
/// build 31. The launch names its collections in the argument domain, and must
/// name all three lists — `collectionBookmarks`, `collectionPaths` and
/// `remoteCollectionCaches`, the last as `()`: a cloud collection comes back
/// from that one alone.
enum CaptureSession {
    static var isActive: Bool { UserDefaults.standard.bool(forKey: "HNCaptureSession") }
}

@MainActor
@Observable
final class Library {
    /// Where the open collections are remembered between launches — the app's
    /// own preferences, or a test's own store: a hosted test's `Library` that
    /// opened a folder wrote that folder into the person's list of open
    /// collections.
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The collections currently open, in the order they were added.
    private(set) var collections: [Collection] = []

    /// The focused collection's id — drives the editor, Git panel and
    /// note-scoped actions. Defaults to the first collection.
    var focusedID: Collection.ID?

    /// The focused collection (falls back to the first open one).
    var focused: Collection? {
        collections.first { $0.id == focusedID } ?? collections.first
    }

    // Cached flattened notes + id→note index, rebuilt only when a collection's
    // structural `revision` changes. `allNotes` used to re-`flatMap` every open
    // collection on each access (read many times per view body), and callers
    // then linearly scanned it to resolve the selected note.
    @ObservationIgnored private var cachedRevision = -1
    @ObservationIgnored private var cachedAllNotes: [Note] = []
    @ObservationIgnored private var cachedIndex: [Note.ID: Note] = [:]

    /// Sum of collection revisions (+ count) — cheap, changes on any note-set change.
    private var aggregateRevision: Int {
        collections.reduce(collections.count) { $0 &+ $1.revision }
    }

    private func refreshCacheIfNeeded() {
        let rev = aggregateRevision
        guard rev != cachedRevision else { return }
        cachedRevision = rev
        var all: [Note] = []
        var index: [Note.ID: Note] = [:]
        for collection in collections {
            all.append(contentsOf: collection.notes)
            for note in collection.notes { index[note.id] = note }
        }
        cachedAllNotes = all
        cachedIndex = index
    }

    /// Notes across every open collection (for library-wide search / chat).
    var allNotes: [Note] {
        refreshCacheIfNeeded()
        return cachedAllNotes
    }

    /// O(1) lookup of a note by id across all collections.
    func note(id: Note.ID?) -> Note? {
        guard let id else { return nil }
        refreshCacheIfNeeded()
        return cachedIndex[id]
    }

    var isEmpty: Bool { collections.isEmpty }

    /// What each window does when an open collection changes on disk, by the
    /// object it keeps its editors in — a main window's tabs, a note window's
    /// editor (`observeExternalChanges(of:_:)`).
    ///
    /// **One per window.** It was a single closure, `onExternalChange`, which
    /// every main window's `.task` set — so the main window opened last was the
    /// only one told. The tabs of every other main window were never
    /// reconciled: a change made elsewhere was neither loaded into their clean
    /// tabs nor raised as a conflict in dirty ones, until a save of theirs
    /// refused to write over it. And a note window's editor, in no window's
    /// tabs, was never told at all.
    @ObservationIgnored private var externalChangeObservers: [ObjectIdentifier: ExternalChangeObserver] = [:]

    private struct ExternalChangeObserver {
        /// Held weakly: a window that goes without saying so is not kept
        /// alive by this, and is let go at the next change.
        weak var owner: AnyObject?
        let notify: @MainActor () -> Void
    }

    /// Tell `owner` each time an open collection changes on disk — by calling
    /// `handler` with it — until it stops (`stopObservingExternalChanges(of:)`)
    /// or goes. It is held weakly and handed to `handler`, so the handler need
    /// not hold it. Observing again replaces the handler.
    func observeExternalChanges<Owner: AnyObject>(of owner: Owner,
                                                   _ handler: @escaping @MainActor (Owner) -> Void) {
        externalChangeObservers[ObjectIdentifier(owner)] = ExternalChangeObserver(owner: owner) { [weak owner] in
            if let owner { handler(owner) }
        }
    }

    func stopObservingExternalChanges(of owner: AnyObject) {
        externalChangeObservers[ObjectIdentifier(owner)] = nil
    }

    /// An open collection changed on disk — what each collection's watcher
    /// calls (`Collection.activate(onExternalChange:)`). Every window is told.
    func collectionChangedOnDisk() {
        for (key, observer) in externalChangeObservers {
            if observer.owner == nil {
                externalChangeObservers[key] = nil
            } else {
                observer.notify()
            }
        }
    }

    /// Called with a collection's root URL each time it's opened — wired to the
    /// recents store.
    var onOpened: @MainActor (URL) -> Void = { _ in }

    // MARK: - Launch

    /// Whether the launch has settled: what was open at the last quit is open
    /// again and read, and on a first run the collection that ships with the
    /// app. The window's launch work says when (`launchDidSettle`); a library
    /// nothing launches — a test's — never does.
    ///
    /// It exists for what arrives *before* then. A link that launches the app
    /// is handed over while the collection it names is not yet open, or is
    /// open and not yet read; resolved at once it finds nothing, and was
    /// dropped — the window came up and the note did not (`NavigationRouter`).
    @ObservationIgnored private(set) var hasSettled = false
    @ObservationIgnored private var afterSettling: [@MainActor () -> Void] = []

    /// Run `action` once the launch has settled — now, if it has.
    func afterLaunch(_ action: @escaping @MainActor () -> Void) {
        if hasSettled { action() } else { afterSettling.append(action) }
    }

    /// The launch's work is done: whatever waited for it runs, once. Asked
    /// again — a second window's launch — it does nothing.
    func launchDidSettle() {
        guard !hasSettled else { return }
        hasSettled = true
        let waiting = afterSettling
        afterSettling = []
        for action in waiting { action() }
    }

    /// A note the main window has been asked to select by something that holds
    /// no selection of its own: the right panel's Graph, Mind Map and Ask
    /// Library, or `NavigationRouter` (the URL scheme, intents, the Services
    /// menu, widgets). The main window observes this, selects the note, and
    /// clears it.
    var pendingOpenNoteID: Note.ID?

    /// Ask the main window to select and show `noteID`.
    func requestOpen(_ noteID: Note.ID) { pendingOpenNoteID = noteID }

    /// A collection the main window has been asked to *show*. Unlike a change of
    /// `focusedID`, this moves the sidebar even when it is parked on the Library
    /// place, and scrolls the collection's row into view: it is set only when the
    /// user did something that means "take me there" — adding a cloud folder,
    /// say — and a collection added out of sight reads as one that wasn't added.
    var pendingRevealCollectionID: Collection.ID?

    func requestReveal(_ collectionID: Collection.ID) { pendingRevealCollectionID = collectionID }

    // MARK: - The Assistant

    /// Each collection's Assistant: one conversation a collection, however
    /// many windows show it, alive while a note is shown in its tab's place.
    /// It was the tab's own, so showing a note took it down — and a turn
    /// still streaming in the old one then saved over the transcript of the
    /// one made when the tab came back, Use my notes came back on, and a
    /// question asked from one window was taken by whichever window's tab
    /// heard it first, with that window's collection (implemented.md §51.55).
    /// Keyed by collection; `nil` is the conversation with none open.
    /// Observed, so a tab drawn before its model was made draws it when it is:
    /// ignored, the Assistant's tab stayed on its spinner for good (the iPad
    /// test's "doesn't say it is experimental").
    private var assistants: [Collection.ID?: AssistantModel] = [:]

    /// The Assistant for `collection`, made the first time it is asked for:
    /// its tools, its skills and its kept conversation.
    func assistant(for collection: Collection?, settings: IntelligenceSettings) -> AssistantModel {
        if let kept = assistants[collection?.id] { return kept }
        let model = AssistantModel(settings: settings)
        if let collection {
            let skills = SkillStore()
            skills.refresh(from: collection.notes)
            model.toolContext = ToolContext(
                collection: collection, search: collection.search, git: collection.git,
                permissions: PermissionBroker(), settings: settings, skills: skills)
        }
        model.sessionStore = ChatSessionStore(collectionURL: collection?.rootURL)
        assistants[collection?.id] = model
        return model
    }

    /// The Assistant for `collection` if it has been made — a look that
    /// makes nothing (making one reads the kept conversation from disk), for a
    /// view to draw with.
    func assistantIfMade(for collection: Collection?) -> AssistantModel? {
        assistants[collection?.id]
    }

    /// Ask `collection`'s Assistant about a selected phrase.
    ///
    /// The prompt lives here because it was written out at two call sites — one
    /// in each shell — and a sentence duplicated across platforms is a sentence
    /// that can differ on them. It is asked of the conversation itself, not
    /// left for a tab to find: the question used to wait in the library for
    /// whichever window's Assistant noticed it first.
    func askAboutSelection(_ phrase: String, in collection: Collection?, settings: IntelligenceSettings) {
        assistant(for: collection, settings: settings).ask("Explain this, using my notes: \(phrase)")
    }

    /// A closed collection's Assistant stops, keeping what it had said.
    private func retireAssistant(of id: Collection.ID) {
        assistants[id]?.stop()
        assistants[id] = nil
    }

    // MARK: - Focus

    func focus(_ collection: Collection) { focusedID = collection.id }

    /// The collection that contains `fileURL`, if any (matched by path prefix).
    func collection(containing fileURL: URL) -> Collection? {
        let path = fileURL.standardizedFileURL.path
        return collections.first { collection in
            // `collection.id` is the already-standardised root path — reuse it
            // instead of re-standardising the root on each of the many calls.
            let base = collection.id
            return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
    }

    /// Focus the collection owning `fileURL` (used when a note is selected).
    func focusCollection(containing fileURL: URL) {
        if let owner = collection(containing: fileURL) { focusedID = owner.id }
    }

    // MARK: - Open / close

    /// Open the folder at `url` as a collection (or focus it if already open),
    /// activate it, and remember it for next launch. Returns the collection.
    @discardableResult
    func open(url: URL) async -> Collection {
        // What the folder is called, worked out on its lane: it asks the disk
        // (`Collection.Identity`), and on a provider's folder or a stalled
        // share that waits — it was asked on the main actor (implemented.md
        // §51.67). And the folder is known by the collection's own `id`: it
        // was compared by its standardized path, which a folder reached
        // through a symlink spells another way, so it could be opened twice.
        let identity = await FileIO.onLane(for: url) { Collection.Identity(of: url) }
        if let existing = collections.first(where: { $0.id == identity.id }) {
            focusedID = existing.id
            onOpened(url)
            return existing
        }
        let collection = Collection(rootURL: url, identity: identity)
        collections.append(collection)
        focusedID = collection.id
        await collection.activate(onExternalChange: { [weak self] in self?.collectionChangedOnDisk() })
        persist()
        onOpened(url)
        return collection
    }

    /// Open several folders at once (multi-select).
    func open(urls: [URL]) async {
        for url in urls { await open(url: url) }
    }

    /// Open a cloud account (a `RemoteStore` folder) as a first-class collection:
    /// mirror it into a local cache, then open that cache with the normal
    /// machinery. Saved edits upload back through `Collection.remote`.
    ///
    /// The collection is created and focused **before** the sync runs, not
    /// after. Waiting for a whole-account download to finish before showing
    /// anything is why "Add as Collection" looked dead: on a real account
    /// nothing appeared for minutes, and one failed request then discarded even
    /// the folders that had already synced. Now the collection is there
    /// immediately and fills in as the sync proceeds (its own file watcher
    /// picks up each downloaded note), and a failure leaves what did arrive.
    @discardableResult
    func openRemote(
        store: RemoteStore, remoteRoot: String, displayName: String,
        progress: @escaping @Sendable (RemoteSyncProgress) -> Void = { _ in }
    ) async throws -> RemoteSyncOutcome {
        let mirror = RemoteMirror.open(
            store: store,
            cacheRoot: RemoteMirror.cacheDirectory(provider: store.providerName,
                                                   folder: remoteRoot.isEmpty ? displayName : remoteRoot),
            remoteRoot: remoteRoot,
            displayName: displayName)
        // The cache directory has to exist before a Collection can be opened on
        // it; this also fails fast (and visibly) if the container is unwritable.
        try FileManager.default.createDirectory(at: mirror.cacheRoot, withIntermediateDirectories: true)

        let id = mirror.cacheRoot.standardizedFileURL.path
        if let existing = collections.first(where: { $0.id == id }) {
            existing.remote = mirror
            focusedID = existing.id
        } else {
            let collection = Collection(rootURL: mirror.cacheRoot)
            collection.remote = mirror
            collections.append(collection)
            focusedID = collection.id
            await collection.activate(onExternalChange: { [weak self] in self?.collectionChangedOnDisk() })
        }

        // Show it before the sync, not after: the collection exists now, and the
        // point of revealing it is to prove the add worked while the sync runs.
        requestReveal(id)
        persist()

        // Metadata first: the folder's *shape* arrives immediately and content
        // is fetched when something needs it. The eager sync downloaded every note
        // before showing anything, which is fine for a notes vault and hopeless
        // for an account of any size — and it skipped non-Markdown files
        // entirely, so a folder of PDFs mirrored to an empty collection.
        let outcome = try await mirror.syncMetadata(progress: progress)
        if let collection = collections.first(where: { $0.id == id }) {
            await collection.scanOffMain()
            collection.refreshDerived()
        }
        return outcome
    }

    /// Close a collection: stop watching it, drop it, and update persistence.
    func close(_ collection: Collection) {
        collection.deactivate()
        retireAssistant(of: collection.id)
        collections.removeAll { $0.id == collection.id }
        if focusedID == collection.id { focusedID = collections.first?.id }
        persist()
    }

    /// Close every open collection (used when switching to a saved library).
    func closeAll() {
        for collection in collections {
            collection.deactivate()
            retireAssistant(of: collection.id)
        }
        collections.removeAll()
        focusedID = nil
        persist()
    }

    /// Switch to a saved library: close what's open, then open its collections.
    func openLibrary(_ urls: [URL]) async {
        closeAll()
        await open(urls: urls)
    }

    /// Ask the user for folders to open as collections.
    ///
    /// The *request* is published, not presented: a model cannot put a picker
    /// on screen, and the shell already owns one. On both platforms now — the
    /// Mac ran an `NSOpenPanel` inline here, which is what let its start
    /// directory and its message diverge from the iPad's.
    func requestOpenFolder() { pendingFolderPick = .folder }

    /// Ask for an Obsidian vault specifically.
    ///
    /// The *only* difference from `requestOpenFolder` is where the picker opens
    /// and what it says — and that is the entire content of the command, which
    /// is why it is worth its own entry rather than a note in the other one's
    /// message. A vault is a folder; what a person needs is to not have to
    /// navigate to `iCloud Drive ▸ Obsidian` by hand every time.
    ///
    /// These two used to be one request (`.anyFolder`) offered under two menu
    /// labels, and that request opened in the Obsidian directory — so "Open
    /// Collection" started somewhere it had no reason to, and the two commands
    /// were indistinguishable in behaviour as well as in code.
    func requestOpenObsidianVault() { pendingFolderPick = .obsidianVault }

    /// Start a collection in a new, empty folder.
    func requestNewCollection() { pendingFolderPick = .newCollection }

    /// Open a folder in iCloud Drive.
    func requestOpeniCloudDrive() { pendingFolderPick = .iCloudDrive }

    /// Add a folder from a cloud provider that is already mounted on this Mac.
    ///
    /// This is the path that should be tried *first*, and it is the cheapest
    /// thing in the whole cloud story: Box, Dropbox, OneDrive and Google Drive
    /// mount their storage at `~/Library/CloudStorage/<Provider>` as ordinary
    /// dataless files, so a collection there needs **no sign-in, no token, no
    /// cache and no sync engine**. Everything that makes cloud files work —
    /// coordinated reads that materialise on demand, online-only badges,
    /// indexers that skip un-downloaded notes, Download / Remove Download —
    /// already applies, because to the app it is simply a folder.
    ///
    /// The sandbox cannot *list* that directory, but the panel runs out of
    /// process and can, and the user's selection is what grants access.
    func requestOpenCloudFolder() { pendingFolderPick = .cloudFolder }

    /// Open `urls`, pausing to warn about any that look big enough to take a
    /// while. Adding a huge folder is never *blocked* — it is the user's folder
    /// and their call. The warning exists so the wait isn't a surprise, and so
    /// the far more common intent ("I meant my Notes subfolder") has somewhere
    /// to go.
    ///
    /// The warning was inside `#if os(macOS)` and built an `NSAlert`, so **iPad
    /// had none of it**: picking a 2,000-note vault there opened it with no
    /// word and no way to narrow the choice, on the platform where the wait is
    /// longest. The estimate and the flow are shared now, and the question is
    /// published for whichever shell is on screen to ask.
    func openChecking(_ urls: [URL],
                      estimate estimateSize: (URL) async -> FolderSizeEstimate = { await Library.estimateSize(of: $0) }) async {
        for url in urls {
            let estimate = await estimateSize(url)
            guard estimate.looksLarge else { await open(url: url); continue }
            // Ask, and wait for the answer the shell brings back.
            // A closure that resumes it, not `continuation.resume(returning:)`
            // itself: that is `@Sendable (sending LargeFolderChoice) -> ()`, and
            // stored as a plain function it lost both, which the compiler warns
            // risks a data race. The choice is `Sendable`, so nothing is lost.
            let choice = await withCheckedContinuation { continuation in
                // A question still up when another comes — two adds at once —
                // is answered for its asker, as Cancel. Replaced, it took its
                // caller's continuation with it, and that caller waited forever.
                if let unanswered = pendingLargeFolder {
                    pendingLargeFolder = nil
                    unanswered.answer(.cancel)
                }
                pendingLargeFolder = LargeFolderPrompt(url: url, estimate: estimate,
                                                       answer: { continuation.resume(returning: $0) })
            }
            switch choice {
            case .addAnyway:
                await open(url: url)
            case .chooseSubfolder:
                // The shell reopens its own picker rooted here; whatever comes
                // back re-enters this same check.
                pendingFolderPick = .subfolder(of: url)
            case .cancel:
                continue
            }
        }
    }

    /// A folder-picking request the shell should present, or nil.
    ///
    /// **The request carries where to start and what to say**, and it did not.
    /// It was a bare two-case enum that the Mac never used — the Mac ran its
    /// own panel inline, with its own start directory and its own message —
    /// while the iPad shell answered every case by opening the *same* picker at
    /// Obsidian's iCloud folder. So on iPad "add a mounted cloud folder" opened
    /// nowhere near the providers, and "choose a subfolder" of a folder too
    /// large to index reopened the picker outside that folder, which is the one
    /// thing that choice exists to do.
    ///
    /// `Library` is a model and cannot present a picker; that part was right.
    /// What it can do is say precisely what it is asking for.
    enum FolderPickRequest: Equatable, Identifiable {
        /// Any folder, to open as a collection. Opens in Documents.
        case folder
        /// An Obsidian vault. Opens where Obsidian keeps them.
        case obsidianVault
        /// iCloud Drive, which is its own case for the same reason Obsidian is:
        /// the destination is the command.
        ///
        /// It fits none of the others. It is always present and always local,
        /// so it never needs the account flow — but it lives in `Mobile
        /// Documents`, **not** `~/Library/CloudStorage`, so "Open Cloud Folder"
        /// cannot reach it, and it is nowhere near Documents either. Without
        /// its own entry the most universally available cloud folder on the
        /// machine is the hardest one to open.
        case iCloudDrive
        /// A brand-new, empty folder to start a collection in.
        ///
        /// No name sheet of its own: both platforms' pickers can already make a
        /// folder and hand it back (`canCreateDirectories`, and Files' own New
        /// Folder), so asking for a name in our own dialog would be a worse
        /// copy of a control the user already knows — and one that would then
        /// have to answer "where?" separately.
        case newCollection
        /// A folder from a cloud provider already mounted on this machine.
        case cloudFolder
        /// Somewhere inside `url`, which was too large to open whole.
        case subfolder(of: URL)
        /// Re-grant access for an unavailable collection, identified by
        /// `Collection.id` (its path) and shown by `name` for the message.
        ///
        /// Nothing else re-mints a dead bookmark. `retry(_:)` can only refresh
        /// one that still resolves; `persist()` deliberately keeps whatever
        /// bookmark data a collection already has rather than overwriting it
        /// (see its own comment — that is what stops a moved folder from being
        /// silently dropped). So a bookmark that cannot resolve at all — the
        /// entitlement it was minted under no longer matches this build's, or
        /// the grant was simply revoked — had no way back in except removing
        /// the collection and re-adding it, which is losing a working
        /// collection's sort position, folder state and identity to fix an
        /// access grant.
        case relocate(collectionID: String, name: String)

        var id: String {
            switch self {
            case .folder: "folder"
            case .obsidianVault: "obsidian"
            case .iCloudDrive: "icloud"
            case .newCollection: "new"
            case .cloudFolder: "cloud"
            case .subfolder(let url): "sub:" + url.path
            case .relocate(let collectionID, _): "relocate:" + collectionID
            }
        }

        /// Where the picker should open. A hint it may ignore.
        @MainActor
        var startDirectory: URL? {
            switch self {
            // The Mac's real Documents, not the container's — `FileManager`'s
            // `.documentDirectory` answers with the sandbox container, which is
            // a folder the user has never seen and has nothing in it.
            //
            // **iOS has no such folder to point at, and must not be given
            // one.** `RealHome` resolves through `getpwuid_r`, which on iOS
            // *is* the app's container — so "Documents" there is the app's own
            // empty Documents, and the picker opened on "Folder is Empty" with
            // nothing to choose and no hint that the sidebar was the way out.
            // A `nil` hint lets the Files browser open where it last was, which
            // is both the platform convention and somewhere that has files in
            // it.
            case .folder, .newCollection:
                #if os(macOS)
                RealHome.path("Documents")
                #else
                nil
                #endif
            case .obsidianVault: ObsidianVault.browseStartDirectory
            case .iCloudDrive: CloudProvider.iCloudDriveDirectory
            case .cloudFolder: CloudProvider.cloudStorageDirectory
            case .subfolder(let url): url
            // The collection's last-known location is the best starting guess
            // for where it moved to, or simply where to re-grant it in place.
            case .relocate(let collectionID, _): URL(fileURLWithPath: collectionID).deletingLastPathComponent()
            }
        }

        /// What the picker says it is asking for. Shown by the Mac's panel; the
        /// document picker has no such field and ignores it.
        @MainActor
        var message: String {
            switch self {
            case .folder:
                "Choose a folder of Markdown files to open as a collection."
            case .newCollection:
                "Create a folder for your new collection, or choose an empty one."
            case .obsidianVault:
                ObsidianVault.pickerMessage
            case .iCloudDrive:
                "Choose a folder in iCloud Drive."
            case .cloudFolder:
                {
                    let installed = CloudProvider.installedClients()
                    return installed.isEmpty
                        ? "Choose a folder from a cloud provider mounted on this device."
                        : "Choose a folder from \(installed.map(\.name).formatted(.list(type: .and))) "
                            + "— no sign-in needed, the files are already here."
                }()
            case .subfolder(let url):
                "Choose a folder inside “\(url.lastPathComponent)” to open instead."
            case .relocate(_, let name):
                "Locate “\(name)” to restore access."
            }
        }

        var prompt: String {
            switch self {
            case .newCollection: "Create"
            default: "Open"
            }
        }

        /// Whether the picker offers a New Folder control.
        ///
        /// Only where making one is the point. An Open panel that can create
        /// folders is harmless, but a "Create" prompt over a panel that cannot
        /// is a dead end, and that is the case worth being sure of.
        var allowsCreatingFolders: Bool {
            if case .newCollection = self { return true }
            return false
        }
    }
    var pendingFolderPick: FolderPickRequest?

    /// A folder that looks large, and the continuation waiting on the answer.
    ///
    /// Published rather than presented: `Library` is a model and cannot put an
    /// alert on screen, and an `NSAlert` here is what made this macOS-only.
    struct LargeFolderPrompt: Identifiable {
        let id = UUID()
        let url: URL
        let estimate: FolderSizeEstimate
        let answer: (LargeFolderChoice) -> Void
    }

    /// The question waiting to be asked, or nil.
    var pendingLargeFolder: LargeFolderPrompt?

    /// Answer the outstanding question.
    func resolveLargeFolder(_ choice: LargeFolderChoice) {
        guard let prompt = pendingLargeFolder else { return }
        pendingLargeFolder = nil
        prompt.answer(choice)
    }

    enum LargeFolderChoice: Sendable { case addAnyway, chooseSubfolder, cancel }

    /// What a one-second look at a folder suggests about its size.
    struct FolderSizeEstimate: Sendable {
        var itemsSeen = 0
        var directoriesRemaining = 0
        /// The probe walked the *whole* tree inside its budget — so whatever it
        /// counted is the real total, however large.
        var isComplete = false

        /// No magic threshold on a number we can't know in advance: the signal
        /// is that a full second wasn't enough to finish *and* there is already
        /// a lot here.
        var looksLarge: Bool { !isComplete && itemsSeen >= 5_000 }
    }

    /// Walk for at most `budget` seconds and report what was found.
    static func estimateSize(of url: URL, budget: TimeInterval = 1.0) async -> FolderSizeEstimate {
        let source = LocalTreeSource(root: url)
        let walk = Task.detached(priority: .userInitiated) {
            await ResumableTreeWalk.run(source: source) { _ in }
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(budget))
            walk.cancel()
        }
        let result = await walk.value
        deadline.cancel()
        return FolderSizeEstimate(itemsSeen: result.progress.itemsSeen,
                                  directoriesRemaining: result.progress.directoriesRemaining,
                                  isComplete: result.isComplete)
    }

    // MARK: - Persistence (security-scoped bookmarks)

    private static let bookmarksKey = "collectionBookmarks"
    /// Cache directories of direct-API collections, so they come back on launch.
    private static let remoteCachesKey = "remoteCollectionCaches"
    /// Last-known paths, index-aligned with `bookmarksKey`. Kept purely so a
    /// collection whose bookmark no longer resolves can still be *named* on
    /// screen — otherwise the only honest thing left to say would be nothing,
    /// which is what it used to say.
    private static let pathsKey = "collectionPaths"
    private static let legacyKey = "vaultBookmark"

    /// Reopen the collections that were open at last quit. Call once at launch.
    func restore() async {
        let store = defaults
        var datas = (store.array(forKey: Self.bookmarksKey) as? [Data]) ?? []
        var paths = (store.array(forKey: Self.pathsKey) as? [String]) ?? []

        // Migrate a single legacy vault bookmark into the new list.
        if datas.isEmpty, let legacy = store.data(forKey: Self.legacyKey) {
            datas = [legacy]
            paths = []
            store.removeObject(forKey: Self.legacyKey)
        }

        // `open(url:)` awaits each collection's off-main scan before returning,
        // so restoring several folders used to cost the *sum* of their cold-scan
        // latencies at every launch. Create them up front (cheap, main-actor)
        // and let the scans overlap: activate() suspends on scanOffMain() and
        // git.refreshStatus(), which frees the main actor for its siblings, so
        // the launch now costs the slowest scan rather than all of them.
        var restored: [Collection] = []
        var refreshedBookmarks = false

        // **Resolved off the main actor**, one after another, in the order
        // they were saved. Resolving can mount a volume and minting a stale
        // one again asks the sandbox; it was done here, on the main actor,
        // holding the launch up behind the splash (implemented.md §51.36).
        // Each on a lane, keyed by the folder it last named — the app's, at the
        // priority of the launch it holds up, not the scans' utility one:
        // resolving can wait on a volume or a provider, and in one `offMain`
        // it held a thread of the pool for all of them (§51.64). The key is
        // the path alone — `URL(fileURLWithPath:)` asks the disk whether it is
        // a folder.
        // And what each folder is called (`Collection.Identity`), in the same
        // hop — it asks the disk too, and on the main actor it was asked
        // once for every collection, and of a dead bookmark's path, the one
        // most likely to be on a volume that has gone (§51.67).
        let bookmarks = datas
        let places = paths
        let foundFolders = await offMainAwaiting { () -> [Found?] in
            var found: [Found?] = []
            for (index, data) in bookmarks.enumerated() {
                let lastPath = index < places.count ? places[index] : nil
                let place = URL(filePath: lastPath ?? "/", directoryHint: .inferFromPath)
                found.append(await FileIO.onLane(for: place) { () -> Found? in
                    if let resolved = Bookmark.resolveRefreshing(data) {
                        return Found(url: resolved.url, identity: Collection.Identity(of: resolved.url),
                                     refreshed: resolved.refreshed, isDead: false)
                    }
                    guard let lastPath else { return nil }   // pre-migration: nothing to show
                    let url = URL(fileURLWithPath: lastPath)
                    return Found(url: url, identity: Collection.Identity(of: url), refreshed: nil, isDead: true)
                })
            }
            return found
        }

        for (index, data) in datas.enumerated() {
            guard let found = foundFolders[index] else { continue }
            if !found.isDead, found.refreshed != nil { refreshedBookmarks = true }

            if found.isDead {
                // The bookmark is dead — the folder is gone, or its volume is.
                // Dropping it here is what made collections silently disappear
                // between launches. Keep it, say why, and let the user decide.
                let url = found.url
                guard !collections.contains(where: { $0.id == found.identity.id }) else { continue }
                let collection = Collection(rootURL: url, identity: found.identity)
                collection.bookmarkData = data
                // Missing, at once; the reason is corrected by a look at the
                // folder off the main actor, on the collection's own lane
                // (`Collection.onRootLane`), that nothing waits for. The list
                // is built whole here, so the look was a listing of a dead
                // folder on the main actor inside it.
                collection.markUnavailable(.missing)
                let lane = collection.rootCalls
                Task { [weak collection] in
                    let reason = await lane.onLane(for: url) { Collection.unavailability(of: url) }
                    // Unless something has answered since — a Try Again.
                    guard let collection, let reason, collection.state == .unavailable(.missing) else { return }
                    collection.markUnavailable(reason)
                }
                collections.append(collection)
                continue
            }

            guard !collections.contains(where: { $0.id == found.identity.id }) else { continue }
            let collection = Collection(rootURL: found.url, identity: found.identity)
            collection.bookmarkData = found.refreshed ?? data
            collections.append(collection)
            restored.append(collection)
        }

        // A re-minted bookmark is only useful once it is written back.
        if refreshedBookmarks { persist() }
        await restoreRemoteCollections()
        guard !restored.isEmpty else { return }

        let externalChange: @MainActor () -> Void = { [weak self] in self?.collectionChangedOnDisk() }
        await withTaskGroup(of: Void.self) { group in
            for collection in restored {
                group.addTask { @MainActor in
                    await collection.activate(onExternalChange: externalChange)
                }
            }
        }

        // Focus the last restored collection and persist once, matching the
        // serial version's end state.
        focusedID = restored.last?.id ?? focusedID
        for collection in restored { onOpened(collection.rootURL) }
        persist()
    }

    private func persist() {
        // A parity capture (`scripts/window-parity.sh`) opens the sample
        // collection alone; saving that as the open list would drop every
        // collection the person actually has open. It saves nothing instead —
        // which is also why nothing has to be put back afterwards.
        guard !CaptureSession.isActive else { return }
        // Keep the two arrays index-aligned, and keep an *unavailable*
        // collection's existing bookmark rather than trying to re-mint one from
        // a folder that isn't there — re-minting would fail and quietly drop it,
        // which is the behaviour this whole path exists to end.
        var datas: [Data] = []
        var paths: [String] = []
        for collection in collections {
            // A direct-API collection is restored from its cache root below,
            // and must **not** also be listed here.
            //
            // It was, and the two restores then raced: the plain path came
            // back first as an ordinary folder pointing into the mirror
            // directory, `restoreRemoteCollections` found that id already
            // present and skipped it, and the collection lost its `remote`
            // mirror for good. The next `persist()` then wrote an empty cache
            // list — so a collection added from Dropbox stopped syncing after
            // one relaunch and became a stale copy of itself, with nothing
            // said.
            guard collection.remote == nil else { continue }
            guard let data = collection.bookmarkData ?? Bookmark.data(for: collection.rootURL)
            else { continue }
            collection.bookmarkData = data
            datas.append(data)
            paths.append(collection.rootURL.path)
        }
        defaults.set(datas, forKey: Self.bookmarksKey)
        defaults.set(paths, forKey: Self.pathsKey)

        // Direct-API collections live in our own container, so they need no
        // bookmark — just the cache directory, which the manifest inside it
        // describes completely.
        let remotes = collections.compactMap { $0.remote?.cacheRoot.path }
        defaults.set(remotes, forKey: Self.remoteCachesKey)
    }

    /// Rebuild the direct-API collections that were open at last quit.
    ///
    /// Restoring these used to be refused on the grounds that a stale cache
    /// shouldn't masquerade as a collection — which was right while staleness was
    /// undetectable. The manifest changed that: it records a delta cursor, so the
    /// collection comes back **instantly from cache** and then asks the provider
    /// what has changed. The alternative was making the user reconnect every
    /// session to see notes that were already on disk.
    private func restoreRemoteCollections() async {
        let caches = (defaults.array(forKey: Self.remoteCachesKey) as? [String]) ?? []
        for path in caches {
            let cacheRoot = URL(fileURLWithPath: path, isDirectory: true)
            // Read and decoded off the main actor — a manifest is a record per
            // file in the account's folder — and handed to the mirror, which
            // decoded it again at its first use (implemented.md §51.36).
            guard let manifest = await offMain({ RemoteManifest.load(fromCacheRoot: cacheRoot) }) else { continue }
            // No account recorded means no way to know whose credentials this
            // needs, so it cannot be rebuilt — better an absent collection than
            // one silently signed in as somebody else.
            guard let accountID = manifest.accountID,
                  let store = Self.makeStore(named: manifest.provider, accountID: accountID)
            else { continue }
            // The account's token read off the main actor, into the cache the
            // refresh below asks: its first read of the launch is a Keychain
            // call, and it was made on the main actor, for as long as any
            // Keychain prompt stayed up (implemented.md §51.36).
            _ = await offMain { store.isAuthenticated }
            let id = cacheRoot.standardizedFileURL.path
            guard !collections.contains(where: { $0.id == id }) else { continue }

            let mirror = RemoteMirror.open(store: store, cacheRoot: cacheRoot,
                                           remoteRoot: manifest.remoteRoot,
                                           displayName: manifest.displayName,
                                           manifest: manifest)
            let collection = Collection(rootURL: cacheRoot)
            collection.remote = mirror
            collections.append(collection)
            await collection.activate(onExternalChange: { [weak self] in self?.collectionChangedOnDisk() })

            // Then reconcile in the background — the cached notes are already on
            // screen, so a slow provider costs nothing but freshness.
            Task { [weak collection] in await collection?.refreshFromProvider() }
        }
    }

    /// Recreate a provider client from what the manifest recorded.
    ///
    /// Both halves are needed: the provider says *which* service, the account
    /// says *whose* credentials. A collection added from a work OneDrive must
    /// come back signed in as that account and not the personal one.
    private static func makeStore(named provider: String, accountID: String) -> RemoteStore? {
        switch provider {
        case "Dropbox":      return DropboxStore(accountID: accountID)
        case "Box":          return BoxStore(accountID: accountID)
        case "Google Drive": return GoogleDriveStore(accountID: accountID)
        case "OneDrive":     return OneDriveStore(accountID: accountID)
        default:             return nil
        }
    }

    /// What launch found for one saved folder, off the main actor: its URL
    /// and identity, and the bookmark minted again — or, for a bookmark that
    /// no longer resolves, the path it last named (`isDead`).
    private nonisolated struct Found: Sendable {
        let url: URL
        let identity: Collection.Identity
        let refreshed: Data?
        let isDead: Bool
    }

    /// Try an unavailable collection again — the drive was plugged back in, or
    /// the folder came out of the Trash. Re-resolves the bookmark first, so a
    /// folder that *moved* is followed rather than reported missing forever.
    @discardableResult
    func retry(_ collection: Collection) async -> Bool {
        // Resolved off the main actor, and without mounting: a share gone away
        // is mounted in the Finder, not by Try Again on the main thread
        // (implemented.md §51.36) — on the collection's own lane, where it
        // waits for no other file (§51.64).
        if let data = collection.bookmarkData,
           let named = await collection.onRootLane({ () -> ((url: URL, refreshed: Data?), String)? in
               // And what the folder it names is called, in the same hop — the
               // collection's own kind of name, so a folder reached through a
               // symlink is not taken for a move at every Try Again (§51.67).
               Bookmark.resolveRefreshing(data, mounting: false).map { ($0, Collection.Identity(of: $0.url).id) }
           }) {
            let (resolved, id) = named
            if let refreshed = resolved.refreshed { collection.bookmarkData = refreshed }
            // Moved: the bookmark tracks the folder by identity, so it now points
            // somewhere else. The collection's id *is* its path, so it has to be
            // reopened there rather than mutated in place.
            if id != collection.id {
                close(collection)
                await open(url: resolved.url)
                return true
            }
        }
        let back = await collection.recheckAvailability()
        if back { persist() }
        return back
    }

    /// Ask the user to re-grant access to `collection` — the recovery path for
    /// a bookmark that `retry(_:)` cannot fix because it no longer resolves at
    /// all, rather than merely being stale.
    func requestRelocate(_ collection: Collection) {
        pendingFolderPick = .relocate(collectionID: collection.id, name: collection.name)
    }

    /// Re-grant `collection` using a fresh picker selection. Unlike `open(url:)`
    /// on an already-open path, this **always** mints and stores new bookmark
    /// data — the one thing `persist()` deliberately won't do for a collection
    /// that already has bookmark data, dead or not.
    func relocate(collectionID: String, to url: URL) async {
        guard let collection = collections.first(where: { $0.id == collectionID }) else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Minted off the main actor (implemented.md §51.36), on the folder's
        // lane: minting can wait on its volume or provider, as resolving can,
        // and in `offMain` it held a thread of the pool (§51.64).
        // And what the folder is called, in the same hop (§51.67).
        let (bookmark, id) = await FileIO.onLane(for: url) { (Bookmark.data(for: url), Collection.Identity(of: url).id) }
        collection.bookmarkData = bookmark
        if id != collection.id {
            // Picked a different folder than the one that was broken (the user
            // is relocating a moved vault, not just re-granting the same one)
            // — the collection's id is its path, so it has to be reopened
            // there rather than mutated in place. Same reasoning as `retry(_:)`.
            close(collection)
            await open(url: url)
        } else {
            _ = await collection.recheckAvailability()
            persist()
        }
    }

    /// Open whatever a folder picker returned.
    ///
    /// Written twice: `iOSContentView.openPicked` and
    /// `MacContentView.openObsidianVault`, and they had drifted. The iPad went
    /// through `openChecking`, which warns before indexing a folder large
    /// enough to be someone's whole home directory; the Mac called `open(urls:)`
    /// straight through and warned about nothing. The same picker, the same
    /// question, two answers.
    ///
    /// Vault discovery applies to whatever survives that check: a folder that
    /// *contains* vaults opens them, a folder that is one opens itself.
    func openPicked(_ urls: [URL]) async {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            let vaults = ObsidianVault.discoverVaults(in: url)
            if vaults.isEmpty {
                await openChecking([url])
            } else {
                // Hold the picked folder's scope while opening each child
                // vault. A discovered child URL is not itself picker- or
                // bookmark-scoped, so `Collection.activate`'s own
                // `startAccessingSecurityScopedResource()` returns false;
                // without the parent scope held, the vault would open (and
                // bookmark) as an empty collection.
                for vault in vaults { await open(url: vault) }
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
    }

}
