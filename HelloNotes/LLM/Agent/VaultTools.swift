//
//  VaultTools.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  The vault-scoped tools the assistant can call: read/list/search notes and,
//  gated by the permission broker with a diff preview + per-edit Git commit,
//  create/write/edit/delete them. Retrieval is agentic (grep/read) rather than
//  embedding-based — always fresh, no index to maintain.
//

import Foundation

enum VaultTools {
    /// The default tool set for a vault: retrieval, editing (gated), web
    /// research, and skills.
    @MainActor
    static func all() -> [AgentTool] {
        [
            ListNotesTool(), ReadNoteTool(), SearchNotesTool(), GrepVaultTool(),
            CreateNoteTool(), EditNoteTool(), WriteNoteTool(), DeleteNoteTool(),
            WebSearchTool(), WebFetchTool(), DeepResearchTool(), LoadSkillTool(),
        ]
    }
}

// MARK: - Read-only

struct ListNotesTool: AgentTool {
    let name = "list_notes"
    let description = "List all notes in the vault (title and relative path). Use this to discover what exists."
    var parameters: JSONValue { .objectSchema(properties: [:]) }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let notes = context.notes
        guard !notes.isEmpty else { return "The vault is empty." }
        return notes.map { "- \($0.title)  (\(context.relativePath($0)))" }.joined(separator: "\n")
    }
}

struct ReadNoteTool: AgentTool {
    let name = "read_note"
    let description = "Read the full Markdown contents of a note, identified by its title or relative path."
    var parameters: JSONValue {
        .objectSchema(
            properties: ["note": .stringSchema("The note's title or relative path, e.g. \"Welcome\" or \"Projects/Roadmap.md\".")],
            required: ["note"]
        )
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        guard let query = arguments.string("note") else { throw ToolError.badArguments("`note` is required.") }
        guard let note = context.note(matching: query) else { throw ToolError.notFound("No note matching “\(query)”.") }
        let body = context.readContents(of: note)
        return "# \(note.title)  (\(context.relativePath(note)))\n\n\(body)"
    }
}

struct SearchNotesTool: AgentTool {
    let name = "search_notes"
    let description = "Full-text search the vault for a query and return the top matching notes with snippets."
    var parameters: JSONValue {
        .objectSchema(
            properties: [
                "query": .stringSchema("The text to search for."),
                "limit": .intSchema("Max results (default 8)."),
            ],
            required: ["query"]
        )
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        guard let query = arguments.string("query") else { throw ToolError.badArguments("`query` is required.") }
        let limit = arguments.int("limit") ?? 8
        let hits = Array(context.search.fullTextResults(query: query).prefix(limit))
        guard !hits.isEmpty else { return "No notes matched “\(query)”." }
        return hits.map { hit in
            let snippet = hit.snippet.replacingOccurrences(of: "\n", with: " ")
            return "- \(hit.note.title)  (\(context.relativePath(hit.note)))\n  \(snippet)"
        }.joined(separator: "\n")
    }
}

struct GrepVaultTool: AgentTool {
    let name = "grep_vault"
    let description = "Find lines across all notes containing a substring (case-insensitive). Returns note title, line number, and the line."
    var parameters: JSONValue {
        .objectSchema(
            properties: [
                "pattern": .stringSchema("The substring to look for on each line."),
                "limit": .intSchema("Max matching lines to return (default 40)."),
            ],
            required: ["pattern"]
        )
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        guard let pattern = arguments.string("pattern") else { throw ToolError.badArguments("`pattern` is required.") }
        let needle = pattern.lowercased()
        let limit = arguments.int("limit") ?? 40
        var out: [String] = []
        for note in context.notes {
            let text = context.readContents(of: note)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line.lowercased().contains(needle) {
                    out.append("\(note.title):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
                    if out.count >= limit { return out.joined(separator: "\n") + "\n… (truncated at \(limit))" }
                }
            }
        }
        return out.isEmpty ? "No matches for “\(pattern)”." : out.joined(separator: "\n")
    }
}

// MARK: - Mutating (permission-gated, committed to Git)

struct CreateNoteTool: AgentTool {
    let name = "create_note"
    let description = "Create a new Markdown note with the given title and content. Fails if a note with that filename already exists."
    let isMutating = true
    var parameters: JSONValue {
        .objectSchema(
            properties: [
                "title": .stringSchema("The note title (also the filename)."),
                "content": .stringSchema("The Markdown body of the new note."),
                "folder": .stringSchema("Optional vault-relative folder to create it in."),
            ],
            required: ["title", "content"]
        )
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        guard let vault = context.vaultURL else { throw ToolError.failed("No vault open.") }
        guard let title = arguments.string("title"), let content = arguments["content"]?.stringValue else {
            throw ToolError.badArguments("`title` and `content` are required.")
        }
        let safe = title.replacingOccurrences(of: "/", with: "-")
        var dir = vault
        if let folder = arguments.string("folder") { dir = vault.appendingPathComponent(folder) }
        let url = dir.appendingPathComponent(safe + ".md")
        let rel = url.path.replacingOccurrences(of: vault.path + "/", with: "")

        let ok = await context.permissions.confirm(
            title: "Create note",
            detail: "Create “\(rel)”",
            diff: EditDiff(path: rel, before: "", after: content, isCreation: true)
        )
        guard ok else { throw ToolError.declined }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url, options: .withoutOverwriting)
        } catch {
            throw ToolError.failed("Couldn't create the note: \(error.localizedDescription)")
        }
        await context.refreshAfterMutation()
        await context.commit("assistant: create \(rel)")
        return "Created “\(rel)”."
    }
}

struct EditNoteTool: AgentTool {
    let name = "edit_note"
    let description = "Replace an exact substring in a note with new text. `old_string` must appear exactly once unless `replace_all` is true. Prefer this over rewriting the whole note."
    let isMutating = true
    var parameters: JSONValue {
        .objectSchema(
            properties: [
                "note": .stringSchema("The note's title or relative path."),
                "old_string": .stringSchema("The exact text to replace (include enough context to be unique)."),
                "new_string": .stringSchema("The replacement text."),
                "replace_all": .boolSchema("Replace every occurrence instead of requiring a unique match."),
            ],
            required: ["note", "old_string", "new_string"]
        )
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        guard let query = arguments.string("note") else { throw ToolError.badArguments("`note` is required.") }
        guard let note = context.note(matching: query) else { throw ToolError.notFound("No note matching “\(query)”.") }
        guard let oldString = arguments["old_string"]?.stringValue, !oldString.isEmpty,
              let newString = arguments["new_string"]?.stringValue else {
            throw ToolError.badArguments("`old_string` and `new_string` are required.")
        }
        let replaceAll = arguments.bool("replace_all") ?? false
        let before = context.readContents(of: note)

        let occurrences = before.components(separatedBy: oldString).count - 1
        guard occurrences > 0 else { throw ToolError.failed("`old_string` was not found in the note.") }
        if occurrences > 1 && !replaceAll {
            throw ToolError.failed("`old_string` appears \(occurrences) times; add more context to make it unique, or set replace_all.")
        }
        let after = replaceAll
            ? before.replacingOccurrences(of: oldString, with: newString)
            : before.replacingFirst(oldString, with: newString)
        let rel = context.relativePath(note)

        let ok = await context.permissions.confirm(
            title: "Edit note",
            detail: "Apply an edit to “\(rel)”",
            diff: EditDiff(path: rel, before: before, after: after)
        )
        guard ok else { throw ToolError.declined }

        do { try Data(after.utf8).write(to: note.fileURL) }
        catch { throw ToolError.failed("Couldn't write the note: \(error.localizedDescription)") }
        await context.refreshAfterMutation()
        await context.commit("assistant: edit \(rel)")
        return "Edited “\(rel)” (\(replaceAll ? "\(occurrences) replacements" : "1 replacement"))."
    }
}

struct WriteNoteTool: AgentTool {
    let name = "write_note"
    let description = "Overwrite a note's entire contents. Use edit_note for small changes; use this for a full rewrite."
    let isMutating = true
    var parameters: JSONValue {
        .objectSchema(
            properties: [
                "note": .stringSchema("The note's title or relative path."),
                "content": .stringSchema("The new full Markdown contents."),
            ],
            required: ["note", "content"]
        )
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        guard let query = arguments.string("note") else { throw ToolError.badArguments("`note` is required.") }
        guard let note = context.note(matching: query) else { throw ToolError.notFound("No note matching “\(query)”.") }
        guard let content = arguments["content"]?.stringValue else { throw ToolError.badArguments("`content` is required.") }
        let before = context.readContents(of: note)
        let rel = context.relativePath(note)

        let ok = await context.permissions.confirm(
            title: "Rewrite note",
            detail: "Overwrite “\(rel)”",
            diff: EditDiff(path: rel, before: before, after: content)
        )
        guard ok else { throw ToolError.declined }

        do { try Data(content.utf8).write(to: note.fileURL) }
        catch { throw ToolError.failed("Couldn't write the note: \(error.localizedDescription)") }
        await context.refreshAfterMutation()
        await context.commit("assistant: rewrite \(rel)")
        return "Rewrote “\(rel)”."
    }
}

struct DeleteNoteTool: AgentTool {
    let name = "delete_note"
    let description = "Move a note to the Trash (recoverable). Requires the note's title or relative path."
    let isMutating = true
    var parameters: JSONValue {
        .objectSchema(
            properties: ["note": .stringSchema("The note's title or relative path.")],
            required: ["note"]
        )
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        guard let query = arguments.string("note") else { throw ToolError.badArguments("`note` is required.") }
        guard let note = context.note(matching: query) else { throw ToolError.notFound("No note matching “\(query)”.") }
        let rel = context.relativePath(note)
        let before = context.readContents(of: note)

        let ok = await context.permissions.confirm(
            title: "Delete note",
            detail: "Move “\(rel)” to the Trash",
            diff: EditDiff(path: rel, before: before, after: "", isDeletion: true)
        )
        guard ok else { throw ToolError.declined }

        context.indexer.deleteNote(note)
        await context.refreshAfterMutation()
        await context.commit("assistant: delete \(rel)")
        return "Moved “\(rel)” to the Trash."
    }
}

private extension String {
    /// Replace the first occurrence of `target` with `replacement`.
    func replacingFirst(_ target: String, with replacement: String) -> String {
        guard let range = range(of: target) else { return self }
        return replacingCharacters(in: range, with: replacement)
    }
}
