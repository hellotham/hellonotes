//
//  GitPullTests.swift
//  HelloNotesTests
//
//  Pull, against a real remote: a bare repository in the temporary directory,
//  reached over libgit2's local transport, a copy that pushes to it as
//  another device would, and a clone of it — the copy the app pulls into.
//
//  The Git pane offered Fetch, which moved the remote's branch inside `.git`
//  and brought nothing into the notes, and no Pull (implemented.md §51.69).
//

import Foundation
import libgit2
import SwiftGitX
import Testing
@testable import HelloNotes

@Suite(.serialized)
@MainActor
struct GitPullTests {

    /// A bare remote holding one committed note, a copy that pushed it — the
    /// other device — and a clone of the remote: the copy under test.
    private func repositories() throws -> (base: URL, local: URL, other: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("hn-pull-\(UUID().uuidString)", isDirectory: true)
        let remote = base.appendingPathComponent("remote.git", isDirectory: true)
        let other = base.appendingPathComponent("other", isDirectory: true)
        let local = base.appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        git_libgit2_init()
        defer { git_libgit2_shutdown() }
        var bare: OpaquePointer?
        try #require(git_repository_init(&bare, remote.path, 1) == 0, "could not make the bare remote")
        git_repository_free(bare)

        let repository = try Repository(at: other, createIfNotExists: true)
        GitService.ensureCommitIdentity(repository)
        try repository.remote.add(named: "origin", at: remote)
        try commit("Note.md", "# Note\n", in: other, message: "First")
        try GitPush.push(repositoryAt: other, cancel: GitCancel())
        try GitFetch.clone(from: remote, to: local, cancel: GitCancel())
        return (base, local, other)
    }

    /// Write `name` in the repository at `url` and commit it.
    private func commit(_ name: String, _ text: String, in url: URL, message: String) throws {
        let repository = try Repository.open(at: url)
        GitService.ensureCommitIdentity(repository)
        try Data(text.utf8).write(to: url.appendingPathComponent(name))
        try repository.add(path: name)
        _ = try repository.commit(message: message)
    }

    /// The commit HEAD names, and how many parents it has.
    private func head(of url: URL) throws -> (id: String, parents: Int) {
        git_libgit2_init()
        defer { git_libgit2_shutdown() }
        var repository: OpaquePointer?
        try #require(git_repository_open(&repository, url.path) == 0)
        defer { git_repository_free(repository) }
        var oid = git_oid()
        try #require(git_reference_name_to_id(&oid, repository, "HEAD") == 0)
        var commit: OpaquePointer?
        try #require(git_commit_lookup(&commit, repository, &oid) == 0)
        defer { git_commit_free(commit) }
        return (String(cString: try #require(git_oid_tostr_s(&oid))), Int(git_commit_parentcount(commit)))
    }

    /// Whether the repository at `url` is mid-merge, or in any state but its
    /// ordinary one.
    private func isInTheMiddleOfSomething(_ url: URL) throws -> Bool {
        git_libgit2_init()
        defer { git_libgit2_shutdown() }
        var repository: OpaquePointer?
        try #require(git_repository_open(&repository, url.path) == 0)
        defer { git_repository_free(repository) }
        return Int(git_repository_state(repository)) != Int(GIT_REPOSITORY_STATE_NONE.rawValue)
    }

    private func text(_ name: String, in url: URL) throws -> String {
        try String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func aPullWithNothingNewIsUpToDate() throws {
        let (base, local, _) = try repositories()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(try GitPull.pull(repositoryAt: local, cancel: GitCancel()) == .upToDate)
    }

    /// **What was pushed from elsewhere reaches the notes.** A new note and a
    /// changed one, two commits, added on top.
    @Test func aPullBringsTheRemotesCommitsIntoTheNotes() throws {
        let (base, local, other) = try repositories()
        defer { try? FileManager.default.removeItem(at: base) }
        try commit("New.md", "# New\n", in: other, message: "Add New")
        try commit("Note.md", "# Note\n\nChanged on the other device.\n", in: other, message: "Change Note")
        try GitPush.push(repositoryAt: other, cancel: GitCancel())

        #expect(try GitPull.pull(repositoryAt: local, cancel: GitCancel()) == .fastForwarded(commits: 2))
        #expect(try text("New.md", in: local) == "# New\n")
        #expect(try text("Note.md", in: local) == "# Note\n\nChanged on the other device.\n")
        #expect(try head(of: local).id == head(of: other).id)
    }

    /// **Both sides committed, to different notes: they are merged.**
    @Test func aPullMergesWhenBothSidesHaveCommits() throws {
        let (base, local, other) = try repositories()
        defer { try? FileManager.default.removeItem(at: base) }
        try commit("Theirs.md", "# Theirs\n", in: other, message: "Theirs")
        try GitPush.push(repositoryAt: other, cancel: GitCancel())
        try commit("Mine.md", "# Mine\n", in: local, message: "Mine")

        #expect(try GitPull.pull(repositoryAt: local, cancel: GitCancel()) == .merged(commits: 1))
        #expect(try text("Theirs.md", in: local) == "# Theirs\n")
        #expect(try text("Mine.md", in: local) == "# Mine\n")
        #expect(try head(of: local).parents == 2, "the merge is not a merge commit")
        #expect(try !isInTheMiddleOfSomething(local))
        let status = try Repository.open(at: local).status()
        #expect(status.isEmpty, "the merge left changes behind: \(status.count)")
    }

    /// **A note changed on both sides stops the pull with nothing changed** —
    /// no conflict markers in the note, no half-merged repository.
    @Test func aPullThatWouldConflictChangesNothing() throws {
        let (base, local, other) = try repositories()
        defer { try? FileManager.default.removeItem(at: base) }
        try commit("Note.md", "# Note\n\nTheirs.\n", in: other, message: "Theirs")
        try GitPush.push(repositoryAt: other, cancel: GitCancel())
        try commit("Note.md", "# Note\n\nMine.\n", in: local, message: "Mine")
        let before = try head(of: local)

        #expect(throws: GitPull.Failure.conflicts(["Note.md"])) {
            try GitPull.pull(repositoryAt: local, cancel: GitCancel())
        }
        #expect(try text("Note.md", in: local) == "# Note\n\nMine.\n")
        #expect(try head(of: local).id == before.id)
        #expect(try !isInTheMiddleOfSomething(local))
    }

    /// **A change not yet committed is never written over**: the pull stops
    /// before writing anything, and says which note.
    @Test func aPullThatWouldWriteOverUncommittedWorkChangesNothing() throws {
        let (base, local, other) = try repositories()
        defer { try? FileManager.default.removeItem(at: base) }
        try commit("Note.md", "# Note\n\nTheirs.\n", in: other, message: "Theirs")
        try GitPush.push(repositoryAt: other, cancel: GitCancel())
        try Data("# Note\n\nTyped here, not committed.\n".utf8).write(to: local.appendingPathComponent("Note.md"))
        let before = try head(of: local)

        #expect(throws: GitPull.Failure.uncommittedChanges(["Note.md"])) {
            try GitPull.pull(repositoryAt: local, cancel: GitCancel())
        }
        #expect(try text("Note.md", in: local) == "# Note\n\nTyped here, not committed.\n")
        #expect(try head(of: local).id == before.id)
    }

    /// **Uncommitted work in a note the pull does not touch is kept.**
    @Test func uncommittedWorkElsewhereSurvivesAPull() throws {
        let (base, local, other) = try repositories()
        defer { try? FileManager.default.removeItem(at: base) }
        try commit("Theirs.md", "# Theirs\n", in: other, message: "Theirs")
        try GitPush.push(repositoryAt: other, cancel: GitCancel())
        try Data("# Note\n\nTyped here, not committed.\n".utf8).write(to: local.appendingPathComponent("Note.md"))

        #expect(try GitPull.pull(repositoryAt: local, cancel: GitCancel()) == .fastForwarded(commits: 1))
        #expect(try text("Theirs.md", in: local) == "# Theirs\n")
        #expect(try text("Note.md", in: local) == "# Note\n\nTyped here, not committed.\n")
    }

    /// **The service pulls, says what came, and the collection reads it**: a
    /// pull writes past file coordination, so nothing else tells the folder's
    /// presenter on iOS.
    @Test func theServicePullsAndTheCollectionReadsWhatCame() async throws {
        let (base, local, other) = try repositories()
        defer { try? FileManager.default.removeItem(at: base) }
        try commit("New.md", "# New\n", in: other, message: "Add New")
        try GitPush.push(repositoryAt: other, cancel: GitCancel())
        let collection = Collection(rootURL: local)
        await collection.scanOffMain()
        defer { collection.deactivate() }
        let asked = collection.walksAskedFor

        await collection.git.pull()
        #expect(collection.git.lastError == nil, "\(collection.git.lastError ?? "")")
        #expect(collection.git.lastMessage == "Pulled 1 commit")
        #expect(collection.walksAskedFor == asked + 1, "the collection was not told the folder changed")
        var patience = Waits.Patience(.seconds(10))
        while !collection.notes.contains(where: { $0.title == "New" }), patience.lasts {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(collection.notes.contains { $0.title == "New" }, "the walk did not find what the pull brought")
    }

    /// **Stop while fetching is the pull's own cancel** — the part Stop is
    /// for. The fetch's cancel was passed up as it came, and the pane showed
    /// it as a failure, "Cancelled." in red (implemented.md §51.72).
    @Test func stopWhileFetchingIsThePullsOwnCancel() throws {
        let (base, local, other) = try repositories()
        defer { try? FileManager.default.removeItem(at: base) }
        try commit("New.md", "# New\n", in: other, message: "Add New")
        try GitPush.push(repositoryAt: other, cancel: GitCancel())
        let cancel = GitCancel()
        cancel.set()
        #expect(throws: GitPull.Failure.cancelled) {
            try GitPull.pull(repositoryAt: local, cancel: cancel)
        }
        #expect(!FileManager.default.fileExists(atPath: local.appendingPathComponent("New.md").path),
                "a pull stopped while fetching wrote notes")
    }

    /// **A pull that fails after writing its notes says so, and the collection
    /// reads its folder** — the branch could not move (here a lock another git
    /// left behind), and the notes it had written were in the folder with
    /// nothing telling the collection; on iOS nothing else would (§51.72).
    @Test func aPullThatFailsAfterWritingTellsTheCollection() async throws {
        let (base, local, other) = try repositories()
        defer { try? FileManager.default.removeItem(at: base) }
        try commit("New.md", "# New\n", in: other, message: "Add New")
        try GitPush.push(repositoryAt: other, cancel: GitCancel())
        let headFile = try String(contentsOf: local.appendingPathComponent(".git/HEAD"), encoding: .utf8)
        let branchRef = headFile.replacingOccurrences(of: "ref: ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lock = local.appendingPathComponent(".git/" + branchRef + ".lock")
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: lock)

        let collection = Collection(rootURL: local)
        await collection.scanOffMain()
        defer { collection.deactivate() }
        let asked = collection.walksAskedFor
        await collection.git.pull()
        #expect(collection.git.lastError != nil, "a pull that could not move its branch said nothing")
        #expect(FileManager.default.fileExists(atPath: local.appendingPathComponent("New.md").path),
                "the control: the pull wrote nothing, so this test cannot see a pull that did")
        #expect(collection.walksAskedFor == asked + 1, "the collection was not told the folder changed")
    }
}
