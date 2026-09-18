//
//  IntelligenceService.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  The writing tools — Summarise, Suggest Tags and Links, Rewrite, Expand,
//  Compose, Ask Library and ghost text — on whichever model the person chose.
//
//  One code path now. There were two: a structured Foundation Models path for
//  Apple's on-device model and a prompt-and-parse path for everything else,
//  each with its own copy of every instruction. Every model the app can reach is
//  a Foundation Models `LanguageModel`, so every feature is one
//  `LanguageModelSession` — and guided generation (`@Generable`) is available on
//  all three, so tags and links arrive as lists rather than as prose to parse.
//
//  **Budgets are measured.** Each request plans its input against the model's
//  own context size, minus its instructions and a reserve for the reply
//  (`TokenBudget`). What happens when a note does not fit depends on what the
//  feature promises:
//
//  * A **summary** of a long note summarises all of it — in parts, then the
//    parts. Summarising the first 4,000 characters and calling it a summary of
//    the note was the defect `ProviderCapabilities` was written to stop.
//  * A **rewrite** refuses. It replaces the selection, so rewriting only the part
//    that fits would delete the rest — which the old path did, silently.
//  * **Tags and links** read the opening of a long note. They are suggestions,
//    and a note's opening is a fair basis for one.
//

import Foundation
import FoundationModels
import NaturalLanguage

@Generable
nonisolated struct SuggestedTags {
    @Guide(description: "3 to 6 broad topics this note is about, each one or two lowercase words, like cooking, travel or planning. Not names, places or phrases copied from the note.",
           .count(3...6))
    var tags: [String]
}

@MainActor
struct IntelligenceService {
    let settings: IntelligenceSettings

    private var models: LanguageModels { settings.models }
    private var choice: ModelChoice { settings.model }

    // MARK: - What the chosen model is

    var availability: IntelligenceAvailability { models.availability(of: choice) }
    var isAvailable: Bool { availability.isAvailable }

    /// The model's name — "System model", "Private Cloud Compute",
    /// "gemma-4-31b-it-4bit" — so a menu can say who does the work.
    var modelName: String { models.name(of: choice) }

    var runsOnDevice: Bool { choice.runsOnDevice }

    /// Ghost text has to appear between keystrokes, and a network round trip
    /// cannot — so it runs only on a model on this device.
    var supportsInlineCompletion: Bool { isAvailable && runsOnDevice }

    // MARK: - Features

    func summarize(_ noteText: String) async throws -> String {
        let body = FrontMatter.body(of: noteText)
        return try await perform(purpose: .transforming) { model, window in
            let budget = TokenBudget.inputTokens(context: window, instructions: Prompts.summarise, reply: 500)
            // Splitting a long note walks all of it — about 30 ms at 1 MB,
            // measured — so it happens off the main actor.
            let parts = await offMain { TokenBudget.chunks(body, tokens: budget) }
            guard parts.count > 1 else {
                return try await respond(model, instructions: Prompts.summarise,
                                         prompt: "Summarize this note:\n\n\(body)", temperature: 0.3)
            }
            guard parts.count <= 32 else {
                throw IntelligenceError.failed("This note is too long to summarise on \(modelName). A model with a larger context — \(LanguageModels.largerModels) — can read more at once.")
            }
            // Map: one summary per part, each in a fresh session.
            var summaries: [String] = []
            for (index, part) in parts.enumerated() {
                try Task.checkCancellation()
                summaries.append(try await respond(
                    model, instructions: Prompts.summarisePart,
                    prompt: "Part \(index + 1) of \(parts.count):\n\n\(part)", temperature: 0.2))
            }
            // Reduce: summarise the summaries, in as many rounds as it takes.
            var combined = summaries.joined(separator: "\n\n")
            while TokenBudget.estimate(combined) > budget {
                try Task.checkCancellation()
                var next: [String] = []
                for group in TokenBudget.chunks(combined, tokens: budget) {
                    next.append(try await respond(model, instructions: Prompts.summarisePart,
                                                  prompt: group, temperature: 0.2))
                }
                combined = next.joined(separator: "\n\n")
            }
            return try await respond(
                model, instructions: Prompts.summarise,
                prompt: "These are summaries of consecutive parts of one note. Summarize the whole note:\n\n\(combined)",
                temperature: 0.3)
        }
    }

    /// Continue the text before the caret (ghost text).
    ///
    /// No trimming of the reply: a **leading space is part of the answer** — it
    /// joins the continuation to the word before it — and the caller slices a
    /// bounded window ending exactly at the caret, front matter included,
    /// because the caret may well be *in* it.
    func completeInline(prefix: String, suffix: String) async throws -> String {
        guard runsOnDevice else { return "" }
        return try await perform(purpose: .transforming) { model, _ in
            let session = LanguageModelSession(model: model, instructions: InlineCompletionPrompt.instructions)
            return try await session.respond(
                to: InlineCompletionPrompt.user(prefix: prefix, suffix: suffix),
                options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 48)
            ).content
        }
    }

    /// Write a new note from a prompt, offering `relatedTitles` as link targets.
    func compose(prompt: String, relatedTitles: [String]) async throws -> String {
        try await perform(purpose: .general) { model, window in
            let budget = TokenBudget.inputTokens(context: window, instructions: ComposePrompt.instructions, reply: 1_500)
            return try await respond(
                model, instructions: ComposePrompt.instructions,
                // ComposePrompt spends its budget in characters; three to a
                // token is the conservative end for the titles it lists.
                prompt: ComposePrompt.user(prompt: prompt, titles: relatedTitles, budget: budget * 3),
                temperature: 0.5)
        }
    }

    func expand(_ noteText: String) async throws -> String {
        try await perform(purpose: .transforming) { model, window in
            // The reply is the note, larger — so the note may use a third of
            // what is left and the expansion the rest.
            let budget = TokenBudget.inputTokens(context: window, instructions: Prompts.expand, reply: 0) / 3
            let body = FrontMatter.body(of: noteText)
            guard TokenBudget.estimate(body) <= budget else {
                throw IntelligenceError.failed("This note is too long to expand on \(modelName). Try a shorter note, or choose \(LanguageModels.largerModels) in AI settings.")
            }
            return try await respond(model, instructions: Prompts.expand,
                                     prompt: "Expand and flesh out this note:\n\n\(body)", temperature: 0.5)
        }
    }

    /// Answer a question grounded in `context`, the notes retrieval found.
    func answer(question: String, context: [(title: String, text: String)]) async throws -> String {
        try await perform(purpose: .general) { model, window in
            // The window, shared across the retrieved notes. A note that does
            // not fit whole contributes its opening, and says so.
            let budget = TokenBudget.inputTokens(context: window, instructions: Prompts.answer, reply: 800)
                - TokenBudget.estimate(question)
            let perNote = max(200, budget / max(context.count, 1))
            let notes = await offMain {
                context.map { note -> String in
                    let (text, truncated) = TokenBudget.prefix(FrontMatter.body(of: note.text), tokens: perNote)
                    return "## \(note.title)\n\(text)\(truncated ? "\n(…the rest of this note was left out)" : "")"
                }.joined(separator: "\n\n")
            }
            return try await respond(model, instructions: Prompts.answer,
                                     prompt: "Notes from my library:\n\n\(notes)\n\nQuestion: \(question)",
                                     temperature: 0.3)
        }
    }

    /// Rewrite a passage per the person's instruction. Returns only the
    /// rewritten text.
    func rewrite(_ text: String, instruction: String) async throws -> String {
        try await perform(purpose: .transforming) { model, window in
            // Input and output are about the same size, so each gets half.
            let budget = TokenBudget.inputTokens(context: window, instructions: Prompts.rewrite, reply: 0) / 2
                - TokenBudget.estimate(instruction)
            guard TokenBudget.estimate(text) <= budget else {
                throw IntelligenceError.failed("That passage is too long to rewrite on \(modelName) in one go. Select a shorter passage, or choose \(LanguageModels.largerModels) in AI settings.")
            }
            return try await respond(model, instructions: Prompts.rewrite,
                                     prompt: "Instruction: \(instruction)\n\nText:\n\(text)", temperature: 0.4)
        }
    }

    func suggestTags(for noteText: String, existing: [String]) async throws -> [String] {
        try await perform(purpose: .general) { model, window in
            let existingList = existing.isEmpty ? "none" : existing.prefix(200).joined(separator: ", ")
            let body = FrontMatter.body(of: noteText)
            let instructions = Prompts.tags(language: Self.languageName(of: body))
            let budget = TokenBudget.inputTokens(context: window, instructions: instructions, reply: 200)
                - TokenBudget.estimate(existingList)
            let (opening, _) = await offMain { TokenBudget.prefix(body, tokens: max(200, budget)) }
            let session = LanguageModelSession(model: model, instructions: instructions)
            let response = try await session.respond(
                to: "Existing tags: \(existingList)\n\nNote:\n\(opening)",
                generating: SuggestedTags.self,
                options: GenerationOptions(temperature: 0.2))
            return Self.normalizeTags(response.content.tags)
        }
    }

    /// Which of `candidates` this note should link to, in the model's order.
    ///
    /// The titles are a **schema**, not a request: the reply is constrained to
    /// be a list drawn from exactly these strings, so a title the model invents
    /// cannot be produced at all. The old path asked nicely and then filtered.
    func suggestLinks(for noteText: String, candidates: [String]) async throws -> [String] {
        // Unique and non-empty: a schema's choices must be distinct strings.
        var unique = Set<String>()
        let candidates = candidates.filter { !$0.isEmpty && unique.insert($0).inserted }.prefix(60)
        guard !candidates.isEmpty else { return [] }
        return try await perform(purpose: .general) { model, window in
            let title = DynamicGenerationSchema(name: "NoteTitle", anyOf: Array(candidates))
            let schema = try GenerationSchema(
                root: DynamicGenerationSchema(
                    name: "SuggestedLinks",
                    properties: [.init(name: "titles",
                                       description: "The candidate notes most related to this one, best first.",
                                       schema: DynamicGenerationSchema(arrayOf: title, minimumElements: 0, maximumElements: 5))]),
                dependencies: [])
            let listing = candidates.joined(separator: "\n")
            let budget = TokenBudget.inputTokens(context: window, instructions: Prompts.links, reply: 300)
                - TokenBudget.estimate(listing) * 2   // the list appears in the schema too
            let (body, _) = await offMain { TokenBudget.prefix(FrontMatter.body(of: noteText), tokens: max(200, budget)) }
            let session = LanguageModelSession(model: model, instructions: Prompts.links)
            let response = try await session.respond(
                to: "Candidate notes:\n\(listing)\n\nCurrent note:\n\(body)",
                schema: schema,
                options: GenerationOptions(temperature: 0.2))
            let chosen = (try? response.content.value([String].self, forProperty: "titles")) ?? []
            var seen = Set<String>()
            return chosen.filter { candidates.contains($0) && seen.insert($0).inserted }
        }
    }

    // MARK: - Running a request

    /// Resolve the model, run `work`, and put any failure in words.
    private func perform<T>(purpose: LanguageModels.Purpose,
                            _ work: (any LanguageModel, Int) async throws -> T) async throws -> T {
        let name = modelName
        do {
            let model = try models.model(for: choice, purpose: purpose)
            let window = await models.contextSize(of: choice)
            return try await work(model, window)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as IntelligenceError {
            throw error
        } catch {
            throw IntelligenceError.failed(IntelligenceService.describe(error, modelName: name))
        }
    }

    private func respond(_ model: any LanguageModel, instructions: String, prompt: String,
                         temperature: Double) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: instructions)
        let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: temperature))
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func describe(_ error: any Error, modelName: String) -> String {
        IntelligenceError.describe(error, modelName: modelName)
    }

    // MARK: - Helpers

    /// Tags as a tag can be written: lowercase, no `#`, and **a space becomes a
    /// hyphen**. A tag cannot contain a space, and models answer with topics
    /// like "task groups"; dropping those left notes with no suggestions at all.
    nonisolated static func normalizeTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags
            .map { tag in
                tag.lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#. ").union(.whitespacesAndNewlines))
                    .split(whereSeparator: \.isWhitespace).joined(separator: "-")
            }
            .filter { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "/" || $0 == "-" || $0 == "_" } }
            .filter { seen.insert($0).inserted }
    }

    /// The name of the language `text` is written in, when it can be told.
    ///
    /// Named in the instructions because that is what the model follows: a
    /// schema description saying "in the note's language" was ignored, while
    /// "The note is written in Chinese, Simplified" produced Chinese tags.
    nonisolated static func languageName(of text: String) -> String? {
        guard let language = NLLanguageRecognizer.dominantLanguage(for: String(text.prefix(2_000))),
              language != .undetermined else { return nil }
        return Locale(identifier: "en").localizedString(forIdentifier: language.rawValue)
    }
}

/// The instructions each feature runs under. Each is written once.
///
/// Nothing from a note ever goes in here — note text travels in the prompt,
/// where the model treats it as material to work on rather than as the app's
/// own directions.
nonisolated enum Prompts {
    static let summarise = "You summarize personal notes. Reply with 2–4 concise sentences capturing the key points. No preamble."
    static let summarisePart = "You summarize one part of a longer note. Reply with the key points of this part in a few sentences. No preamble."
    static let expand = "You expand brief notes and outlines into clear, well-structured Markdown prose. Preserve the author's intent, headings and lists. Return only the expanded note, no preamble."
    static let answer = "You answer questions using ONLY the provided notes from the person's library. Cite the note titles you used in brackets, like [Title]. If the notes don't contain the answer, say you couldn't find it in the library."
    static let rewrite = """
    You rewrite passages from the person's Markdown notes. Follow the rewrite instruction faithfully. \
    Keep Markdown syntax (links, emphasis, lists, headings) intact unless the instruction says otherwise. \
    Reply with ONLY the rewritten text — no preamble, no quotes, no code fences.
    """
    static func tags(language: String?) -> String {
        var text = "You suggest topical tags for personal notes. Prefer reusing the person's existing tags when they fit."
        if let language { text += " The note is written in \(language). Write every tag in \(language)." }
        return text
    }
    static let links = "You recommend which of the person's other notes are worth linking from the current note, choosing only from the candidates."
}
