//
//  GitPushTests.swift
//  HelloNotesTests
//
//  Push, and Push's Stop, against a real remote: a bare repository in the
//  temporary directory, reached over libgit2's local transport.
//
//  SwiftGitX's push gave libgit2 no callback, so nothing could stop it and the
//  Git pane spun until the network gave up. `GitPush` is the same push with
//  callbacks that answer "stop" once the task is cancelled.
//

import Foundation
import libgit2
import SwiftGitX
import Testing
@testable import HelloNotes

@Suite(.serialized)
@MainActor
struct GitPushTests {

    /// A repository holding one committed note, with `origin` pointing at an
    /// empty bare repository beside it.
    private func repositories() throws -> (base: URL, local: URL, remote: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("hn-push-\(UUID().uuidString)", isDirectory: true)
        let local = base.appendingPathComponent("local", isDirectory: true)
        let remote = base.appendingPathComponent("remote.git", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)

        git_libgit2_init()
        defer { git_libgit2_shutdown() }
        var bare: OpaquePointer?
        try #require(git_repository_init(&bare, remote.path, 1) == 0, "could not make the bare remote")
        git_repository_free(bare)

        let repository = try Repository(at: local, createIfNotExists: true)
        GitService.ensureCommitIdentity(repository)
        try Data("# Note\n".utf8).write(to: local.appendingPathComponent("Note.md"))
        try repository.add(path: "Note.md")
        _ = try repository.commit(message: "First")
        try repository.remote.add(named: "origin", at: remote)
        return (base, local, remote)
    }

    /// The commit `reference` names in the repository at `url`, or nil.
    private func commit(_ reference: String, in url: URL) -> String? {
        git_libgit2_init()
        defer { git_libgit2_shutdown() }
        var repository: OpaquePointer?
        guard git_repository_open(&repository, url.path) == 0 else { return nil }
        defer { git_repository_free(repository) }
        var oid = git_oid()
        guard git_reference_name_to_id(&oid, repository, reference) == 0,
              let text = git_oid_tostr_s(&oid) else { return nil }
        return String(cString: text)
    }

    /// The branch HEAD is on, as a full reference name.
    private func branch(in url: URL) throws -> String {
        git_libgit2_init()
        defer { git_libgit2_shutdown() }
        var repository: OpaquePointer?
        try #require(git_repository_open(&repository, url.path) == 0)
        defer { git_repository_free(repository) }
        var head: OpaquePointer?
        try #require(git_repository_head(&head, repository) == 0)
        defer { git_reference_free(head) }
        return String(cString: try #require(git_reference_name(head)))
    }

    @Test func aPushReachesTheRemote() throws {
        let (base, local, remote) = try repositories()
        defer { try? FileManager.default.removeItem(at: base) }
        let branch = try branch(in: local)

        try GitPush.push(repositoryAt: local)
        let pushed = try #require(commit(branch, in: remote), "the remote has no \(branch)")
        #expect(pushed == commit("HEAD", in: local))
    }

    /// Stopped at libgit2's first callback: the pack is never sent and the
    /// remote's branch is never written.
    @Test func aCancelledPushStopsAndSaysSo() async throws {
        let (base, local, remote) = try repositories()
        defer { try? FileManager.default.removeItem(at: base) }
        let branch = try branch(in: local)

        let failure = await Task.detached { () -> GitPush.Failure? in
            withUnsafeCurrentTask { $0?.cancel() }
            do { try GitPush.push(repositoryAt: local); return nil }
            catch { return error as? GitPush.Failure }
        }.value
        #expect(failure == .cancelled)
        #expect(commit(branch, in: remote) == nil, "a cancelled push wrote the remote's branch")
    }

    /// The pane's Push, through the service: it reports what happened and is
    /// no longer pushing afterwards.
    @Test func theServicePushesAndSaysSo() async throws {
        let (base, local, remote) = try repositories()
        defer { try? FileManager.default.removeItem(at: base) }
        let branch = try branch(in: local)

        let git = GitService()
        git.rootURL = local
        await git.refreshStatus()
        await git.push()
        #expect(git.lastError == nil)
        #expect(git.lastMessage == "Pushed to remote")
        #expect(git.isPushing == false && git.isBusy == false)
        #expect(commit(branch, in: remote) == commit("HEAD", in: local))
    }
}

/// What a commit is signed with when nothing names the person.
struct GitIdentityTests {
    /// The iOS simulator's account has no name, and a commit signed with an
    /// empty one is refused by libgit2 — "Signature cannot have an empty name
    /// or email" — so every commit failed there.
    @Test func anAccountWithNoNameStillSignsACommit() {
        let identity = GitService.fallbackIdentity(fullName: "", userName: "")
        #expect(!identity.name.isEmpty && !identity.email.hasPrefix("@"), "\(identity)")
        #expect(GitService.fallbackIdentity(fullName: "Ada Lovelace", userName: "ada") == ("Ada Lovelace", "ada@localhost"))
        #expect(GitService.fallbackIdentity(fullName: "", userName: "ada") == ("ada", "ada@localhost"))
    }
}
