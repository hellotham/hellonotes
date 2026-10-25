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
    /// A note tool's result where nothing shares out a turn's room — a tool on
    /// its own: a quarter of the window, in tokens. In an Assistant
    /// conversation, and in each of Research's questions, a result takes what
    /// the turn has left instead (`TurnRoom`). There were counts — six search
    /// results, or ten, twenty lines of exact-text search, sixty titles —
    /// whatever the window, and a search on Cloud (Apple)'s 32K showed ten
    /// notes of the hundreds that matched (the person, 2026-10-18: "There's
    /// plenty of tokens left to return all entries and let the model
    /// summarise").
    let resultTokens: Int
    /// A web page's cap: a sixth of the window, in tokens, from 500 to 5,333 —
    /// what the 1,500 and 16,000 characters it was in characters came to at
    /// three a token, which is what a Chinese page is not.
    let fetchTokens: Int

    init(contextTokens: Int) {
        resultTokens = max(500, contextTokens / 4)
        fetchTokens = min(5_333, max(500, contextTokens / 6))
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
    /// The tools that send something off the device. A session holding any of
    /// them is one the app says so about (`LanguageModels.webSummary`).
    nonisolated static let webToolNames: Set<String> = ["web_search", "web_fetch", "deep_research"]

    /// Whether a session with `tools` can reach the web.
    nonisolated static func reachesTheWeb(_ toolNames: some Sequence<String>) -> Bool {
        toolNames.contains { webToolNames.contains($0) }
    }

    /// The tools for a session, chosen by the model's window.
    ///
    /// Apple's guidance for the on-device model is three to five tools a
    /// request: every definition is instructions the model must read before the
    /// person's question, and a small window spent on schemas is a window not
    /// spent on notes. So a small window gets the few that carry the
    /// Assistant's purpose — find, read, and look something up —
    /// and a large one gets the full set.
    @MainActor
    static func tools(for context: ToolContext, contextTokens: Int, room: TurnRoom? = nil) -> [any Tool] {
        let limits = ToolLimits(contextTokens: contextTokens)
        let hasSkills = !(context.skills?.skills.isEmpty ?? true)

        // **It reads and answers; it changes nothing (1.3.5).** Creating,
        // editing, rewriting and deleting notes are left out until they are
        // designed properly — the person's decision, 2026-10-18. The tools stay
        // written (`CreateNoteTool` … `DeleteNoteTool`, approvals and all) for
        // the release that brings them back; nothing offers them meanwhile.
        //
        // Exact-text search is on every model now: it is cheap, and on the
        // on-device model it was the only way to find a line past where
        // `read_note` stops reading.
        guard contextTokens >= 16_000 else {
            var compact: [any Tool] = [
                SearchNotesTool(context: context, limits: limits, room: room),
                ReadNoteTool(context: context, limits: limits, room: room),
                GrepTool(context: context, limits: limits, room: room),
                WebSearchTool(room: room),
            ]
            if hasSkills { compact.append(LoadSkillTool(context: context)) }
            return compact
        }

        var full: [any Tool] = [
            SearchNotesTool(context: context, limits: limits, room: room),
            ReadNoteTool(context: context, limits: limits, room: room),
            ListNotesTool(context: context, limits: limits, room: room),
            GrepTool(context: context, limits: limits, room: room),
            WebSearchTool(room: room),
            WebFetchTool(limits: limits, room: room),
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
    /// The Assistant turn's room, which results asked for together share (`TurnRoom`).
    var room: TurnRoom? = nil
    let name = "list_notes"
    let description = "List the collection's notes by title and path. Prefer search_notes to find something specific."

    @Generable
    nonisolated struct Arguments {}

    @concurrent func call(arguments: Arguments) async throws -> String {
        await context.listNotes(tokens: limits.resultTokens, room: room)
    }
}

nonisolated struct ReadNoteTool: Tool {
    let context: ToolContext
    let limits: ToolLimits
    /// The Assistant turn's room, which results asked for together share (`TurnRoom`).
    var room: TurnRoom? = nil
    let name = "read_note"
    let description = "Read a note's Markdown, by its title or relative path — from the top, or from one of its sections. A long note is cut off, and the cut names the sections after it."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The note's exact title or relative path, such as Welcome or Projects/Roadmap.md.")
        var note: String
        @Guide(description: "A heading in the note to start reading from. Leave out to read from the top.")
        var section: String?
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        try await ToolOutcome.run {
            try await context.readNote(arguments.note, tokens: limits.resultTokens, section: arguments.section, room: room)
        }
    }
}

nonisolated struct SearchNotesTool: Tool {
    let context: ToolContext
    let limits: ToolLimits
    /// The Assistant turn's room, which results asked for together share (`TurnRoom`).
    var room: TurnRoom? = nil
    let name = "search_notes"
    let description = "Search the collection's notes for words or a phrase. Returns matching note titles with a snippet from each."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The words to search for.")
        var query: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await context.searchNotes(arguments.query, tokens: limits.resultTokens, room: room)
    }
}

nonisolated struct GrepTool: Tool {
    let context: ToolContext
    let limits: ToolLimits
    /// The Assistant turn's room, which results asked for together share (`TurnRoom`).
    var room: TurnRoom? = nil
    let name = "grep_collection"
    let description = "Find every line, across all notes, that contains some exact text (ignoring case). Returns each line with its note, the section it is in, and its line number."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The exact text to look for on each line.")
        var pattern: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await context.grep(arguments.pattern, tokens: limits.resultTokens, room: room)
    }
}

// MARK: - Changing (approved by the person, committed to Git)

nonisolated struct CreateNoteTool: Tool {
    let context: ToolContext
    let name = "create_note"
    let description = "Create a new note. Calling this shows the person the note, and it is written only if they approve."

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
    let description = "Replace exact text in a note. Read the note first and copy the text to replace exactly. Calling this shows the person the change, and it is saved only if they approve."

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
    let description = "Replace a note's entire content. Use edit_note for smaller changes. Calling this shows the person the change, and it is saved only if they approve."

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
    let description = "Move a note to the Trash. Calling this asks the person to confirm the deletion first."

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
