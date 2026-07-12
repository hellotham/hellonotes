//
//  NoteIntelligence.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//
//  On-device note intelligence via Apple's Foundation Models framework
//  (macOS 26+). Entirely app-level and independent of the editor: it reads a
//  note's text and returns a summary, suggested tags, or suggested links.
//

#if os(macOS)
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether on-device intelligence can run, and why not when it can't.
enum IntelligenceAvailability {
    case available
    case unavailable(String)
}

@available(macOS 26.0, *)
@Generable
struct SuggestedTags {
    @Guide(description: "3 to 6 short, lowercase, single-word topical tags with no '#'")
    var tags: [String]
}

@available(macOS 26.0, *)
@Generable
struct SuggestedLinks {
    @Guide(description: "Titles, chosen only from the provided candidate list, of notes most related to this one")
    var titles: [String]
}

/// Facade over Foundation Models. Gracefully degrades to `.unavailable` on OSes
/// or devices without the on-device model.
struct NoteIntelligence {

    /// Trim very long notes so a request stays within the model's context.
    private static let maxInputChars = 6000

    static var availability: IntelligenceAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(.deviceNotEligible):
                return .unavailable("This Mac doesn't support Apple Intelligence.")
            case .unavailable(.appleIntelligenceNotEnabled):
                return .unavailable("Turn on Apple Intelligence in System Settings to use this.")
            case .unavailable(.modelNotReady):
                return .unavailable("The on-device model is still downloading. Try again shortly.")
            case .unavailable:
                return .unavailable("On-device intelligence is unavailable right now.")
            }
        }
        #endif
        return .unavailable("Requires macOS 26 or later.")
    }

    static var isAvailable: Bool {
        if case .available = availability { return true }
        return false
    }

    // MARK: - Actions

    static func summarize(_ noteText: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(
                instructions: "You summarize personal notes. Reply with 2–4 concise sentences capturing the key points. No preamble."
            )
            let response = try await session.respond(to: "Summarize this note:\n\n\(clean(noteText))")
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        throw IntelligenceError.unavailable
    }

    static func suggestTags(for noteText: String, existing: [String]) async throws -> [String] {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let existingList = existing.isEmpty ? "none" : existing.joined(separator: ", ")
            let session = LanguageModelSession(
                instructions: "You suggest topical tags for personal notes. Prefer reusing your existing tags when they fit."
            )
            let prompt = """
            Existing tags: \(existingList)

            Note:
            \(clean(noteText))
            """
            let response = try await session.respond(to: prompt, generating: SuggestedTags.self)
            return normalize(response.content.tags)
        }
        #endif
        throw IntelligenceError.unavailable
    }

    static func expand(_ noteText: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(
                instructions: "You expand brief notes and outlines into clear, well-structured Markdown prose. Preserve the author's intent, headings, and any lists. Return only the expanded note, no preamble."
            )
            let response = try await session.respond(to: "Expand and flesh out this note:\n\n\(clean(noteText))")
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        throw IntelligenceError.unavailable
    }

    /// Answer a question grounded in the supplied collection notes, citing titles.
    static func answer(question: String, context: [(title: String, text: String)]) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(
                instructions: "You answer questions using ONLY the provided notes from the user's library. Cite the note titles you used, in brackets like [Title]. If the notes don't contain the answer, say you couldn't find it in the library."
            )
            // Budget the context across notes so the whole prompt stays in-window.
            let perNote = max(400, maxInputChars / max(context.count, 1))
            let contextText = context
                .map { "## \($0.title)\n\(String($0.text.prefix(perNote)))" }
                .joined(separator: "\n\n")
            let prompt = "Notes from my library:\n\n\(contextText)\n\nQuestion: \(question)"
            let response = try await session.respond(to: prompt)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        throw IntelligenceError.unavailable
    }

    static func suggestLinks(for noteText: String, candidates: [String]) async throws -> [String] {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard !candidates.isEmpty else { return [] }
            let session = LanguageModelSession(
                instructions: "You recommend which other notes to link from the current note. Only choose from the candidate list."
            )
            let prompt = """
            Candidate note titles:
            \(candidates.prefix(60).joined(separator: "\n"))

            Current note:
            \(clean(noteText))
            """
            let response = try await session.respond(to: prompt, generating: SuggestedLinks.self)
            // Keep only real candidates (case-insensitive), preserving the model's order.
            let byLower = Dictionary(candidates.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
            var seen = Set<String>()
            return response.content.titles.compactMap { byLower[$0.lowercased()] }
                .filter { seen.insert($0).inserted }
        }
        #endif
        throw IntelligenceError.unavailable
    }

    // MARK: - Helpers

    private static func clean(_ text: String) -> String {
        let body = FrontMatter.body(of: text)
        return String(body.prefix(maxInputChars))
    }

    private static func normalize(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags
            .map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
            .filter { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "/" || $0 == "-" || $0 == "_" } }
            .filter { seen.insert($0).inserted }
    }
}

enum IntelligenceError: Error {
    case unavailable
}
#endif
