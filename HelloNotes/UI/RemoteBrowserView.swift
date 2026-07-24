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

@MainActor
@Observable
final class RemoteBrowserModel {
    let store: RemoteStore

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

    init(store: RemoteStore) {
        self.store = store
        self.isAuthenticated = store.isAuthenticated
    }

    var providerName: String { store.providerName }
    var canGoUp: Bool { !path.isEmpty }
    var displayPath: String { path.isEmpty ? "/" : path }

    func connect() async {
        error = nil
        do {
            try await store.authenticate()
            isAuthenticated = store.isAuthenticated
            await load("")
        } catch {
            self.error = describe(error)
        }
    }

    func load(_ folder: String) async {
        path = folder
        isLoading = true
        error = nil
        do { entries = try await store.list(path: folder) }
        catch { self.error = describe(error); entries = [] }
        isLoading = false
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
    }

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
    /// When set, the browser offers "Open as Collection", handing back the
    /// (store, current remote path, display name) so the host can mirror it into
    /// a first-class sidebar collection.
    private let onOpenAsCollection: ((RemoteStore, String, String) -> Void)?

    init(store: RemoteStore,
         onOpenAsCollection: ((RemoteStore, String, String) -> Void)? = nil) {
        _model = State(initialValue: RemoteBrowserModel(store: store))
        self.onOpenAsCollection = onOpenAsCollection
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
                if let onOpenAsCollection {
                    Button("Open as Collection") {
                        let name = model.path.isEmpty
                            ? model.providerName
                            : String(model.path.split(separator: "/").last ?? Substring(model.providerName))
                        onOpenAsCollection(model.store, model.path, name)
                    }
                    .font(.caption)
                    .help("Add this folder to the sidebar; edits sync back to \(model.providerName).")
                }
                Button("Sign Out") { model.signOut() }
                    .font(.caption)
            }
            .padding(10)
            Divider()

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
                if model.entries.isEmpty && !model.isLoading {
                    ContentUnavailableView("Empty folder", systemImage: "folder")
                }
            }

            if let error = model.error {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
