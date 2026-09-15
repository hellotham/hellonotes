//
//  NoteTools.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  The collection tools the Assistant calls, as Foundation Models `Tool`s.
//
//  Each one is a thin shell: `@Generable` arguments (so the model's call is
//  schema-constrained rather than parsed from free text), a hop to
//  `ToolContext` for the work, and a string back. `nonisolated` because the
//  framework calls tools concurrently, off the main actor, and this target
//  would otherwise make every one of them main-actor-isolated.
//
//  **A failure is an answer, not an abort.** A tool that throws ends the whole
//  response — Foundation Models wraps the error in `ToolCallError` and rolls the
//  transcript back. That is right for "the person stopped it" and wrong for "no
//  note has that title", which the model can fix by searching first. So
//  recoverable failures come back as text (`ToolOutcome`), and only
//  cancellation propagates.
//

import Foundation
import FoundationModels

/// How much a tool may put in front of the model, scaled to its window.
///
/// A tool's output is one turn among several — instructions, the conversation,
/// other tools' results and the reply all share the window. On the on-device
/// model's 8,192 tokens a whole long note would crowd out the answer; on Private
/// Cloud Compute's 32,768 the same cap would read a fraction of what fits.
nonisolated struct ToolLimits: Sendable, Equatable {
    let readCharacters: Int
    let fetchCharacters: Int
    let listLimit: Int
    let grepLimit: Int
    let searchLimit: Int

    init(contextTokens: Int) {
        // About a quarter of the window for a note, a sixth for a web page, at
        // a conservative three characters a token.
        readCharacters = min(40_000, max(2_000, contextTokens / 4 * 3))
        fetchCharacters = min(16_000, max(1_500, contextTokens / 6 * 3))
        let roomy = contextTokens >= 16_000
        listLimit = roomy ? 200 : 60
        grepLimit = roomy ? 60 : 20
        searchLimit = roomy ? 10 : 6
    }
}

/// Runs a tool's work and turns a recoverable failure into words for the model.
nonisolated enum ToolOutcome {
    static func run(_ work: () async throws -> String) async throws -> String {
        do {
            return try await work()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return "Couldn't do that: \(error.localizedDescription)"
        }
    }
}

enum NoteTools {
    /// The tools for a session, chosen by the model's window.
    ///
    /// Apple's guidance for the on-device model is three to five tools a
    /// request: every definition is instructions the model must read before the
    /// person's question, and a small window spent on schemas is a window not
    /// spent on notes. So a small window gets the five that carry the
    /// Assistant's purpose — find, read, create, edit, and look something up —
    /// and a large one gets the full set.
    @MainActor
    static func tools(for context: ToolContext, contextTokens: Int) -> [any Tool] {
        let limits = ToolLimits(contextTokens: contextTokens)
        let hasSkills = !(context.skills?.skills.isEmpty ?? true)

        guard contextTokens >= 16_000 else {
            var compact: [any Tool] = [
                SearchNotesTool(context: context, limits: limits),
                ReadNoteTool(context: context, limits: limits),
                CreateNoteTool(context: context),
                EditNoteTool(context: context),
                WebSearchTool(),
            ]
            if hasSkills { compact.append(LoadSkillTool(context: context)) }
            return compact
        }

        var full: [any Tool] = [
            SearchNotesTool(context: context, limits: limits),
            ReadNoteTool(context: context, limits: limits),
            ListNotesTool(context: context, limits: limits),
            GrepTool(context: context, limits: limits),
            CreateNoteTool(context: context),
            EditNoteTool(context: context),
            WriteNoteTool(context: context),
            DeleteNoteTool(context: context),
            WebSearchTool(),
            WebFetchTool(limits: limits),
            DeepResearchTool(context: context),
        ]
        if hasSkills { full.append(LoadSkillTool(context: context)) }
        return full
    }
}

// MARK: - Reading

nonisolated struct ListNotesTool: Tool {
    let context: ToolContext
    let limits: ToolLimits
    let name = "list_notes"
    let description = "List the collection's notes by title and path. Prefer search_notes to find something specific."

    @Generable
    nonisolated struct Arguments {}

    @concurrent func call(arguments: Arguments) async throws -> String {
        let limit = limits.listLimit
        return await context.listNotes(limit: limit)
    }
}

nonisolated struct ReadNoteTool: Tool {
    let context: ToolContext
    let limits: ToolLimits
    let name = "read_note"
    let description = "Read a note's Markdown, by its title or relative path."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The note's exact title or relative path, such as Welcome or Projects/Roadmap.md.")
        var note: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        let limit = limits.readCharacters
        return try await ToolOutcome.run {
            try await context.readNote(arguments.note, maxCharacters: limit)
        }
    }
}

nonisolated struct SearchNotesTool: Tool {
    let context: ToolContext
    let limits: ToolLimits
    let name = "search_notes"
    let description = "Search the collection's notes for words or a phrase. Returns matching note titles with a snippet from each."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The words to search for.")
        var query: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        let limit = limits.searchLimit
        return await context.searchNotes(arguments.query, limit: limit)
    }
}

nonisolated struct GrepTool: Tool {
    let context: ToolContext
    let limits: ToolLimits
    let name = "grep_collection"
    let description = "Find every line, across all notes, that contains some exact text (ignoring case). Returns the note title, line number and line."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The exact text to look for on each line.")
        var pattern: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        let limit = limits.grepLimit
        return await context.grep(arguments.pattern, limit: limit)
    }
}

// MARK: - Changing (approved by the person, committed to Git)

nonisolated struct CreateNoteTool: Tool {
    let context: ToolContext
    let name = "create_note"
    let description = "Create a new note. The person approves it before it is written."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The new note's title, which is also its file name.")
        var title: String
        @Guide(description: "The note's Markdown content.")
        var content: String
        @Guide(description: "A folder inside the collection to create it in. Leave out for the top level.")
        var folder: String?
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        try await ToolOutcome.run {
            try await context.createNote(title: arguments.title, content: arguments.content,
                                         folder: arguments.folder)
        }
    }
}

nonisolated struct EditNoteTool: Tool {
    let context: ToolContext
    let name = "edit_note"
    let description = "Replace exact text in a note. Read the note first and copy the text to replace exactly. The person approves the change."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The note's exact title or relative path.")
        var note: String
        @Guide(description: "The exact text to replace, with enough around it to appear only once.")
        var oldText: String
        @Guide(description: "The text to put in its place.")
        var newText: String
        @Guide(description: "True to replace every occurrence rather than requiring a single one.")
        var replaceAll: Bool
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        try await ToolOutcome.run {
            try await context.editNote(arguments.note, oldString: arguments.oldText,
                                       newString: arguments.newText, replaceAll: arguments.replaceAll)
        }
    }
}

nonisolated struct WriteNoteTool: Tool {
    let context: ToolContext
    let name = "write_note"
    let description = "Replace a note's entire content. Use edit_note for smaller changes. The person approves the change."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The note's exact title or relative path.")
        var note: String
        @Guide(description: "The note's complete new Markdown content.")
        var content: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        try await ToolOutcome.run {
            try await context.writeNote(arguments.note, content: arguments.content)
        }
    }
}

nonisolated struct DeleteNoteTool: Tool {
    let context: ToolContext
    let name = "delete_note"
    let description = "Move a note to the Trash. The person always confirms a deletion."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The note's exact title or relative path.")
        var note: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        try await ToolOutcome.run {
            try await context.deleteNote(arguments.note)
        }
    }
}
