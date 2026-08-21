//
//  GitPane.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  Branch, change count, Commit, Push, Fetch, Initialize, auto-commit — the
//  whole of the app's Git surface, and **the iPad had none of it.**
//
//  It was 118 lines inside `MacContentView`, presented from a popover on the
//  status bar. iOS reached `GitSettingsView` (identity and accounts) and
//  `CloneRepositoryView`, so it could sign in and clone a repository and then
//  never commit to it. `GitService` itself was cross-platform the whole time.
//
//  Nothing here is platform-shaped: it is a `GitService` and some buttons. The
//  one thing that was is `.toggleStyle(.checkbox)`, which is macOS-only — the
//  platform default is the right control on each anyway.
//

import SwiftUI

struct GitPane: View {
    let collection: Collection?
    /// Show identity and accounts. The shell owns that surface, because it is a
    /// sheet on one platform and a pushed screen on the other.
    let showSettings: () -> Void

    /// Opt-in background local auto-commit (never auto-pushes). The setting is
    /// app-wide and was read only on the Mac.
    @AppStorage("gitAutoCommit") private var autoCommit = false

    /// The message a commit made from here carries.
    private var commitMessage: String { GitService.autoCommitMessage }

    var body: some View {
        if let collection {
            content(collection: collection, git: collection.git)
        }
    }

    @ViewBuilder
    private func content(collection: Collection, git: GitService) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
            Text("GIT").font(.caption2).foregroundStyle(.secondary)
            Spacer()
            if git.isBusy { ProgressView().controlSize(.small) }
            Button(action: showSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Git identity & accounts")
        }

        // Git-on-cloud guardrail: libgit2 reads the whole object store, so a
        // repo whose objects are online-only thrashes (and coordinated access
        // isn't wired through libgit2). Warn, and keep auto-commit off in a
        // cloud folder.
        if let provider = CloudProvider.name(for: collection.rootURL) {
            Label("In \(provider). Git works best when the folder is fully downloaded — online-only files can slow or break operations.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        if !git.status.isRepository {
            Text("Not a Git repository")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task { await git.initializeRepository() }
            } label: {
                Label("Initialize Repository", systemImage: "plus.circle")
            }
            .disabled(git.isBusy)
        } else {
            HStack {
                Label(git.status.branch ?? "—",
                      systemImage: "point.3.filled.connected.trianglepath.dotted")
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Text(git.status.isClean ? "Clean" : "\(git.status.changeCount) changed")
                    .font(.caption)
                    .foregroundStyle(git.status.isClean ? Color.secondary : Color.orange)
            }

            // This collection is only part of its repository — say where the
            // repository starts, and that everything here is confined to this
            // folder. Offering full Git controls without naming the wider repo
            // is how someone ends up surprised by what a commit contained.
            if git.status.isSubdirectory, let repoRoot = git.status.repositoryRoot {
                Text("Inside the repository at \(repoRoot.path(percentEncoded: false)) — commits, counts and history cover only this folder.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button {
                    Task { await git.commitAll(message: commitMessage) }
                } label: {
                    Label("Commit", systemImage: "checkmark.seal")
                }
                .disabled(git.status.isClean || git.isBusy)

                if git.status.hasRemote {
                    Menu {
                        Button("Push") { Task { await git.push() } }
                        Button("Fetch") { Task { await git.fetch() } }
                    } label: {
                        Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(git.isBusy)
                    .fixedSize()
                } else {
                    Button(action: showSettings) {
                        Label("Connect Remote", systemImage: "link.badge.plus")
                    }
                    .fixedSize()
                }
            }

            let cloudBacked = CloudProvider.name(for: collection.rootURL) != nil
            let partOfLargerRepo = git.status.isSubdirectory
            // The platform's own toggle. `.toggleStyle(.checkbox)` is macOS-only
            // and was one of the reasons this pane could not move.
            Toggle("Auto-commit", isOn: $autoCommit)
                .font(.caption)
                .disabled(cloudBacked || partOfLargerRepo)
            if cloudBacked {
                Text("Auto-commit is off in cloud folders — commit manually once files are downloaded.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if partOfLargerRepo {
                Text("Auto-commit is off inside a larger repository — commit this folder yourself when you're ready.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = git.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .textSelection(.enabled)
            } else if let message = git.lastMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
