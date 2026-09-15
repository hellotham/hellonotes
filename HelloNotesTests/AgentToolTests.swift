//
//  AgentToolTests.swift
//  HelloNotesTests
//
//  Created by Chris Tham on 12/7/2026.
//
//  Exercises the Assistant's collection operations directly (no model):
//  read/list/grep retrieval and permission-gated create/edit against a
//  throwaway copy of the sample vault, plus the approval queue that parallel
//  tool calls depend on.
//

import Testing
import Foundation
@testable import HelloNotes

@MainActor
struct AgentToolTests {

    /// A tool context over a fresh copy of the sample vault. `approving` arms
    /// the broker to auto-approve mutations.
    private func makeContext(approving: Bool = true) throws -> (ToolContext, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentToolTests-\(UUID().uuidString)", isDirectory: true)
        let sample = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SampleVault")
        try FileManager.default.copyItem(at: sample, to: base)

        let collection = Collection(rootURL: base)
        collection.scan()
        let git = GitService(); git.rootURL = base
        let permissions = PermissionBroker()
        if approving { permissions.respond(approved: true, allowAll: true) }

        return (ToolContext(collection: collection, search: collection.search, git: git,
                            permissions: permissions), base)
    }

    @Test
    func createReadListAndGrep() async throws {
        let (ctx, vault) = try makeContext()
        defer { try? FileManager.default.removeItem(at: vault) }

        let created = try await ctx.createNote(title: "AgentScratch",
                                               content: "line one\nsecret-token here\nline three",
                                               folder: nil)
        #expect(created.contains("AgentScratch"))

        #expect(ctx.listNotes(limit: 10_000).contains("AgentScratch"))

        let read = try await ctx.readNote("AgentScratch", maxCharacters: 10_000)
        #expect(read.contains("secret-token here"))

        let grep = await ctx.grep("secret-token", limit: 40)
        #expect(grep.contains("AgentScratch"))
    }

    @Test
    func createRefusesToOverwriteAnExistingNote() async throws {
        let (ctx, vault) = try makeContext()
        defer { try? FileManager.default.removeItem(at: vault) }

        _ = try await ctx.createNote(title: "Once", content: "first", folder: nil)
        await #expect(throws: ToolError.self) {
            _ = try await ctx.createNote(title: "Once", content: "second", folder: nil)
        }
        #expect(try await ctx.readNote("Once", maxCharacters: 10_000).contains("first"))
    }

    @Test
    func createStaysInsideTheCollection() async throws {
        let (ctx, vault) = try makeContext()
        defer { try? FileManager.default.removeItem(at: vault) }

        await #expect(throws: ToolError.self) {
            _ = try await ctx.createNote(title: "Escape", content: "x", folder: "../..")
        }
    }

    @Test
    func editAppliesUniqueReplacement() async throws {
        let (ctx, vault) = try makeContext()
        defer { try? FileManager.default.removeItem(at: vault) }

        _ = try await ctx.createNote(title: "EditMe", content: "alpha beta gamma", folder: nil)
        let result = try await ctx.editNote("EditMe", oldString: "beta", newString: "BETA", replaceAll: false)
        #expect(result.contains("1 replacement"))

        let read = try await ctx.readNote("EditMe", maxCharacters: 10_000)
        #expect(read.contains("alpha BETA gamma"))
    }

    @Test
    func editRejectsAmbiguousMatchUnlessReplaceAll() async throws {
        let (ctx, vault) = try makeContext()
        defer { try? FileManager.default.removeItem(at: vault) }

        _ = try await ctx.createNote(title: "Dup", content: "dup dup", folder: nil)

        await #expect(throws: ToolError.self) {
            _ = try await ctx.editNote("Dup", oldString: "dup", newString: "x", replaceAll: false)
        }

        let result = try await ctx.editNote("Dup", oldString: "dup", newString: "x", replaceAll: true)
        #expect(result.contains("2 replacements"))
        #expect(try await ctx.readNote("Dup", maxCharacters: 10_000).contains("x x"))
    }

    @Test
    func readTruncationSaysSo() async throws {
        let (ctx, vault) = try makeContext()
        defer { try? FileManager.default.removeItem(at: vault) }

        _ = try await ctx.createNote(title: "Long", content: String(repeating: "word ", count: 2_000), folder: nil)
        let read = try await ctx.readNote("Long", maxCharacters: 100)
        #expect(read.contains("truncated"))
    }

    @Test
    func declinedPermissionBlocksMutation() async throws {
        let (ctx, vault) = try makeContext(approving: false)
        defer { try? FileManager.default.removeItem(at: vault) }
        let broker = ctx.permissions

        let task = Task { @MainActor in
            try await ctx.createNote(title: "ShouldNotExist", content: "x", folder: nil)
        }
        var spins = 0
        while broker.prompt == nil && spins < 10_000 { await Task.yield(); spins += 1 }
        broker.respond(approved: false)

        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(!ctx.collection.notes.contains { $0.title == "ShouldNotExist" })
    }

    /// Wait, briefly, for the broker to show a card — the read before it runs
    /// off the main actor, so a fixed number of yields is not enough.
    private func waitForPrompt(_ broker: PermissionBroker) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while broker.prompt == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(broker.prompt != nil, "no approval card appeared")
    }

    /// Clicking Approve in the Assistant's window ends editing in the note's
    /// window, which saves what the person typed while the card was up. The
    /// approved change was computed without that typing, so it must not be
    /// written over it.
    @Test
    func anApprovedEditIsNotMadeOverTextSavedWhileItWaited() async throws {
        let (ctx, vault) = try makeContext(approving: false)
        defer { try? FileManager.default.removeItem(at: vault) }
        let url = vault.appendingPathComponent("Race.md")
        try FileIO.write("alpha beta gamma", to: url)
        ctx.collection.scan()

        let edit = Task { @MainActor in
            try await ctx.editNote("Race", oldString: "beta", newString: "BETA", replaceAll: false)
        }
        try await waitForPrompt(ctx.permissions)
        #expect(ctx.permissions.prompt?.diff?.before == "alpha beta gamma")

        try FileIO.write("alpha beta gamma, and what the person typed", to: url)
        ctx.permissions.respond(approved: true)

        let error = await #expect(throws: ToolError.self) { _ = try await edit.value }
        #expect(error?.errorDescription?.contains("changed after it was read") == true)
        #expect(try FileIO.readString(at: url) == "alpha beta gamma, and what the person typed")
    }

    /// An approved edit is recorded as the app's own write, so the file watcher
    /// never reports it. The open editors are told directly instead — without
    /// that, a tab showing the note saved its old text back over the change.
    @Test
    func anApprovedEditTellsTheOpenEditors() async throws {
        let (ctx, vault) = try makeContext()
        defer { try? FileManager.default.removeItem(at: vault) }
        try FileIO.write("alpha beta gamma", to: vault.appendingPathComponent("Open.md"))
        var told = 0
        await ctx.collection.activate(onExternalChange: { told += 1 })
        defer { ctx.collection.deactivate() }
        let deadline = ContinuousClock.now + .seconds(5)
        while ctx.note(matching: "Open") == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let before = told

        _ = try await ctx.editNote("Open", oldString: "beta", newString: "BETA", replaceAll: false)

        #expect(told == before + 1)
        #expect(try FileIO.readString(at: vault.appendingPathComponent("Open.md")) == "alpha BETA gamma")
    }

    /// A note that can't be read is not an empty note. It used to read as `""`,
    /// which made the approval card for deleting it look like deleting nothing.
    @Test
    func anUnreadableNoteIsRefusedNotTreatedAsEmpty() async throws {
        let (ctx, vault) = try makeContext(approving: false)
        defer { try? FileManager.default.removeItem(at: vault) }
        // Not UTF-8, so the coordinated read throws — the same outcome as a
        // cloud file that will not download.
        try Data([0xFF, 0xFE, 0xFD]).write(to: vault.appendingPathComponent("Garbled.md"))
        ctx.collection.scan()

        await #expect(throws: ToolError.self) { _ = try await ctx.readNote("Garbled", maxCharacters: 1_000) }
        await #expect(throws: ToolError.self) { _ = try await ctx.deleteNote("Garbled") }
        #expect(ctx.permissions.prompt == nil, "a deletion card was shown for a note that couldn't be read")
        #expect(FileManager.default.fileExists(atPath: vault.appendingPathComponent("Garbled.md").path))
    }

    /// The model issues parallel tool calls, so two approvals can be asked for at
    /// once. The second must wait its turn — not be denied, which is what the
    /// broker did before it queued.
    @Test
    func concurrentApprovalsQueueInsteadOfFailing() async throws {
        let broker = PermissionBroker()
        let first = Task { @MainActor in await broker.confirm(title: "First", detail: "") }
        let second = Task { @MainActor in await broker.confirm(title: "Second", detail: "") }

        var spins = 0
        while broker.queuedCount == 0 && spins < 10_000 { await Task.yield(); spins += 1 }
        #expect(broker.prompt?.title == "First")
        #expect(broker.queuedCount == 1)

        broker.respond(approved: true)
        #expect(await first.value)
        #expect(broker.prompt?.title == "Second")

        broker.respond(approved: false)
        #expect(await second.value == false)
        #expect(broker.prompt == nil)
    }

    /// "Allow all" answered on one prompt covers what queued behind it — but a
    /// deletion is always asked about.
    @Test
    func allowAllCoversTheQueueExceptDeletions() async throws {
        let broker = PermissionBroker()
        let edit = Task { @MainActor in await broker.confirm(title: "Edit", detail: "") }
        let queuedEdit = Task { @MainActor in
            await broker.confirm(title: "Queued edit", detail: "",
                                 diff: EditDiff(path: "a.md", before: "a", after: "b"))
        }
        let deletion = Task { @MainActor in
            await broker.confirm(title: "Delete", detail: "",
                                 diff: EditDiff(path: "a.md", before: "a", after: "", isDeletion: true))
        }
        var spins = 0
        while broker.queuedCount < 2 && spins < 10_000 { await Task.yield(); spins += 1 }

        broker.respond(approved: true, allowAll: true)
        #expect(await edit.value)
        #expect(await queuedEdit.value)
        #expect(broker.prompt?.title == "Delete")
        broker.respond(approved: false)
        #expect(await deletion.value == false)
    }

    /// Stopping a response denies whatever is waiting, so a tool cannot hang
    /// on a question nobody will answer.
    @Test
    func cancelPendingReleasesEveryWaiter() async throws {
        let broker = PermissionBroker()
        let a = Task { @MainActor in await broker.confirm(title: "A", detail: "") }
        let b = Task { @MainActor in await broker.confirm(title: "B", detail: "") }
        var spins = 0
        while broker.queuedCount == 0 && spins < 10_000 { await Task.yield(); spins += 1 }

        broker.cancelPending()
        #expect(await a.value == false)
        #expect(await b.value == false)
        #expect(broker.prompt == nil)
    }
}
