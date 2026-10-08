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

    /// Through the tool, the arguments Apple's on-device model sent when asked
    /// to change pears to plums: the line, and the lines around it restated.
    /// What is approved and written is the one line changed.
    @Test
    func anEditThatRestatesItsSurroundingsChangesOneLine() async throws {
        let (ctx, vault) = try makeContext()
        defer { try? FileManager.default.removeItem(at: vault) }

        _ = try await ctx.createNote(title: "Groceries", content: "# Groceries\n\n- apples\n- pears\n- flour\n",
                                     folder: nil)
        _ = try await ctx.editNote("Groceries", oldString: "- pears", newString: "- apples\n- plums\n- flour",
                                   replaceAll: true)
        #expect(try FileIO.readString(at: vault.appendingPathComponent("Groceries.md"))
                == "# Groceries\n\n- apples\n- plums\n- flour\n")
    }

    /// A note in the collection's list is found by its title before the index
    /// has read it — as on opening a collection, until the index's rebuild
    /// lands, and for a note that hasn't downloaded, which it never reads.
    /// `makeContext` scans and loads no index.
    @Test
    func searchFindsANoteByTitleTheIndexHasNotRead() async throws {
        let (ctx, vault) = try makeContext()
        defer { try? FileManager.default.removeItem(at: vault) }

        let found = await ctx.searchNotes("Callouts", limit: 10)
        #expect(found.contains("- Callouts  (Callouts.md)"), "\(found)")
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
    /// The card is raised once the note has been read and the diff made, off
    /// the main actor — on a pool the whole suite shares. Five seconds was not
    /// always enough in a full run (it failed twice on 2026-09-25/26, and
    /// passed alone every time); a card that never comes fails here all the
    /// same, only later.
    private func waitForPrompt(_ broker: PermissionBroker) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
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

    // MARK: - A note open in an editor

    /// An editor on `title`'s note, wired to the collection as a tab's is,
    /// with `typed` typed into it and not yet saved.
    private func openWithTyping(_ title: String, in ctx: ToolContext, vault: URL,
                                body: String, typed: String) async throws -> (EditorModel, URL) {
        let url = vault.appendingPathComponent("\(title).md")
        try FileIO.write(body, to: url)
        ctx.collection.scan()
        let note = try #require(ctx.note(matching: title))
        let editor = EditorModel()
        EditorWiring { _ in ctx.collection }.wire(editor)
        await editor.open(note)
        editor.typed(typed)
        #expect(editor.isDirty)
        return (editor, url)
    }

    /// **An edit to a note open with unsaved typing is made on the typing.**
    /// The Assistant read the file and wrote the file, so the typing on screen
    /// was not in what it changed: the note open in the editor then met a
    /// change it had not made, and the person had to choose between their
    /// typing and the approved change (implemented.md §51.36). Read and
    /// written through the editor, the change is made to what is on screen,
    /// and both are kept.
    @Test
    func anEditToANoteOpenWithTypingIsMadeOnTheTyping() async throws {
        let (ctx, vault) = try makeContext()
        defer { try? FileManager.default.removeItem(at: vault) }
        let (editor, url) = try await openWithTyping("Open", in: ctx, vault: vault, body: "alpha beta gamma\n",
                                                     typed: "alpha beta gamma\nTyped, not yet saved.\n")

        _ = try await ctx.editNote("Open", oldString: "beta", newString: "BETA", replaceAll: false)

        #expect(editor.text == "alpha BETA gamma\nTyped, not yet saved.\n", "the change was not made to what is on screen")
        #expect(!editor.hasConflict, "the approved change and the typing were set against each other")
        #expect(try FileIO.readString(at: url) == "alpha BETA gamma\nTyped, not yet saved.\n",
                "the change and the typing were not written together")
        #expect(!editor.isDirty)
    }

    /// The card shows the change against what is on screen — the text the
    /// change will be made to.
    @Test
    func theCardForANoteOpenWithTypingShowsTheTyping() async throws {
        let (ctx, vault) = try makeContext(approving: false)
        defer { try? FileManager.default.removeItem(at: vault) }
        let (editor, _) = try await openWithTyping("Shown", in: ctx, vault: vault, body: "alpha beta gamma\n",
                                                   typed: "alpha beta gamma\nTyped.\n")
        defer { withExtendedLifetime(editor) {} }

        let rewrite = Task { @MainActor in try await ctx.writeNote("Shown", content: "Rewritten.\n") }
        try await waitForPrompt(ctx.permissions)
        #expect(ctx.permissions.prompt?.diff?.before == "alpha beta gamma\nTyped.\n")
        ctx.permissions.respond(approved: false)
        _ = try? await rewrite.value
    }

    /// Typing while the card waits is the same as a save while it waits: the
    /// change was made from text that is no longer on screen, so it is not
    /// made, and the typing stays.
    @Test
    func anApprovedEditIsNotMadeOverTypingWhileItWaited() async throws {
        let (ctx, vault) = try makeContext(approving: false)
        defer { try? FileManager.default.removeItem(at: vault) }
        let (editor, url) = try await openWithTyping("Waiting", in: ctx, vault: vault, body: "alpha beta gamma\n",
                                                     typed: "alpha beta gamma\nTyped.\n")

        let edit = Task { @MainActor in
            try await ctx.editNote("Waiting", oldString: "beta", newString: "BETA", replaceAll: false)
        }
        try await waitForPrompt(ctx.permissions)
        editor.typed("alpha beta gamma\nTyped.\nAnd more, while the card was up.\n")
        ctx.permissions.respond(approved: true)

        let error = await #expect(throws: ToolError.self) { _ = try await edit.value }
        #expect(error?.errorDescription?.contains("changed after it was read") == true)
        #expect(editor.text == "alpha beta gamma\nTyped.\nAnd more, while the card was up.\n")
        #expect(try FileIO.readString(at: url) == "alpha beta gamma\n")
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

/// Linking an unlinked mention writes another note — through its editor when
/// one has it open, as the Assistant's edits are (implemented.md §51.36). It
/// wrote the file and told no editor, so a tab showing the note met a change
/// it had not made, and asked the person to choose.
@MainActor
struct MentionLinkTests {
    @Test func aMentionInAnOpenNoteIsLinkedOnScreen() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MentionLink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileIO.write("# Target\n", to: root.appendingPathComponent("Target.md"))
        let mentioning = root.appendingPathComponent("Mentioning.md")
        try FileIO.write("Something about Target here.\n", to: mentioning)
        let collection = Collection(rootURL: root)
        collection.scan()
        let note = try #require(collection.note(titled: "Mentioning"))
        let editor = EditorModel()
        EditorWiring { _ in collection }.wire(editor)
        await editor.open(note)
        editor.typed("Something about Target here.\nTyped, not yet saved.\n")

        await MentionLinker.linkFirstMention(of: "Target", in: note, collection: collection)

        #expect(editor.text == "Something about [[Target]] here.\nTyped, not yet saved.\n",
                "the link was not made to what is on screen")
        #expect(!editor.hasConflict)
        await editor.save()
        #expect(try FileIO.readString(at: mentioning) == "Something about [[Target]] here.\nTyped, not yet saved.\n")
    }
}

/// What `edit_note` writes for a match that occurs once.
struct EditReplacementTests {
    let note = "# Shopping\n\n- apples\n- pears\n- flour\n"

    /// Asked to change one line of a list, Apple's on-device model sent that
    /// line to replace and the lines around it, restated, as the replacement.
    @Test func linesRestatedOnBothSidesAreContextNotNewText() {
        #expect(EditReplacement.once("- pears", with: "- apples\n- plums\n- flour", in: note)
                == "# Shopping\n\n- apples\n- plums\n- flour\n")
        // A line taken out the same way.
        #expect(EditReplacement.once("- pears", with: "- apples\n- flour", in: note)
                == "# Shopping\n\n- apples\n- flour\n")
    }

    /// Arguments that carry their context in both, as larger models send
    /// them, are applied as written.
    @Test func contextInBothArgumentsIsAppliedAsWritten() {
        #expect(EditReplacement.once("- apples\n- pears\n- flour", with: "- apples\n- plums\n- flour", in: note)
                == "# Shopping\n\n- apples\n- plums\n- flour\n")
        #expect(EditReplacement.once("pears", with: "plums", in: note)
                == "# Shopping\n\n- apples\n- plums\n- flour\n")
    }

    /// One side alone is also how an insertion looks — a line added before
    /// pears — so it is written as given, and the person sees it in the diff.
    @Test func oneSideIsTakenAsWritten() {
        #expect(EditReplacement.once("- pears", with: "- bread\n- pears", in: note)
                == "# Shopping\n\n- apples\n- bread\n- pears\n- flour\n")
        #expect(EditReplacement.once("- pears", with: "- apples\n- plums", in: note)
                == "# Shopping\n\n- apples\n- apples\n- plums\n- flour\n")
    }

    /// Whole lines only: a match inside a line is replaced where it stands.
    @Test func aMatchInsideALineIsNeverWidened() {
        #expect(EditReplacement.once("pears", with: "- apples\n- plums\n- flour", in: note)
                == "# Shopping\n\n- apples\n- - apples\n- plums\n- flour\n- flour\n")
    }
}
