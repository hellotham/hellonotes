//
//  NewRepositoryView.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Create a new collection backed by a fresh Git repository: a local folder
//  (initialised with a starter README and first commit) and, optionally, a new
//  remote created on a connected hosting account and pushed to.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct NewRepositoryView: View {
    @Bindable var store: GitAccountsStore
    /// Called with the new repository's local folder URL once created.
    var onCreated: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @State private var showFolderPicker = false
    #endif

    @State private var git = GitService()
    @State private var name = ""
    @State private var parent: URL?
    @State private var createRemote = false
    @State private var selectedHost = ""
    @State private var isPrivate = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("New Repository", systemImage: "plus.rectangle.on.folder")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()

            Form {
                Section("Local") {
                    TextField("Name", text: $name, prompt: Text("my-notes"))
                    HStack {
                        Text("Location")
                        Spacer()
                        Button(parent?.lastPathComponent ?? "Choose…") { chooseParent() }
                            .lineLimit(1)
                    }
                    if let parent {
                        Text(parent.appendingPathComponent(name.isEmpty ? "…" : name).path)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }

                Section("Remote") {
                    Toggle("Create a remote repository", isOn: $createRemote)
                        .disabled(store.accounts.isEmpty)
                    if store.accounts.isEmpty {
                        Text("Add a hosting account in Git Settings to create a remote.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if createRemote {
                        Picker("Account", selection: $selectedHost) {
                            ForEach(store.accounts) { Text("\($0.username)@\($0.host)").tag($0.host) }
                        }
                        Toggle("Private", isOn: $isPrivate)
                        Text("Creates the repository on the service and pushes the first commit.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if busy {
                    ProgressView().controlSize(.small)
                    Text("Creating…").foregroundStyle(.secondary)
                }
                Spacer()
                if busy {
                    // Creating with a remote ends in a push, which can hang on
                    // an unreachable host. Cancelling removes the half-made repo.
                    Button("Stop", role: .cancel) { git.cancelCreate() }
                } else {
                    Button("Create") { create() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canCreate)
                }
            }
            .padding()
        }
        .frame(width: 460, height: 440)
        .onAppear { if selectedHost.isEmpty { selectedHost = store.accounts.first?.host ?? "" } }
        #if os(iOS)
        // The Mac opens an NSOpenPanel; iPad presents the document
        // picker, which is the same question asked the platform's way.
        .sheet(isPresented: $showFolderPicker) {
            FolderPicker(startingAt: nil) { urls in
                showFolderPicker = false
                if let first = urls.first { parent = first }
            }
        }
        #endif
    }

    private var canCreate: Bool {
        !busy && !name.trimmingCharacters(in: .whitespaces).isEmpty && parent != nil
            && (!createRemote || !selectedHost.isEmpty)
    }

    private func chooseParent() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where to create the repository folder."
        if panel.runModal() == .OK { parent = panel.url }
        #else
        showFolderPicker = true
        #endif
    }

    private func create() {
        guard let parent else { return }
        busy = true
        error = nil
        Task {
            var remoteURL: URL?
            var account: GitAccount?
            var token: String?

            if createRemote, let acct = store.account(forHost: selectedHost),
               let tok = GitKeychain.token(forHost: acct.host) {
                do {
                    let repo = try await GitHostAPI.createRepository(
                        named: name.trimmingCharacters(in: .whitespaces), isPrivate: isPrivate, for: acct, token: tok)
                    remoteURL = URL(string: repo.cloneURL)
                    account = acct
                    token = tok
                } catch {
                    self.error = error.localizedDescription
                    busy = false
                    return
                }
            }

            let created = await git.createRepository(
                named: name, in: parent, remoteURL: remoteURL, account: account, token: token)
            busy = false
            if let created {
                onCreated(created)
                dismiss()
            } else {
                error = git.lastError ?? "Couldn't create the repository."
            }
        }
    }
}
