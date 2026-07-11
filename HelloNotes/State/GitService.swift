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
    struct RepoStatus: Equatable, Sendable {
        var isRepository = false
        var branch: String?
        var changeCount = 0
        var isClean: Bool { changeCount == 0 }
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
            return RepoStatus(isRepository: true, branch: branch, changeCount: entries.count)
        }.value
    }
}

extension GitService {
    /// Ensure the repository has a commit identity. `git_commit_create_from_stage`
    /// (used by SwiftGitX's `commit`) needs a default signature from config; a
    /// GUI-launched app doesn't always resolve the global `~/.gitconfig`, so we
    /// copy the global identity into the repo's local config, falling back to a
    /// generic identity when none is available.
    nonisolated static func ensureCommitIdentity(_ repo: Repository) {
        let hasName = ((try? repo.config.string(forKey: "user.name")) ?? nil) != nil
        let hasEmail = ((try? repo.config.string(forKey: "user.email")) ?? nil) != nil
        guard !hasName || !hasEmail else { return }

        let globalName = (try? Repository.config.string(forKey: "user.name")) ?? nil
        let globalEmail = (try? Repository.config.string(forKey: "user.email")) ?? nil

        // Fall back to the macOS account identity when git has no configured one.
        let fallbackName = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
        let fallbackEmail = "\(NSUserName())@localhost"

        try? repo.config.set("user.name", to: globalName ?? fallbackName)
        try? repo.config.set("user.email", to: globalEmail ?? fallbackEmail)
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
