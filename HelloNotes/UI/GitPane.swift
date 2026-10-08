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
//  one thing that was is `.toggleStyle(.checkbox)`, which is macOS-only; the
//  toggle is the app's own switch now (`chromeDefaults`), the same control on
//  both.
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
            Text("GIT").font(Chrome.Style.caption2).foregroundStyle(Chrome.Colour.secondaryLabel)
            Spacer()
            if git.isBusy { ProgressView().controlSize(.small) }
            // A push can wait on the network for as long as the network
            // likes; Clone and Create have always had a way out, and this is
            // Push's (`GitService.cancelPush`).
            if git.isPushing {
                Button("Stop") { git.cancelPush() }
                    .buttonStyle(ChromeBorderlessStyle())
                    .help("Stop pushing")
            }
            Button(action: showSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(ChromeBorderlessStyle())
            .accessibilityLabel("Git identity & accounts")
        }

        // Git-on-cloud guardrail: libgit2 reads the whole object store, so a
        // repo whose objects are online-only thrashes (and coordinated access
        // isn't wired through libgit2). Warn, and keep auto-commit off in a
        // cloud folder.
        if let provider = CloudProvider.name(for: collection.rootURL) {
            Label("In \(provider). Git works best when the folder is fully downloaded — online-only files can slow or break operations.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(Chrome.Style.caption2)
                .foregroundStyle(Chrome.Colour.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        if !git.status.isRepository {
            Text("Not a Git repository")
                .font(Chrome.Style.caption)
                .foregroundStyle(Chrome.Colour.secondaryLabel)
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
                    .font(Chrome.Style.caption)
                    .lineLimit(1)
                Spacer()
                Text(git.status.isClean ? "Clean" : "\(git.status.changeCount) changed")
                    .font(Chrome.Style.caption)
                    .foregroundStyle(git.status.isClean ? Chrome.Colour.secondaryLabel : Chrome.Colour.orange)
            }

            // This collection is only part of its repository — say where the
            // repository starts, and that everything here is confined to this
            // folder. Offering full Git controls without naming the wider repo
            // is how someone ends up surprised by what a commit contained.
            if git.status.isSubdirectory, let repoRoot = git.status.repositoryRoot {
                Text("Inside the repository at \(repoRoot.path(percentEncoded: false)) — commits, counts and history cover only this folder.")
                    .font(Chrome.Style.caption2)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
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
                    // The app's pull-down beside the app's push button — a
                    // `Menu`'s face is the platform's. What drops from it is
                    // still the OS's menu.
                    ChromePullDown("Sync", systemImage: "arrow.triangle.2.circlepath") {
                        Button("Push") { Task { await git.push() } }
                        Button("Fetch") { Task { await git.fetch() } }
                    }
                    .disabled(git.isBusy)
                } else {
                    Button(action: showSettings) {
                        Label("Connect Remote", systemImage: "link.badge.plus")
                    }
                    .fixedSize()
                }
            }

            let cloudBacked = CloudProvider.name(for: collection.rootURL) != nil
            let partOfLargerRepo = git.status.isSubdirectory
            // The app's switch, as every toggle is. `.toggleStyle(.checkbox)` is
            // macOS-only and was one of the reasons this pane could not move.
            Toggle("Auto-commit", isOn: $autoCommit)
                .font(Chrome.Style.caption)
                .disabled(cloudBacked || partOfLargerRepo)
            if cloudBacked {
                Text("Auto-commit is off in cloud folders — commit manually once files are downloaded.")
                    .font(Chrome.Style.caption2)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            } else if partOfLargerRepo {
                Text("Auto-commit is off inside a larger repository — commit this folder yourself when you're ready.")
                    .font(Chrome.Style.caption2)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = git.lastError {
                Text(error)
                    .font(Chrome.Style.caption2)
                    .foregroundStyle(Chrome.Colour.red)
                    .lineLimit(4)
                    .textSelection(.enabled)
            } else if let message = git.lastMessage {
                Text(message)
                    .font(Chrome.Style.caption2)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                    .lineLimit(1)
            }
        }
    }
}
