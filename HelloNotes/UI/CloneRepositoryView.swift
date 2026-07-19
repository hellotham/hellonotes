//
//  CloneRepositoryView.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Browse a connected account's repositories (or paste any clone URL), choose a
//  destination folder, and clone. On success the cloned folder is handed back to
//  open as the collection.
//

#if os(macOS)
import SwiftUI
import AppKit

struct CloneRepositoryView: View {
    @Bindable var store: GitAccountsStore
    @Bindable var git: GitService

    /// Called with the cloned folder's URL so the caller can open it as a collection.
    var onCloned: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectedHost = ""          // "" = no account (public / manual)
    @State private var repos: [RemoteRepository] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var filter = ""
    @State private var repoURL = ""               // the URL that will be cloned

    private var filteredRepos: [RemoteRepository] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return repos }
        return repos.filter {
            $0.fullName.lowercased().contains(q) || ($0.description?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Clone Repository", systemImage: "arrow.down.circle").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()

            Form {
                if store.accounts.isEmpty {
                    Section {
                        Text("No accounts connected. Paste a public repository URL below, or add an account in Git Settings to browse your private repositories.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    browseSection
                }
                urlSection
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(width: 560, height: 640)
    }

    // MARK: - Browse

    private var browseSection: some View {
        Section("Browse your repositories") {
            Picker("Account", selection: $selectedHost) {
                Text("None").tag("")
                ForEach(store.accounts) { Text($0.host).tag($0.host) }
            }
            .onChange(of: selectedHost) { _, _ in loadRepositories() }

            if isLoading {
                HStack { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }
            } else if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            } else if !selectedHost.isEmpty {
                if repos.isEmpty {
                    Text("No repositories found for this account.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("Filter", text: $filter, prompt: Text("Filter repositories"))
                        .textFieldStyle(.roundedBorder)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredRepos) { repo in repoRow(repo) }
                        }
                    }
                    .frame(height: 240)
                }
            }
        }
    }

    private func repoRow(_ repo: RemoteRepository) -> some View {
        let selected = repoURL == repo.cloneURL
        return Button {
            repoURL = repo.cloneURL
        } label: {
            HStack(spacing: 8) {
                Image(systemName: repo.isPrivate ? "lock.fill" : "book.closed")
                    .foregroundStyle(repo.isPrivate ? Color.orange : Color.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(repo.fullName).fontWeight(.medium)
                    if let d = repo.description, !d.isEmpty {
                        Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
            }
            .padding(.vertical, 5).padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(selected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - URL + action

    private var urlSection: some View {
        Section("Repository URL") {
            TextField("URL", text: $repoURL, prompt: Text("https://github.com/you/notes.git"))
            Text("Private repositories clone using the token of the matching connected account.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            if git.isBusy {
                ProgressView().controlSize(.small)
                Text("Cloning…").foregroundStyle(.secondary)
            } else if let error = git.lastError {
                Label(error, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            Spacer()
            Button {
                clone()
            } label: {
                Label("Clone…", systemImage: "arrow.down.circle")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(repoURL.trimmingCharacters(in: .whitespaces).isEmpty || git.isBusy)
        }
        .padding()
    }

    // MARK: - Logic

    private func loadRepositories() {
        repos = []; loadError = nil; filter = ""
        guard let account = store.account(forHost: selectedHost),
              let token = GitKeychain.token(forHost: account.host) else {
            if !selectedHost.isEmpty { loadError = "No stored token for this account." }
            return
        }
        isLoading = true
        let requestedHost = selectedHost
        Task {
            // Guard against an account-switch race: two rapid switches leave two
            // in-flight loads, and a slow earlier one could overwrite `repos` for
            // the account no longer selected. Drop results for a stale host.
            do {
                let result = try await GitHostAPI.repositories(for: account, token: token)
                guard requestedHost == selectedHost else { return }
                repos = result.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
                isLoading = false
            } catch {
                guard requestedHost == selectedHost else { return }
                loadError = (error as? GitHostAPI.APIError)?.errorDescription ?? error.localizedDescription
                isLoading = false
            }
        }
    }

    private func clone() {
        let urlString = repoURL.trimmingCharacters(in: .whitespaces)
        guard let parent = chooseDestinationFolder() else { return }

        // Authenticate with an account matching the URL's host, if we have one.
        let host = URL(string: urlString).flatMap { GitRemoteURL.host(of: $0) } ?? ""
        let account = store.account(forHost: host)
        let token = account.flatMap { GitKeychain.token(forHost: $0.host) }

        Task {
            let started = parent.startAccessingSecurityScopedResource()
            if let cloned = await git.cloneRepository(from: urlString, into: parent, account: account, token: token) {
                onCloned(cloned)   // hands the URL onward; scope kept for the app's lifetime
                dismiss()
            } else if started {
                parent.stopAccessingSecurityScopedResource()   // balance the scope on failure/cancel
            }
        }
    }

    /// Ask the user where to put the clone. The returned folder is the *parent*;
    /// the repository is cloned into a subfolder named after the repo.
    private func chooseDestinationFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Clone Here"
        panel.message = "Choose the folder to clone the repository into."
        return panel.runModal() == .OK ? panel.url : nil
    }
}
#endif
