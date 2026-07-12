//
//  GitSettingsView.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//

#if os(macOS)
import SwiftUI

/// Manage the Git commit identity, connected hosting accounts (GitHub, GitLab,
/// …), and this collection's remote.
struct GitSettingsView: View {
    @Bindable var store: GitAccountsStore
    @Bindable var git: GitService

    @Environment(\.dismiss) private var dismiss

    // Add-account form state
    @State private var newService: GitHostService = .github
    @State private var newHost = "github.com"
    @State private var newUsername = ""
    @State private var newToken = ""

    // Connect-remote state
    @State private var remoteURL = ""
    @State private var remoteAccountHost = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Git Settings", systemImage: "arrow.triangle.branch").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            Form {
                identitySection
                accountsSection
                if git.status.isRepository { remoteSection }
            }
            .formStyle(.grouped)
        }
        .frame(width: 540, height: 620)
    }

    // MARK: - Identity

    private var identitySection: some View {
        Section("Commit identity") {
            TextField("Name", text: $store.identityName, prompt: Text("Ada Lovelace"))
            TextField("Email", text: $store.identityEmail, prompt: Text("ada@example.com"))
            Text("Used as the author of commits this app makes. Overrides your global git config for this collection.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Accounts

    private var accountsSection: some View {
        Section("Accounts") {
            if store.accounts.isEmpty {
                Text("No accounts yet. Add one to push and pull over HTTPS.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(store.accounts) { account in
                HStack {
                    Image(systemName: account.service.symbol).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.host).fontWeight(.medium)
                        Text("\(account.service.displayName) · \(account.username.isEmpty ? "token" : account.username)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { store.remove(account) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }

            DisclosureGroup("Add an account") {
                Picker("Service", selection: $newService) {
                    ForEach(GitHostService.allCases) { Text($0.displayName).tag($0) }
                }
                .onChange(of: newService) { _, s in if !s.defaultHost.isEmpty { newHost = s.defaultHost } }

                TextField("Host", text: $newHost, prompt: Text("github.com"))
                TextField("Username", text: $newUsername, prompt: Text("your-username"))
                SecureField("Personal access token", text: $newToken)

                HStack(spacing: 10) {
                    if let url = newService.tokenPageURL {
                        Link(destination: url) { Label("Create a token", systemImage: "arrow.up.right.square") }
                            .font(.caption)
                    }
                    Text(newService.scopeHint).font(.caption).foregroundStyle(.secondary)
                }

                Button("Save Account") {
                    store.save(service: newService, host: newHost, username: newUsername, token: newToken)
                    newUsername = ""; newToken = ""
                }
                .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty
                    || newToken.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Remote

    private var remoteSection: some View {
        Section("This collection's remote") {
            ForEach(git.status.remotes) { remote in
                HStack {
                    Image(systemName: remote.hasEmbeddedCredentials ? "lock.fill" : "link")
                        .foregroundStyle(remote.hasEmbeddedCredentials ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(remote.name).fontWeight(.medium)
                        Text(remote.displayURL).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if !remote.hasEmbeddedCredentials, let host = remote.host,
                       let account = store.account(forHost: host),
                       let token = GitKeychain.token(forHost: host) {
                        Button("Authenticate") {
                            Task { await git.authenticateRemote(remote.name, account: account, token: token) }
                        }
                        .font(.caption)
                    }
                    Button(role: .destructive) { Task { await git.removeRemote(remote.name) } } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }

            if git.status.remotes.isEmpty {
                Text("No remote yet. Add one to sync this collection to a hosting service.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Remote URL", text: $remoteURL, prompt: Text("https://github.com/you/notes.git"))
                if !store.accounts.isEmpty {
                    Picker("Authenticate with", selection: $remoteAccountHost) {
                        Text("None (public / SSH)").tag("")
                        ForEach(store.accounts) { Text($0.host).tag($0.host) }
                    }
                }
                Button("Add Remote") {
                    let account = store.account(forHost: remoteAccountHost)
                    let token = account.flatMap { GitKeychain.token(forHost: $0.host) }
                    Task { await git.connectRemote(urlString: remoteURL, account: account, token: token) }
                }
                .disabled(remoteURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
#endif
