//
//  GitService.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import Foundation
import Observation
import SwiftGitX

/// Observable Git state + operations for the vault, backed by SwiftGitX
/// (libgit2). Blocking libgit2 calls run off the main actor; observable state
/// is published back on it.
///
/// Safety by design: the vault is only turned into a repository on an explicit
/// `initializeRepository()` call, and pushing to a remote is only ever a
/// user-initiated action — nothing here pushes automatically.
@MainActor
@Observable
final class GitService {
    struct RemoteInfo: Equatable, Sendable, Identifiable {
        var id: String { name }
        var name: String
        var displayURL: String        // credentials stripped
        var host: String?
        var hasEmbeddedCredentials: Bool
    }

    struct RepoStatus: Equatable, Sendable {
        var isRepository = false
        var branch: String?
        var changeCount = 0
        var remotes: [RemoteInfo] = []
        var isClean: Bool { changeCount == 0 }
        var hasRemote: Bool { !remotes.isEmpty }
    }

    private(set) var status = RepoStatus()
    private(set) var isBusy = false
    private(set) var lastError: String?
    private(set) var lastMessage: String?

    /// The vault whose repository this service manages.
    var vaultURL: URL?

    private var autoCommitTask: Task<Void, Never>?

    // MARK: - Status

    func refreshStatus() async {
        guard let url = vaultURL else { status = RepoStatus(); return }
        status = await Self.readStatus(at: url)
    }

    // MARK: - Operations

    /// Turn the vault into a Git repository (explicit user action only).
    func initializeRepository() async {
        guard let url = vaultURL else { return }
        await run(success: "Initialized empty Git repository") {
            let repo = try Repository(at: url, createIfNotExists: true)
            Self.ensureCommitIdentity(repo)
        }
    }

    /// Stage all changes and create a local commit.
    func commitAll(message: String) async {
        guard let url = vaultURL else { return }
        await run(success: "Committed changes") {
            let repo = try Repository.open(at: url)
            Self.ensureCommitIdentity(repo)
            let entries = try repo.status()
            let paths = Set(entries.compactMap { $0.workingTree?.newFile.path ?? $0.index?.newFile.path })
            guard !paths.isEmpty else { throw GitServiceError.nothingToCommit }
            for path in paths { try? repo.add(path: path) }
            _ = try repo.commit(message: message)
        }
    }

    /// Push the current branch to its remote (user-initiated only).
    func push() async {
        guard let url = vaultURL else { return }
        await run(success: "Pushed to remote") {
            let repo = try Repository.open(at: url)
            try await repo.push()
        }
    }

    /// Fetch remote refs (SwiftGitX has no merge yet, so this doesn't pull).
    func fetch() async {
        guard let url = vaultURL else { return }
        await run(success: "Fetched from remote") {
            let repo = try Repository.open(at: url)
            try await repo.fetch()
        }
    }

    // MARK: - Note history

    /// One commit in a note's history — a version the user can preview / restore.
    struct NoteRevision: Identifiable, Hashable, Sendable {
        let id: String          // full commit hex (identity + lookup key)
        let shortID: String     // abbreviated hex for display
        let summary: String
        let authorName: String
        let date: Date
    }

    /// The commits that changed `fileURL` (its blob differs from the parent's),
    /// newest first. Empty when the vault isn't a repo or the file is untracked.
    /// Walks at most `scan` commits so large histories stay responsive.
    func history(for fileURL: URL, scan: Int = 300) async -> [NoteRevision] {
        guard let vaultURL, let relPath = Self.relativePath(of: fileURL, in: vaultURL) else { return [] }
        return await Task.detached(priority: .userInitiated) {
            guard let repo = try? Repository.open(at: vaultURL),
                  let commits = try? repo.log() else { return [] }
            let components = relPath.split(separator: "/").map(String.init)

            var revisions: [NoteRevision] = []
            var walked = 0
            for commit in commits {
                guard walked < scan else { break }
                walked += 1

                guard let tree = try? commit.tree else { continue }
                let current = Self.entryOID(at: components, in: tree, repo: repo)
                guard current != nil else { continue }

                let parentOID: OID?
                if let parent = (try? commit.parents)?.first, let parentTree = try? parent.tree {
                    parentOID = Self.entryOID(at: components, in: parentTree, repo: repo)
                } else {
                    parentOID = nil
                }

                if current != parentOID {
                    revisions.append(NoteRevision(
                        id: commit.id.hex,
                        shortID: commit.id.abbreviated,
                        summary: commit.summary,
                        authorName: commit.author.name,
                        date: commit.date
                    ))
                }
            }
            return revisions
        }.value
    }

    /// The UTF-8 contents of `fileURL` as of commit `revisionID`, or nil if it
    /// can't be resolved.
    func content(ofRevision revisionID: String, for fileURL: URL) async -> String? {
        guard let vaultURL, let relPath = Self.relativePath(of: fileURL, in: vaultURL) else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> String? in
            guard let repo = try? Repository.open(at: vaultURL),
                  let oid = try? OID(hex: revisionID),
                  let commit: Commit = try? repo.show(id: oid),
                  let tree = try? commit.tree else { return nil }
            let components = relPath.split(separator: "/").map(String.init)
            guard let blobOID = Self.entryOID(at: components, in: tree, repo: repo),
                  let blob: Blob = try? repo.show(id: blobOID) else { return nil }
            return String(data: blob.content, encoding: .utf8)
        }.value
    }

    /// The blob OID at a slash-separated path within `tree`, walking subtrees.
    /// Returns nil if any component is missing or the leaf isn't a file.
    private nonisolated static func entryOID(at components: [String], in tree: Tree, repo: Repository) -> OID? {
        guard let first = components.first,
              let entry = tree.entries.first(where: { $0.name == first }) else { return nil }
        if components.count == 1 {
            return entry.type == .blob ? entry.id : nil
        }
        guard entry.type == .tree, let subtree: Tree = try? repo.show(id: entry.id) else { return nil }
        return entryOID(at: Array(components.dropFirst()), in: subtree, repo: repo)
    }

    /// `fileURL` expressed relative to the vault root, using forward slashes, or
    /// nil if it isn't inside the vault.
    private nonisolated static func relativePath(of fileURL: URL, in vaultURL: URL) -> String? {
        let file = fileURL.standardizedFileURL.path
        var base = vaultURL.standardizedFileURL.path
        if !base.hasSuffix("/") { base += "/" }
        guard file.hasPrefix(base) else { return nil }
        return String(file.dropFirst(base.count))
    }

    /// Debounced local auto-commit; only ever commits, never pushes.
    func scheduleAutoCommit(message: String) {
        autoCommitTask?.cancel()
        autoCommitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.commitAll(message: message)
        }
    }

    // MARK: - Private

    private func run(success: String, _ operation: @escaping @Sendable () async throws -> Void) async {
        isBusy = true
        lastError = nil
        defer { isBusy = false }

        do {
            try await Task.detached(priority: .userInitiated) {
                try await operation()
            }.value
            lastMessage = success
        } catch let error as GitServiceError {
            lastMessage = error.localizedDescription
        } catch {
            lastError = "\(error)"
            lastMessage = nil
        }

        await refreshStatus()
    }

    private static func readStatus(at url: URL) async -> RepoStatus {
        await Task.detached(priority: .utility) {
            guard let repo = try? Repository.open(at: url) else {
                return RepoStatus(isRepository: false)
            }
            let entries = (try? repo.status()) ?? []
            let branch = try? repo.branch.current.name
            let remotes = ((try? repo.remote.list()) ?? []).map { remote in
                RemoteInfo(
                    name: remote.name,
                    displayURL: GitRemoteURL.sanitized(remote.url).absoluteString,
                    host: GitRemoteURL.host(of: remote.url),
                    hasEmbeddedCredentials: remote.url.password != nil
                )
            }
            return RepoStatus(isRepository: true, branch: branch, changeCount: entries.count, remotes: remotes)
        }.value
    }

    // MARK: - Remotes

    /// Add or replace a remote (default `origin`). When `account`/`token` are
    /// supplied for an HTTPS URL, the token is embedded so push/fetch authenticate.
    func connectRemote(urlString: String, name: String = "origin",
                       account: GitAccount? = nil, token: String? = nil) async {
        guard let vaultURL else { return }
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)
        guard let baseURL = URL(string: trimmed), baseURL.scheme != nil else {
            lastError = "Enter a valid remote URL (https://…)."
            return
        }
        let finalURL: URL = {
            if let account, let token, let authed = GitRemoteURL.authenticated(baseURL, username: account.username, token: token) {
                return authed
            }
            return baseURL
        }()
        await run(success: "Connected remote “\(name)”") {
            let repo = try Repository.open(at: vaultURL)
            if let existing = try? repo.remote.get(named: name) {
                try repo.remote.remove(existing)
            }
            try repo.remote.add(named: name, at: finalURL)
            // Best-effort: track the current branch against the new remote.
            if let branch = try? repo.branch.current,
               let upstream = try? repo.branch.get(named: "\(name)/\(branch.name)", type: .remote) {
                try? repo.branch.setUpstream(from: branch, to: upstream)
            }
        }
    }

    /// Rewrite an existing remote's URL to embed credentials from an account.
    func authenticateRemote(_ name: String, account: GitAccount, token: String) async {
        guard let vaultURL else { return }
        guard let repo = try? Repository.open(at: vaultURL),
              let remote = try? repo.remote.get(named: name) else { return }
        let base = GitRemoteURL.sanitized(remote.url)
        await connectRemote(urlString: base.absoluteString, name: name, account: account, token: token)
    }

    func removeRemote(_ name: String) async {
        guard let vaultURL else { return }
        await run(success: "Removed remote “\(name)”") {
            let repo = try Repository.open(at: vaultURL)
            if let remote = try? repo.remote.get(named: name) {
                try repo.remote.remove(remote)
            }
        }
    }

    // MARK: - Clone

    /// Clone `urlString` into a new folder under `parentDirectory` and return the
    /// cloned folder's URL (nil on failure). For a private repo, pass the
    /// `account`/`token` so the token is embedded in the clone URL — libgit2 then
    /// stores it as `origin`, so later push/fetch stay authenticated. Independent
    /// of any currently-open vault; the caller opens the result as a vault.
    func cloneRepository(from urlString: String, into parentDirectory: URL,
                         account: GitAccount? = nil, token: String? = nil) async -> URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)
        guard let baseURL = URL(string: trimmed), baseURL.scheme != nil else {
            lastError = "Enter a valid repository URL (https://…)."
            return nil
        }

        // Folder name = last path component minus a trailing ".git".
        let leaf = baseURL.lastPathComponent
        let folderName = leaf.hasSuffix(".git") ? String(leaf.dropLast(4)) : leaf
        let destination = parentDirectory.appendingPathComponent(folderName.isEmpty ? "cloned-repo" : folderName)

        // libgit2 requires the target to be absent or empty.
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: destination.path), !contents.isEmpty {
            lastError = "“\(destination.lastPathComponent)” already exists and isn't empty."
            return nil
        }

        let remoteURL: URL = {
            if let account, let token,
               let authed = GitRemoteURL.authenticated(baseURL, username: account.username, token: token) {
                return authed
            }
            return baseURL
        }()

        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            try await Task.detached(priority: .userInitiated) {
                _ = try await Repository.clone(from: remoteURL, to: destination)
            }.value
            lastMessage = "Cloned “\(folderName)”"
            return destination
        } catch {
            lastError = "Clone failed: \(error)"
            // Best-effort cleanup of a partial checkout.
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
    }
}

extension GitService {
    /// Ensure the repository has a commit identity. `git_commit_create_from_stage`
    /// (used by SwiftGitX's `commit`) needs a default signature from config; a
    /// GUI-launched app doesn't always resolve the global `~/.gitconfig`, so we
    /// copy the global identity into the repo's local config, falling back to a
    /// generic identity when none is available.
    nonisolated static func ensureCommitIdentity(_ repo: Repository) {
        // App-managed identity (set in Git Settings) always wins when present.
        let storedName = UserDefaults.standard.string(forKey: "gitUserName")?.nonEmpty
        let storedEmail = UserDefaults.standard.string(forKey: "gitUserEmail")?.nonEmpty
        if let storedName { try? repo.config.set("user.name", to: storedName) }
        if let storedEmail { try? repo.config.set("user.email", to: storedEmail) }

        let hasName = storedName != nil || ((try? repo.config.string(forKey: "user.name")) ?? nil) != nil
        let hasEmail = storedEmail != nil || ((try? repo.config.string(forKey: "user.email")) ?? nil) != nil
        guard !hasName || !hasEmail else { return }

        let globalName = (try? Repository.config.string(forKey: "user.name")) ?? nil
        let globalEmail = (try? Repository.config.string(forKey: "user.email")) ?? nil

        // Fall back to the macOS account identity when git has no configured one.
        let fallbackName = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
        let fallbackEmail = "\(NSUserName())@localhost"

        if !hasName { try? repo.config.set("user.name", to: globalName ?? fallbackName) }
        if !hasEmail { try? repo.config.set("user.email", to: globalEmail ?? fallbackEmail) }
    }
}

enum GitServiceError: LocalizedError {
    case nothingToCommit
    var errorDescription: String? {
        switch self {
        case .nothingToCommit: return "Nothing to commit."
        }
    }
}
