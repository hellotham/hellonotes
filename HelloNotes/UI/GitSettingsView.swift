//
//  GitSettingsView.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//

// **Not macOS-only.** This file was `#if os(macOS)` and used no AppKit and
// no Mac-only API — the gate was the only thing keeping it off iPad.
import SwiftUI

/// Manage the Git commit identity, connected hosting accounts (GitHub, GitLab,
/// …), and this collection's remote.
///
/// **A page, with no bar of its own.** Settings names it in its tab strip and
/// owns the way out; the sheet a collection's Git pane opens puts a bar above
/// it (`ContentView`). It used to draw a header on the Mac and borrow a
/// navigation bar on iOS — two ways of saying one thing, which is how one
/// screen came to be called "Git Settings" on one platform and "Git" on the
/// other.
struct GitSettingsView: View {
    @Bindable var store: GitAccountsStore
    @Bindable var git: GitService

    @Environment(\.openURL) private var openURL

    // Add-account form state
    @State private var newService: GitHostService = .github
    @State private var newHost = "github.com"
    @State private var newUsername = ""
    @State private var newToken = ""

    // Connect-remote state
    @State private var remoteURL = ""
    @State private var remoteAccountHost = ""

    var body: some View {
        ChromeForm {
            identitySection
            accountsSection
            if git.status.isRepository { remoteSection }
        }
    }

    // MARK: - Identity

    private var identitySection: some View {
        ChromeSection("Commit identity") {
            LabeledField(label: "Name", text: $store.identityName, prompt: "Ada Lovelace")
            LabeledField(label: "Email", text: $store.identityEmail, prompt: "ada@example.com")
            Text("Used as the author of commits this app makes. Overrides your global git config for this collection.")
                .font(Chrome.Style.caption).foregroundStyle(Chrome.Colour.secondaryLabel)
        }
    }

    // MARK: - Accounts

    private var accountsSection: some View {
        ChromeSection("Accounts") {
            if store.accounts.isEmpty {
                Text("No accounts yet. Add one to push and fetch over HTTPS.")
                    .font(Chrome.Style.caption).foregroundStyle(Chrome.Colour.secondaryLabel)
            }
            ForEach(store.accounts) { account in
                HStack {
                    Image(systemName: account.service.symbol).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.host).fontWeight(.medium)
                        Text("\(account.service.displayName) · \(account.username.isEmpty ? "token" : account.username)")
                            .font(Chrome.Style.caption).foregroundStyle(Chrome.Colour.secondaryLabel)
                    }
                    Spacer()
                    Button(role: .destructive) { store.remove(account) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(ChromeBorderlessStyle())
                }
            }

            DisclosureGroup("Add an account") {
                // Spaced as rows: the group's own stack sets its content 4pt
                // apart.
                VStack(alignment: .leading, spacing: 10) {
                    ChromePopUp("Service", selection: $newService,
                                options: GitHostService.allCases.map { ChromeOption(value: $0, title: $0.displayName) })
                        .onChange(of: newService) { _, s in if !s.defaultHost.isEmpty { newHost = s.defaultHost } }

                    LabeledField(label: "Host", text: $newHost, prompt: "github.com", isPath: true)
                    LabeledField(label: "Username", text: $newUsername, prompt: "your-username", isPath: true)
                    tokenField

                    HStack(spacing: 10) {
                        if let url = newService.tokenPageURL {
                            Button { openURL(url) } label: {
                                Label("Create a token", systemImage: "arrow.up.right.square")
                            }
                            .buttonStyle(ChromeLinkStyle())
                            .accessibilityAddTraits(.isLink)
                            .font(Chrome.Style.caption)
                        }
                        Text(newService.scopeHint).font(Chrome.Style.caption).foregroundStyle(Chrome.Colour.secondaryLabel)
                    }

                    Button("Save Account") {
                        store.save(service: newService, host: newHost, username: newUsername, token: newToken)
                        newUsername = ""; newToken = ""
                    }
                    .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty
                        || newToken.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.top, 6)
            }
        }
    }

    /// The token, in the same row as every other field here — its name on the
    /// left, the typing on the right, the placeholder drawn by the app — but
    /// secure, which `LabeledField` is not.
    private var tokenField: some View {
        LabeledContent("Personal access token") {
            SecureField("", text: $newToken)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Chrome.Colour.label)
                .focusEffectDisabled()
                .chromePlaceholder("Required", showing: newToken.isEmpty, alignment: .trailing)
                .accessibilityLabel("Personal access token")
        }
    }

    // MARK: - Remote

    private var remoteSection: some View {
        ChromeSection("This collection's remote") {
            ForEach(git.status.remotes) { remote in
                HStack {
                    Image(systemName: remote.hasEmbeddedCredentials ? "lock.fill" : "link")
                        .foregroundStyle(remote.hasEmbeddedCredentials ? Chrome.Colour.green : Chrome.Colour.secondaryLabel)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(remote.name).fontWeight(.medium)
                        Text(remote.displayURL).font(Chrome.Style.caption).foregroundStyle(Chrome.Colour.secondaryLabel).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if !remote.hasEmbeddedCredentials, let host = remote.host,
                       let account = store.account(forHost: host),
                       let token = GitKeychain.token(forHost: host) {
                        Button("Authenticate") {
                            Task { await git.authenticateRemote(remote.name, account: account, token: token) }
                        }
                        .controlSize(.small)
                    }
                    Button(role: .destructive) { Task { await git.removeRemote(remote.name) } } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(ChromeBorderlessStyle())
                }
            }

            if git.status.remotes.isEmpty {
                Text("No remote yet. Add one to sync this collection to a hosting service.")
                    .font(Chrome.Style.caption).foregroundStyle(Chrome.Colour.secondaryLabel)
                LabeledField(label: "Remote URL", text: $remoteURL, prompt: "https://github.com/you/notes.git", isPath: true)
                if !store.accounts.isEmpty {
                    ChromePopUp("Authenticate with", selection: $remoteAccountHost, options: remoteAccountOptions)
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

    /// No account, or one of the saved ones — by host, which is what an
    /// account is looked up by (`GitAccountsStore.account(forHost:)`).
    private var remoteAccountOptions: [ChromeOption<String>] {
        [ChromeOption(value: "", title: "None (public / SSH)")]
            + store.accounts.map { ChromeOption(value: $0.host, title: $0.host) }
    }
}
