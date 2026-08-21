//
//  RemoteBrowserView.swift
//  HelloNotes
//
//  Created by Chris Tham on 21/7/2026.
//
//  The direct-API (Phase 4) surface: sign in to a RemoteStore provider, browse
//  its folders, and open / edit / save a note straight over the provider's REST
//  API — no File Provider mount, no local sync. Works against any RemoteStore
//  (DropboxStore in production; MockRemoteStore for the demo entry point and
//  RemoteBrowserModel's tests).
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
        self.isAuthenticated = store.isAuthenticated
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

    func addAsCollection() {
        guard onAdd != nil, !isAdding else { return }
        let store = self.store
        let remoteRoot = self.path
        let name = self.collectionName
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

struct RemoteBrowserView: View {
    @State private var model: RemoteBrowserModel

    /// Closes this browser — its own window on macOS, the settings sheet on iOS.
    @Environment(\.dismiss) private var dismiss

    /// `onAddAsCollection` — when set, the browser offers "Add as Collection",
    /// handing the current folder to the host so it can mirror it into a
    /// first-class sidebar collection, and reporting back what happened. It goes
    /// straight into the model rather than being stored here; see the typealias.
    init(store: RemoteStore, onAddAsCollection: AddRemoteCollection? = nil) {
        _model = State(initialValue: RemoteBrowserModel(store: store, onAdd: onAddAsCollection))
    }

    var body: some View {
        Group {
            if model.isAuthenticated {
                browser
            } else {
                connect
            }
        }
        .frame(minWidth: 380, minHeight: 420)
        // A window opened with a token already in the Keychain never runs
        // `connect()`, so this is the only thing that lists the root for it.
        .task { await model.loadRootIfNeeded() }
        .sheet(item: Binding(get: { model.openPath.map { OpenNote(path: $0) } },
                             set: { if $0 == nil { model.closeNote() } })) { _ in
            noteEditor
        }
    }

    // MARK: Connect

    private var connect: some View {
        VStack(spacing: 16) {
            Image(systemName: "cloud")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Connect \(model.providerName)")
                .font(.title2.bold())
            Text("Sign in to browse and edit notes directly over the provider's API — no sync folder needed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Connect \(model.providerName)") {
                Task { await model.connect() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if let error = model.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 340)
            }
        }
        .padding(32)
    }

    // MARK: Browser

    private var browser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { Task { await model.goUp() } } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(!model.canGoUp)
                .help("Parent folder")
                Text(model.displayPath)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
                if model.canAddAsCollection {
                    Button("Add as Collection") { model.addAsCollection() }
                    .font(.caption)
                    .disabled(model.isAdding)
                    .help("Add “\(model.collectionName)” to the sidebar; edits sync back to \(model.providerName).")
                }
                Button("Sign Out") { model.signOut() }
                    .font(.caption)
                    .disabled(model.isAdding)
            }
            .padding(10)
            Divider()

            addStatus

            List(model.entries, id: \.path) { entry in
                Button {
                    Task { await model.open(entry) }
                } label: {
                    HStack {
                        Image(systemName: entry.isDirectory ? "folder" : "doc.text")
                            .foregroundStyle(entry.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        Text(entry.name)
                        Spacer()
                        if entry.isDirectory {
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .overlay {
                // Only claim the folder is empty when we actually listed it.
                // A failed listing showing "Empty folder" is the same lie as an
                // unreachable vault showing no notes.
                if model.entries.isEmpty && !model.isLoading && model.error == nil {
                    ContentUnavailableView("Empty folder", systemImage: "folder")
                }
            }

            if let error = model.error {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                        if model.needsReauthentication {
                            Text("The saved sign-in for \(model.providerName) is no longer valid.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if model.needsReauthentication {
                        Button("Sign In Again") { Task { await model.reconnect() } }
                            .font(.caption)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Add-as-collection status

    /// Says what the add action is doing and what it achieved. Silent when
    /// idle, so the browser looks exactly as it did before you pressed anything.
    @ViewBuilder
    private var addStatus: some View {
        switch model.addState {
        case .idle:
            EmptyView()

        case .adding(let progress):
            statusStrip {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Adding “\(model.collectionName)”…")
                        .font(.caption.weight(.medium))
                    Text(Self.line(for: progress))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Stop") { model.cancelAdd() }
                    .font(.caption)
                    .help("Stop syncing. Notes already downloaded stay in the collection.")
            }

        case .added(let name, let outcome):
            statusStrip {
                Image(systemName: outcome.isComplete ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(outcome.isComplete ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Added “\(name)” to the sidebar")
                        .font(.caption.weight(.medium))
                    Text(Self.summary(for: outcome))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                // The job is done: the collection is in the sidebar and already
                // scrolled into view. Leaving the browser sitting in front of it
                // makes the user close a window to see what they just added, so
                // OK finishes the whole errand rather than only the message.
                Button("OK") {
                    model.dismissAddResult()
                    dismiss()
                }
                .font(.caption)
                .keyboardShortcut(.defaultAction)
            }

        case .failed(let message):
            statusStrip {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Couldn't add “\(model.collectionName)”")
                        .font(.caption.weight(.medium))
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                // Deliberately *not* closing the window: nothing was added, the
                // message is the only record of why, and the next thing you want
                // is probably to try again from here.
                Button("Dismiss") { model.dismissAddResult() }
                    .font(.caption)
            }
        }
    }

    private func statusStrip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8, content: content)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
        }
        .background(.quaternary.opacity(0.4))
    }

    private static func line(for progress: RemoteSyncProgress) -> String {
        var parts = ["\(progress.foldersListed) folder\(progress.foldersListed == 1 ? "" : "s")"]
        if progress.filesMirrored > 0 { parts.append("\(progress.filesMirrored) files") }
        if !progress.currentPath.isEmpty { parts.append(progress.currentPath) }
        return parts.joined(separator: " · ")
    }

    /// Deliberately states what was *not* done as well as what was. A sync that
    /// stopped early or skipped folders has not seen the whole remote folder,
    /// and saying so is the difference between a trustworthy collection and one
    /// that quietly omits notes.
    private static func summary(for outcome: RemoteSyncOutcome) -> String {
        let files = outcome.progress.filesMirrored
        let folders = outcome.progress.foldersListed
        var text = "\(files) file\(files == 1 ? "" : "s") in \(folders) folder\(folders == 1 ? "" : "s")."
        if files > 0 {
            // Say what has and hasn't been fetched. The collection is usable
            // now; the bytes arrive per file, on demand.
            text += " Their contents download as you open them."
        }

        if !outcome.isComplete {
            if outcome.failures.isEmpty {
                text += " Stopped before the whole folder was checked — use Add as Collection again to finish."
            } else {
                let failed = outcome.failures.count
                text += " \(failed) item\(failed == 1 ? "" : "s") couldn't be read (\(outcome.failures[0].message))"
                if failed > 1 { text += " and \(failed - 1) more." } else { text += "." }
            }
        }
        return text
    }

    // MARK: Note editor

    private var noteEditor: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.openPath.map { RemoteBrowserModel.parent(of: $0).isEmpty ? $0 : $0 } ?? "")
                    .font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                if model.didSave {
                    Label("Saved", systemImage: "checkmark.circle").foregroundStyle(.green).font(.caption)
                }
                if model.isSaving { ProgressView().controlSize(.small) }
                Button("Save") { Task { await model.save() } }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.isSaving)
                Button("Close") { model.closeNote() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            TextEditor(text: $model.openText)
                .font(.body.monospaced())
                .padding(6)
        }
        .frame(minWidth: 460, minHeight: 420)
    }

    private struct OpenNote: Identifiable { let path: String; var id: String { path } }
}
