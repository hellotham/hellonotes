//
//  AgentTool.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  The uniform tool contract — {name, description, JSON-Schema parameters, run} —
//  plus the execution context (collection services) and registry. Every capability the
//  assistant has over the collection is a tool; the model decides when to call them.
//

import Foundation

/// A capability the assistant can invoke. Runs on the main actor because it
/// touches the collection's @Observable state.
@MainActor
protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    /// JSON-Schema `object` describing the arguments.
    var parameters: JSONValue { get }
    /// Whether the tool changes files (gated by the permission broker).
    var isMutating: Bool { get }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String
}

extension AgentTool {
    var isMutating: Bool { false }
    var asLLMTool: LLMTool { LLMTool(name: name, description: description, parameters: parameters) }
}

/// Services a tool operates against — the focused collection and its services.
@MainActor
struct ToolContext {
    let collection: Collection
    let search: CollectionSearchModel
    let git: GitService
    let permissions: PermissionBroker
    var settings: LLMSettings? = nil   // for tools that spawn sub-agents (deep research)
    var skills: SkillStore? = nil      // collection SKILL.md files (load_skill)

    var rootURL: URL? { collection.rootURL }
    var notes: [Note] { collection.notes }

    /// A note matched by exact title, filename, or relative path (case-insensitive).
    func note(matching query: String) -> Note? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return nil }
        if let n = notes.first(where: { $0.title.lowercased() == q }) { return n }
        if let n = notes.first(where: { $0.fileURL.lastPathComponent.lowercased() == q }) { return n }
        return notes.first(where: {
            let rel = relativePath($0).lowercased()
            return rel == q || rel.hasSuffix("/" + q)
        })
    }

    func relativePath(_ note: Note) -> String {
        guard let base = rootURL?.standardizedFileURL.path else { return note.fileURL.lastPathComponent }
        let path = note.fileURL.standardizedFileURL.path
        guard path.hasPrefix(base) else { return note.fileURL.lastPathComponent }
        return String(path.dropFirst(base.count).drop(while: { $0 == "/" }))
    }

    /// True when `url`, after resolving symlinks, stays inside the collection
    /// root. Defends the mutating tools against a note whose file is a symlink
    /// pointing out of the vault (the directory enumerator follows symlinks).
    func isWithinRoot(_ url: URL) -> Bool {
        guard let root = rootURL else { return true }   // no scoped root: nothing to enforce
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        return target == base || target.hasPrefix(base + "/")
    }

    func readContents(of note: Note) -> String {
        (try? String(contentsOf: note.fileURL, encoding: .utf8)) ?? ""
    }

    /// Re-index the collection after a mutation and refresh search + git status.
    func refreshAfterMutation() async {
        collection.scan()
        collection.refreshDerived()
        await search.refresh(from: collection.notes)
        await git.refreshStatus()
    }

    /// Commit the change if the collection is a Git repo (per-edit safety net).
    func commit(_ message: String) async {
        if git.status.isRepository { await git.commitAll(message: message) }
    }
}

/// Errors a tool can raise; surfaced back to the model as an error tool result.
enum ToolError: LocalizedError {
    case badArguments(String)
    case notFound(String)
    case declined
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .badArguments(let m): return "Invalid arguments: \(m)"
        case .notFound(let m): return "Not found: \(m)"
        case .declined: return "The user declined this action."
        case .failed(let m): return m
        }
    }
}

@MainActor
struct ToolRegistry {
    let tools: [AgentTool]
    func tool(named name: String) -> AgentTool? { tools.first { $0.name == name } }
    var llmTools: [LLMTool] { tools.map(\.asLLMTool) }
}
