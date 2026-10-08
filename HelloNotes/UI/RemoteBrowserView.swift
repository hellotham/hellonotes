//
//  RemoteBrowserView.swift
//  HelloNotes
//
//  Created by Chris Tham on 21/7/2026.
//
//  The direct-API (Phase 4) browsing model: sign in to a RemoteStore provider,
//  browse its folders, and add one as a collection — no File Provider mount.
//  Works against any RemoteStore (MockRemoteStore in RemoteBrowserModel's
//  tests). What draws it is `RemoteFolderPicker`, reached from the cloud
//  collections sheet.
//
//  It had a view of its own here, `RemoteBrowserView`, a browser window that
//  also opened and edited notes over the API. Nothing had shown it since
//  August, when browsing became the folder picker; it was deleted rather than
//  kept compiling for no one.
//

import SwiftUI

/// Adds the browsed folder as a sidebar collection: reports progress while it
/// works and returns what actually happened, so the browser can show a real
/// result rather than leaving the user to guess.
/// Deliberately **not** `@Sendable`: `RemoteBrowserModel` stores it and only ever
/// calls it from its own `@MainActor` context, so the function value never
/// crosses an isolation boundary. (Marking it `@Sendable` doesn't help anyway —
/// under Swift 5 a function value read back out of a stored property loses the
/// attribute, so the conversion warns no matter how it's declared. Keeping the
/// closure inside the actor is the fix; the annotation was only a plaster.)
///
/// `progress` *is* `@Sendable`: it is called from the sync's own executor.
typealias AddRemoteCollection = @MainActor (
    _ store: RemoteStore,
    _ remoteRoot: String,
    _ displayName: String,
    _ progress: @escaping @Sendable (RemoteSyncProgress) -> Void
) async throws -> RemoteSyncOutcome

extension Library {
    /// Mirror a browsed cloud folder into a sidebar collection, handing
    /// progress and failures back to the browser that asked for it.
    ///
    /// This was `Task { try? await library.openRemote(…) }` at five call sites:
    /// the `try?` discarded every error, and nothing awaited or reported the
    /// result — so an expired token, a 403 on a shared folder and a complete
    /// success all looked identical, and identical to the button being dead.
    ///
    /// Then it was written twice: once in `HelloNotesApp` behind
    /// `#if os(macOS)`, once in `iOSContentView`, byte for byte the same. It
    /// belongs to the library, which is the object that does the work and the
    /// one thing both call sites already have.
    var addRemoteCollection: AddRemoteCollection {
        { [self] store, remoteRoot, displayName, progress in
            try await openRemote(store: store, remoteRoot: remoteRoot,
                                 displayName: displayName, progress: progress)
        }
    }
}

@MainActor
@Observable
final class RemoteBrowserModel {
    let store: RemoteStore

    /// Non-nil when this browser can promote a folder to a sidebar collection.
    /// Held here rather than in the view so it never has to be handed across an
    /// isolation boundary — see `AddRemoteCollection`.
    private let onAdd: AddRemoteCollection?
    var canAddAsCollection: Bool { onAdd != nil }

    var path = ""                       // current folder ("" = root)
    var entries: [RemoteEntry] = []
    var isLoading = false
    var error: String?

    var openPath: String?               // the note being edited, if any
    var openText = ""
    var isSaving = false
    var didSave = false

    /// Mirrors the store's auth state as an *observed* property — the view
    /// switches on this. (Reading `store.isAuthenticated` directly wouldn't
    /// trigger a SwiftUI update, since the store isn't @Observable.)
    private(set) var isAuthenticated: Bool

    init(store: RemoteStore, onAdd: AddRemoteCollection? = nil) {
        self.store = store
        self.onAdd = onAdd
        // Not asked here: the answer is a Keychain read, the account's first
        // of the launch, and this runs on the main actor as the sheet opens.
        // Loading until `start` has asked it off the main actor
        // (implemented.md §51.36).
        self.isAuthenticated = false
        self.isLoading = true
    }

    /// What the sheet does as it opens: ask whether the account is signed in,
    /// off the main actor, then list the root — or sign in, which is part of
    /// opening rather than a screen to find.
    func start() async {
        let store = self.store
        let authenticated = await offMain { store.isAuthenticated }
        isAuthenticated = authenticated
        isLoading = false
        if authenticated {
            await loadRootIfNeeded()
        } else {
            await connect()
        }
    }

    var providerName: String { store.providerName }
    var canGoUp: Bool { !path.isEmpty }
    var displayPath: String { path.isEmpty ? "/" : path }

    /// Set when the provider rejects a request we thought was authenticated —
    /// the stored token exists but is expired, revoked, or its refresh failed.
    /// The browser then offers to sign in again instead of looking merely empty.
    private(set) var needsReauthentication = false

    /// Whether the root has been listed yet. A window opened with a token
    /// already in the Keychain skips `connect()` entirely, so without this the
    /// browser never issued a single request and showed an empty folder — signed
    /// in, apparently, to nothing.
    private var didLoadInitialFolder = false

    func loadRootIfNeeded() async {
        guard isAuthenticated, !didLoadInitialFolder else { return }
        didLoadInitialFolder = true
        await load("")
    }

    func connect() async {
        error = nil
        needsReauthentication = false
        do {
            try await store.authenticate()
            isAuthenticated = store.isAuthenticated
            didLoadInitialFolder = true
            await load("")
        } catch {
            self.error = describe(error)
        }
    }

    /// Discard the rejected token and start the sign-in flow again.
    func reconnect() async {
        store.signOut()
        isAuthenticated = false
        needsReauthentication = false
        entries = []
        path = ""
        didLoadInitialFolder = false
        await connect()
    }

    func load(_ folder: String) async {
        path = folder
        isLoading = true
        error = nil
        do {
            entries = try await store.list(path: folder)
            needsReauthentication = false
        } catch {
            self.error = describe(error)
            entries = []
            needsReauthentication = Self.isAuthFailure(error)
        }
        isLoading = false
    }

    /// A token the provider won't accept, as opposed to a folder we can't read.
    private static func isAuthFailure(_ error: Error) -> Bool {
        switch error as? RemoteStoreError {
        case .notAuthenticated:      return true
        case .http(let code, _):     return code == 401
        default:                     return false
        }
    }

    func refresh() async { await load(path) }
    func goUp() async { await load(Self.parent(of: path)) }

    func open(_ entry: RemoteEntry) async {
        if entry.isDirectory {
            await load(entry.path)
            return
        }
        error = nil
        do {
            let data = try await store.read(path: entry.path)
            // Decode strictly. `String(decoding:as:)` is *lossy* — it silently
            // substitutes U+FFFD for invalid bytes, so opening a PDF/PNG and
            // hitting Save would upload mojibake over the original file on the
            // provider. Refuse to open anything that isn't valid UTF-8 text.
            guard let text = String(data: data, encoding: .utf8) else {
                self.error = "“\(entry.name)” isn’t a UTF-8 text file, so it can’t be edited here. Opening it would risk overwriting it with corrupted content."
                return
            }
            openText = text
            openPath = entry.path
            didSave = false
        } catch {
            self.error = describe(error)
        }
    }

    func save() async {
        guard let openPath else { return }
        isSaving = true
        error = nil
        didSave = false
        do {
            try await store.write(Data(openText.utf8), to: openPath)
            didSave = true
        } catch {
            self.error = describe(error)
        }
        isSaving = false
    }

    func closeNote() { openPath = nil; openText = ""; didSave = false }

    func signOut() {
        store.signOut()
        isAuthenticated = store.isAuthenticated
        entries = []
        openPath = nil
        path = ""
        addState = .idle
        didLoadInitialFolder = false
        needsReauthentication = false
    }

    // MARK: - Add as Collection

    /// What the add action is doing.
    ///
    /// The action used to have no state at all: it called a closure whose body
    /// was `try? await …`, so a permissions failure, a rate limit and a
    /// complete success were indistinguishable — from each other and from the
    /// button doing nothing.
    enum AddState: Equatable {
        case idle
        case adding(RemoteSyncProgress)
        case added(name: String, outcome: RemoteSyncOutcome)
        case failed(String)
    }

    var addState: AddState = .idle
    private var addTask: Task<Void, Never>?

    var isAdding: Bool { if case .adding = addState { return true } else { return false } }

    /// The name a collection added from the current folder would take.
    var collectionName: String {
        path.isEmpty
            ? providerName
            : String(path.split(separator: "/").last ?? Substring(providerName))
    }

    /// - Parameter folder: the folder to add, defaulting to the one being
    ///   shown. `RemoteFolderPicker` passes the *selected* row, so "Choose"
    ///   can take a folder you highlighted without first navigating into it —
    ///   which is how every file picker behaves and what the old browser, with
    ///   only a current-folder "Add as Collection", could not do.
    func addAsCollection(folder: RemoteEntry? = nil) {
        guard onAdd != nil, !isAdding else { return }
        let store = self.store
        let remoteRoot = folder?.path ?? self.path
        let name = folder?.name ?? self.collectionName
        addState = .adding(RemoteSyncProgress())

        // Progress is reported from the sync's own executor, so it has to reach
        // the main actor somehow. A stream does that without the callback
        // capturing this model at all — which matters because a closure that
        // hops by nesting a `Task` inside itself captures its enclosing weak
        // binding as a `var`, a data race under Swift 6.
        //
        // `bufferingNewest(1)` also coalesces for free: a fast sync can report
        // hundreds of times a second and only the latest count is worth drawing.
        let (progressStream, continuation) = AsyncStream<RemoteSyncProgress>
            .makeStream(bufferingPolicy: .bufferingNewest(1))
        let report: @Sendable (RemoteSyncProgress) -> Void = { continuation.yield($0) }

        // Both tasks are created here, at method scope, where `self` is the real
        // model rather than another closure's captured binding.
        let pump = Task { @MainActor [weak self] in
            for await progress in progressStream {
                guard let self, self.isAdding else { continue }
                self.addState = .adding(progress)
            }
        }

        addTask = Task { @MainActor [weak self] in
            defer { continuation.finish(); pump.cancel() }
            guard let self, let onAdd = self.onAdd else { return }
            do {
                let outcome = try await onAdd(store, remoteRoot, name, report)
                // A cancelled sync returns what it managed rather than throwing,
                // so the user still sees what arrived before they stopped it.
                self.addState = .added(name: name, outcome: outcome)
            } catch is CancellationError {
                self.addState = .idle
            } catch {
                self.addState = .failed(self.describe(error))
            }
        }
    }

    /// Stop the sync. What already downloaded stays — the collection is in the
    /// sidebar and keeps the notes it got.
    func cancelAdd() { addTask?.cancel() }

    func dismissAddResult() { addState = .idle }

    private func describe(_ e: Error) -> String {
        (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
    }

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<slash])
    }
}
