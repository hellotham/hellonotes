//
//  AgentToolTests.swift
//  HelloNotesTests
//
//  Created by Chris Tham on 12/7/2026.
//
//  Exercises the vault tools directly (no LLM): read/list/grep retrieval and
//  permission-gated create/edit against a throwaway copy of the sample vault.
//

import Testing
import Foundation
@testable import HelloNotes

@MainActor
struct AgentToolTests {

    /// Build a tool context over a fresh copy of the sample vault, with the
    /// permission broker pre-armed to auto-approve mutations.
    private func makeContext() throws -> (ToolContext, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentToolTests-\(UUID().uuidString)", isDirectory: true)
        let sample = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SampleVault")
        try FileManager.default.copyItem(at: sample, to: base)

        let indexer = Collection(rootURL: base)
        indexer.scan()
        let search = CollectionSearchModel()
        let git = GitService(); git.rootURL = base
        let permissions = PermissionBroker()
        permissions.respond(approved: true, allowAll: true)   // arm auto-approve

        return (ToolContext(collection: indexer, search: search, git: git, permissions: permissions), base)
    }

    private func arg(_ pairs: [String: JSONValue]) -> JSONValue { .object(pairs) }

    @Test
    func createReadListAndGrep() async throws {
        let (ctx, vault) = try makeContext()
        defer { try? FileManager.default.removeItem(at: vault) }

        let created = try await CreateNoteTool().run(
            arg(["title": .string("AgentScratch"),
                 "content": .string("line one\nsecret-token here\nline three")]),
            context: ctx)
        #expect(created.contains("AgentScratch"))

        let list = try await ListNotesTool().run(.object([:]), context: ctx)
        #expect(list.contains("AgentScratch"))

        let read = try await ReadNoteTool().run(arg(["note": .string("AgentScratch")]), context: ctx)
        #expect(read.contains("secret-token here"))

        let grep = try await GrepTool().run(arg(["pattern": .string("secret-token")]), context: ctx)
        #expect(grep.contains("AgentScratch"))
    }

    @Test
    func editAppliesUniqueReplacement() async throws {
        let (ctx, vault) = try makeContext()
        defer { try? FileManager.default.removeItem(at: vault) }

        _ = try await CreateNoteTool().run(
            arg(["title": .string("EditMe"), "content": .string("alpha beta gamma")]), context: ctx)

        let result = try await EditNoteTool().run(
            arg(["note": .string("EditMe"), "old_string": .string("beta"), "new_string": .string("BETA")]),
            context: ctx)
        #expect(result.contains("1 replacement"))

        let read = try await ReadNoteTool().run(arg(["note": .string("EditMe")]), context: ctx)
        #expect(read.contains("alpha BETA gamma"))
    }

    @Test
    func editRejectsAmbiguousMatchUnlessReplaceAll() async throws {
        let (ctx, vault) = try makeContext()
        defer { try? FileManager.default.removeItem(at: vault) }

        _ = try await CreateNoteTool().run(
            arg(["title": .string("Dup"), "content": .string("dup dup")]), context: ctx)

        // Ambiguous (2 occurrences) without replace_all → throws.
        await #expect(throws: (any Error).self) {
            _ = try await EditNoteTool().run(
                arg(["note": .string("Dup"), "old_string": .string("dup"), "new_string": .string("x")]),
                context: ctx)
        }

        // With replace_all → both replaced.
        let result = try await EditNoteTool().run(
            arg(["note": .string("Dup"), "old_string": .string("dup"),
                 "new_string": .string("x"), "replace_all": .bool(true)]),
            context: ctx)
        #expect(result.contains("2 replacements"))
        let read = try await ReadNoteTool().run(arg(["note": .string("Dup")]), context: ctx)
        #expect(read.contains("x x"))
    }

    @Test
    func declinedPermissionBlocksMutation() async throws {
        let (ctx, vault) = try makeContext()
        defer { try? FileManager.default.removeItem(at: vault) }
        // Fresh broker that denies.
        let denying = PermissionBroker()
        let denyingCtx = ToolContext(collection: ctx.collection, search: ctx.search, git: ctx.git, permissions: denying)

        // Run the tool and deny the prompt it raises.
        let task = Task { @MainActor in
            try await CreateNoteTool().run(
                arg(["title": .string("ShouldNotExist"), "content": .string("x")]), context: denyingCtx)
        }
        // Wait for the tool to register its prompt, then deny.
        var spins = 0
        while denying.prompt == nil && spins < 10_000 { await Task.yield(); spins += 1 }
        denying.respond(approved: false)

        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(!ctx.collection.notes.contains { $0.title == "ShouldNotExist" })
    }
}
