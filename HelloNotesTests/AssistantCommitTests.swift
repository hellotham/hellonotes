//
//  AssistantCommitTests.swift
//  HelloNotesTests
//
//  A change the Assistant makes is committed alone, and only where the app
//  may commit unasked.
//
//  Each approved change is its own commit, so each can be taken back on its
//  own — and the commit was `commitAll`: every pending change in the
//  collection went into it, under "assistant: edit …", whatever Auto-commit
//  was set to, and in a cloud folder or a sub-folder of a larger repository,
//  where Auto-commit itself is refused (found by fact-checking the 1.3.3
//  website against the source; implemented.md §51.44).
//
//  The commit names its file now (`GitService.commit(_:message:)`), and is
//  made under the rule Auto-commit is (`GitService.allowsUnattendedCommits`).
//

import Foundation
import Testing
import SwiftGitX
@testable import HelloNotes

@MainActor
struct AssistantCommitTests {

    // MARK: - One file

    /// The defect: the person's own pending change went into the Assistant's
    /// commit.
    @Test func aCommitOfOneNoteLeavesTheOthersPending() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = try await committed(root)
        let one = root.appendingPathComponent("One.md"), two = root.appendingPathComponent("Two.md")
        try write("# One\n\nChanged by the Assistant.\n", to: one)
        try write("# Two\n\nTyped by the person.\n", to: two)
        await git.refreshStatus()
        try #require(git.status.changeCount == 2)

        await git.commit([one], message: "assistant: edit One.md")

        #expect(git.lastError == nil)
        #expect(await git.history(for: one).map(\.summary) == ["assistant: edit One.md", "Import"])
        #expect(await git.history(for: two).map(\.summary) == ["Import"],
                "the person's own change went into the Assistant's commit")
        #expect(git.status.changeCount == 1, "what the person changed is still theirs to commit")
    }

    @Test func aNewNoteIsCommittedAlone() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = try await committed(root)
        let made = root.appendingPathComponent("Made.md"), other = root.appendingPathComponent("Other.md")
        try write("# Made\n", to: made)
        try write("# Other\n", to: other)

        await git.commit([made], message: "assistant: create Made.md")

        #expect(await git.history(for: made).map(\.summary) == ["assistant: create Made.md"])
        #expect(await git.history(for: other).isEmpty)
        #expect(git.status.changeCount == 1)
    }

    /// A deletion is a change to commit too — and staging a path that is no
    /// longer there is its own call in libgit2.
    @Test func aDeletedNoteIsCommittedAlone() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = try await committed(root)
        let three = root.appendingPathComponent("Three.md"), two = root.appendingPathComponent("Two.md")
        try FileManager.default.removeItem(at: three)
        try write("# Two\n\nTyped by the person.\n", to: two)
        await git.refreshStatus()
        try #require(git.status.changeCount == 2)

        await git.commit([three], message: "assistant: delete Three.md")

        #expect(git.lastError == nil)
        #expect(git.lastMessage == "Committed changes")
        #expect(git.status.changeCount == 1, "the deletion was not committed, or the other change was")
        #expect(await git.history(for: two).map(\.summary) == ["Import"])
    }

    /// The whole-collection commit, for the same reason: a note deleted and
    /// then committed is gone from the repository.
    @Test func commitTakesADeletionToo() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = try await committed(root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Three.md"))
        await git.refreshStatus()
        try #require(git.status.changeCount == 1)

        await git.commitAll(message: "Delete Three")

        #expect(git.status.isClean,
                "a deleted note stayed pending after Commit: said \(git.lastMessage ?? "nothing"), error \(git.lastError ?? "none")")
    }

    /// A commit writes the whole index, so something staged by another tool
    /// would go into it: refused, as the whole-collection commit refuses it.
    @Test func somethingAlreadyStagedIsNotSweptIn() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = try await committed(root)
        let one = root.appendingPathComponent("One.md"), two = root.appendingPathComponent("Two.md")
        try write("# One\n\nChanged by the Assistant.\n", to: one)
        try write("# Two\n\nStaged in a Git client.\n", to: two)
        try Repository.open(at: root).add(path: "Two.md")

        await git.commit([one], message: "assistant: edit One.md")

        #expect(await git.history(for: two).map(\.summary) == ["Import"],
                "a change staged elsewhere went into the Assistant's commit")
        #expect(await git.history(for: one).map(\.summary) == ["Import"])
        #expect(git.lastMessage?.contains("staged") == true, "nothing said why: \(git.lastMessage ?? "nil")")
    }

    // MARK: - Where

    /// The Assistant's edit, approved, in an ordinary repository: committed,
    /// alone, whatever Auto-commit is set to.
    @Test func anApprovedEditIsCommittedAlone() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let (context, git) = try await assistant(in: root, repositoryAt: root)
        let two = root.appendingPathComponent("Two.md")
        try write("# Two\n\nTyped by the person.\n", to: two)

        _ = try await context.editNote("One", oldString: "# One", newString: "# One, edited", replaceAll: false)
        await context.lastCommit?.value

        let one = root.appendingPathComponent("One.md")
        #expect(try FileIO.readString(at: one).hasPrefix("# One, edited"))
        #expect(await git.history(for: one).map(\.summary) == ["assistant: edit One.md", "Import"])
        #expect(await git.history(for: two).map(\.summary) == ["Import"])
    }

    /// A collection that is one folder of a larger repository: the change is
    /// made and saved, and no commit is — commits written unasked into a
    /// repository someone uses for other work are not the app's to make.
    @Test func noCommitIsMadeIntoALargerRepository() async throws {
        let outer = try folder(notes: [])
        defer { try? FileManager.default.removeItem(at: outer) }
        let root = outer.appendingPathComponent("docs", isDirectory: true)
        try seed(root)
        let (context, git) = try await assistant(in: root, repositoryAt: outer)
        try #require(git.status.isSubdirectory)

        _ = try await context.editNote("One", oldString: "# One", newString: "# One, edited", replaceAll: false)
        await context.lastCommit?.value

        let one = root.appendingPathComponent("One.md")
        #expect(try FileIO.readString(at: one).hasPrefix("# One, edited"), "the edit itself must still be made")
        #expect(context.lastCommit == nil)
        #expect(await git.history(for: one).map(\.summary) == ["Import"])
    }

    /// A collection in a cloud provider's folder, where libgit2 would churn
    /// its object store against files kept online: the same.
    @Test func noCommitIsMadeInACloudFolder() async throws {
        let base = try folder(notes: [])
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("CloudStorage/Dropbox-Test/Notes", isDirectory: true)
        try seed(root)
        // The control: this is a folder the app calls cloud-backed.
        try #require(CloudProvider.name(for: root) == "Dropbox")
        let (context, git) = try await assistant(in: root, repositoryAt: root)
        try #require(git.status.isRepository && !git.status.isSubdirectory)

        _ = try await context.editNote("One", oldString: "# One", newString: "# One, edited", replaceAll: false)
        await context.lastCommit?.value

        let one = root.appendingPathComponent("One.md")
        #expect(try FileIO.readString(at: one).hasPrefix("# One, edited"), "the edit itself must still be made")
        #expect(context.lastCommit == nil)
        #expect(await git.history(for: one).map(\.summary) == ["Import"])
    }

    /// **A folder that is there and a file no longer in it are spelled two
    /// ways.** `standardizedFileURL` drops `/private` from a path that exists
    /// and leaves it on one that does not, so the file was "not inside" its
    /// own repository and the commit of a deletion was skipped without a word
    /// — on any collection reached as `/private/var/…`, which is an iPhone's
    /// containers. This host's own folders have no `/private` twin, so the
    /// deletion tests above could not see it; the paths here name nothing,
    /// and only their spelling is asked about.
    @Test func aDeletedFileIsFoundInsideARootSpelledTheOtherWay() {
        let short = URL(fileURLWithPath: "/var/mobile/Containers/Notes", isDirectory: true)
        let long = URL(fileURLWithPath: "/private/var/mobile/Containers/Notes", isDirectory: true)
        for (file, root) in [(long, short), (short, long), (short, short), (long, long)] {
            #expect(GitService.relativePath(of: file.appendingPathComponent("Sub/Gone.md"), in: root) == "Sub/Gone.md",
                    "\(file.path) was not found inside \(root.path)")
        }
        // The control: a file somewhere else is still somewhere else.
        #expect(GitService.relativePath(of: URL(fileURLWithPath: "/var/mobile/Containers/Other/Gone.md"), in: short) == nil)
        #expect(GitService.relativePath(of: URL(fileURLWithPath: "/var/mobile/Containers/NotesToo/Gone.md"), in: short) == nil)
    }

    /// A delete that fails is not answered "Moved to the Trash", and is not
    /// committed. `Collection.deleteNote` reports the failure and returns, and
    /// the tool went on as if it had not.
    @Test func aDeleteThatFailsIsNotReportedOrCommitted() async throws {
        let root = try folder(notes: ["One"])
        defer { try? FileManager.default.removeItem(at: root) }
        let locked = root.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let kept = locked.appendingPathComponent("Kept.md")
        try write("# Kept\n", to: kept)
        let (context, git) = try await assistant(in: root, repositoryAt: root)
        // A folder nothing can be taken out of.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        // A deletion is asked about every time, whatever was allowed before —
        // so the question is answered here, once it is up.
        let deleting = Task { @MainActor () -> Result<String, Error> in
            do { return .success(try await context.deleteNote("Kept")) } catch { return .failure(error) }
        }
        var patience = Waits.Patience(.seconds(10))
        while context.permissions.prompt == nil, patience.lasts {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(context.permissions.prompt?.diff?.isDeletion == true, "the delete was never asked about")
        context.permissions.respond(approved: true)
        var said: String?
        var failure: Error?
        switch await deleting.value {
        case .success(let answer): said = answer
        case .failure(let error): failure = error
        }
        await context.lastCommit?.value

        try #require(FileManager.default.fileExists(atPath: kept.path),
                     "the note was deleted after all, so this shows nothing about a delete that fails")
        #expect(said == nil, "a note still on disk was answered: \(said ?? "")")
        #expect(failure != nil)
        #expect(context.lastCommit == nil)
        #expect(await git.history(for: kept).map(\.summary) == ["Import"])
    }

    /// One rule, asked by Auto-commit and by the Assistant.
    @Test func theRuleForCommitsNobodyPressedCommitFor() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = try await committed(root)
        #expect(git.allowsUnattendedCommits(isCloudBacked: false))
        #expect(!git.allowsUnattendedCommits(isCloudBacked: true))
    }

    // MARK: - Setup

    private func folder(notes: [String] = ["One", "Two", "Three"]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssistantCommit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in notes { try write("# \(name)\n", to: root.appendingPathComponent("\(name).md")) }
        return root
    }

    private func seed(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["One", "Two", "Three"] { try write("# \(name)\n", to: root.appendingPathComponent("\(name).md")) }
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// A repository at `root` with everything in it committed as "Import".
    private func committed(_ root: URL) async throws -> GitService {
        let git = GitService()
        git.rootURL = root
        await git.initializeRepository()
        await git.commitAll(message: "Import")
        try #require(git.status.isRepository && git.status.isClean, "the repository was never set up")
        return git
    }

    /// The Assistant's tools over the collection at `root`, approving every
    /// change, in a repository at `repository` with everything committed.
    private func assistant(in root: URL, repositoryAt repository: URL) async throws -> (ToolContext, GitService) {
        _ = try await committed(repository)
        let collection = Collection(rootURL: root)
        collection.scan()
        let git = GitService()
        git.rootURL = root
        await git.refreshStatus()
        let permissions = PermissionBroker()
        permissions.respond(approved: true, allowAll: true)
        return (ToolContext(collection: collection, search: collection.search, git: git, permissions: permissions), git)
    }
}
