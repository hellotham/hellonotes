//
//  FoundationModelsIntelligence.swift
//  HelloNotes
//
//  On-device structured generation via Apple's Foundation Models (macOS/iOS 26):
//  `@Generable` guided outputs for note titles + tags, and a vault-search `Tool`
//  so "Ask Library" can answer grounded questions offline. Availability- and
//  `canImport`-gated so the app still builds on the macOS 15 floor.
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// Structured suggestion for a note (title + topic tags), guided so the model
/// returns exactly this shape.
@available(macOS 26.0, iOS 26.0, *)
@Generable
struct NoteSuggestion {
    @Guide(description: "A concise, descriptive title for the note (3–8 words, no Markdown).")
    var title: String

    @Guide(description: "Lowercase topic tags without a leading '#'.", .count(3...6))
    var tags: [String]
}

/// A Foundation Models tool that searches the user's notes. The actual search is
/// injected (the app owns the index + security-scoped access).
@available(macOS 26.0, iOS 26.0, *)
struct VaultSearchTool: Tool {
    let name = "search_notes"
    let description = "Search the user's notes and return the most relevant passages."
    let search: @Sendable (String) -> [String]

    @Generable
    struct Arguments {
        @Guide(description: "What to search the notes for.")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        let hits = search(arguments.query).prefix(5)
        return hits.isEmpty ? "No matching notes." : hits.joined(separator: "\n---\n")
    }
}

@available(macOS 26.0, iOS 26.0, *)
enum FoundationModelsIntelligence {
    /// True when the on-device model is available (hardware + Apple Intelligence).
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Suggest a title + topic tags for `content`, guided to the `NoteSuggestion`
    /// shape — no parsing, no hallucinated structure.
    static func suggest(for content: String) async throws -> NoteSuggestion {
        let session = LanguageModelSession()
        let prompt = "Suggest a title and topic tags for this note:\n\n\(String(content.prefix(4000)))"
        return try await session.respond(to: prompt, generating: NoteSuggestion.self).content
    }

    /// Answer `question` grounded in the user's notes, via the vault-search tool.
    /// `search` maps a query to matching snippets (injected by the app).
    static func answer(question: String, search: @escaping @Sendable (String) -> [String]) async throws -> String {
        let session = LanguageModelSession(
            tools: [VaultSearchTool(search: search)],
            instructions: "Answer the user's question using their notes. Search first, then answer concisely and cite the note titles you used. If the notes don't cover it, say so.")
        return try await session.respond(to: question).content
    }
}
#endif
