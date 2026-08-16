//
//  IntelligenceService.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Routes the "intelligence" features — Summarize, Suggest Tags/Links, Expand,
//  and Ask Library — through the user's chosen intelligence provider. Apple
//  Intelligence (the default) uses the on-device structured path in
//  NoteIntelligence; every other provider runs a one-shot completion through the
//  shared LLM layer and parses the result.
//
//  How much text each feature sends is decided by the provider's *declared*
//  capabilities (`ProviderCapabilities`) rather than by one shared constant.
//  A single 6,000-character cap was two wrong numbers at once: too much for the
//  on-device model's context, and a fraction of what a frontier model would
//  happily read for Ask Library.
//

import Foundation

@MainActor
struct IntelligenceService {
    let settings: LLMSettings

    private var provider: ProviderKind { settings.intelligenceProvider }
    private var isApple: Bool { provider == .apple }

    /// What the chosen provider can do. Read per call rather than stored: the
    /// user can change providers in Settings while a panel is open.
    var capabilities: ProviderCapabilities { provider.capabilities }

    /// Whether `feature` can run on the chosen provider at all.
    func can(_ feature: IntelligenceNeeds) -> Bool {
        isAvailable && feature.satisfied(by: capabilities)
    }

    // MARK: - Availability

    var availability: IntelligenceAvailability {
        if isApple { return NoteIntelligence.availability }
        if settings.isReady(provider) { return .available }
        return .unavailable("\(provider.displayName) isn't set up. Add it in Assistant Settings, or change the intelligence provider there.")
    }

    var isAvailable: Bool {
        if case .available = availability { return true }
        return false
    }

    var providerName: String { provider.displayName }

    // MARK: - Actions

    func summarize(_ noteText: String) async throws -> String {
        if isApple { return try await NoteIntelligence.summarize(noteText) }
        return try await complete(
            system: "You summarize personal notes. Reply with 2–4 concise sentences capturing the key points. No preamble.",
            user: "Summarize this note:\n\n\(clean(noteText, for: .summarise))")
    }

    func expand(_ noteText: String) async throws -> String {
        if isApple { return try await NoteIntelligence.expand(noteText) }
        return try await complete(
            system: "You expand brief notes and outlines into clear, well-structured Markdown prose. Preserve the author's intent, headings and lists. Return only the expanded note, no preamble.",
            user: "Expand and flesh out this note:\n\n\(clean(noteText, for: .rewrite))")
    }

    func answer(question: String, context: [(title: String, text: String)]) async throws -> String {
        if isApple { return try await NoteIntelligence.answer(question: question, context: context) }
        // Share the provider's budget across the retrieved notes rather than a
        // fixed cap: a frontier model can read four notes nearly whole, and
        // truncating them to 1,500 characters each was throwing away most of
        // the retrieval this feature exists to do.
        let perNote = max(400, budget(for: .askLibrary) / max(context.count, 1))
        let contextText = context
            .map { "## \($0.title)\n\(String($0.text.prefix(perNote)))" }
            .joined(separator: "\n\n")
        return try await complete(
            system: "You answer questions using ONLY the provided notes from the user's library. Cite the note titles you used in brackets like [Title]. If the notes don't contain the answer, say you couldn't find it in the library.",
            user: "Notes from my library:\n\n\(contextText)\n\nQuestion: \(question)")
    }

    /// Rewrite a passage per the user's instruction (the editor's
    /// rewrite-selection feature). Returns only the rewritten text.
    func rewrite(_ text: String, instruction: String) async throws -> String {
        if isApple { return try await NoteIntelligence.rewrite(text, instruction: instruction) }
        return try await complete(
            system: """
            You rewrite passages from the user's Markdown notes. Follow the rewrite \
            instruction faithfully. Keep Markdown syntax (links, emphasis, lists, \
            headings) intact unless the instruction says otherwise. Reply with ONLY \
            the rewritten text — no preamble, no quotes, no code fences.
            """,
            user: "Instruction: \(instruction)\n\nText:\n\(String(text.prefix(budget(for: .rewrite))))",
            temperature: 0.4)
    }

    func suggestTags(for noteText: String, existing: [String]) async throws -> [String] {
        if isApple {
            // Prefer guided (@Generable) structured output on the on-device model:
            // it returns clean tags directly, with no fragile reply-parsing.
            #if canImport(FoundationModels)
            if #available(macOS 26.0, iOS 26.0, *), FoundationModelsIntelligence.isAvailable {
                return try await FoundationModelsIntelligence.suggest(for: noteText).tags
            }
            #endif
            return try await NoteIntelligence.suggestTags(for: noteText, existing: existing)
        }
        let existingList = existing.isEmpty ? "none" : existing.joined(separator: ", ")
        let reply = try await complete(
            system: "You suggest topical tags for personal notes. Prefer reusing your existing tags when they fit. Reply with ONLY 3–6 short, lowercase, single-word tags separated by commas — no '#', no other text.",
            user: "Existing tags: \(existingList)\n\nNote:\n\(clean(noteText, for: .suggestTags))")
        return normalizeTags(reply)
    }

    func suggestLinks(for noteText: String, candidates: [String]) async throws -> [String] {
        guard !candidates.isEmpty else { return [] }
        if isApple { return try await NoteIntelligence.suggestLinks(for: noteText, candidates: candidates) }
        let reply = try await complete(
            system: "You recommend which other notes to link from the current note. Choose ONLY from the candidate list. Reply with one exact title per line and nothing else.",
            user: "Candidate note titles:\n\(candidates.prefix(60).joined(separator: "\n"))\n\nCurrent note:\n\(clean(noteText, for: .suggestLinks))")
        return matchTitles(reply, candidates: candidates)
    }

    // MARK: - Generic provider path

    private func complete(system: String, user: String, temperature: Double = 0.3) async throws -> String {
        let (llm, model) = try ProviderFactory.make(for: provider, settings: settings)
        let ctx = LLMContext(systemPrompt: system, messages: [LLMMessage(role: .user, text: user)])
        var output = ""
        for try await event in llm.stream(ctx, model: model, options: LLMRequestOptions(temperature: temperature)) {
            if case .textDelta(let delta) = event { output += delta }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    /// How many characters of input `feature` may send to this provider: what
    /// the feature would like, capped by what the provider can hold.
    private func budget(for feature: IntelligenceNeeds) -> Int {
        max(500, min(feature.inputBudget, capabilities.inputBudget))
    }

    /// The note's body (front matter is metadata, not content), trimmed to the
    /// budget for `feature`.
    private func clean(_ text: String, for feature: IntelligenceNeeds) -> String {
        String(FrontMatter.body(of: text).prefix(budget(for: feature)))
    }

    private func normalizeTags(_ reply: String) -> [String] {
        var seen = Set<String>()
        return reply
            .split { $0 == "," || $0 == "\n" || $0 == " " }
            .map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "#. ")) }
            .filter { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "/" || $0 == "-" || $0 == "_" } }
            .filter { seen.insert($0).inserted }
    }

    private func matchTitles(_ reply: String, candidates: [String]) -> [String] {
        let byLower = Dictionary(candidates.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        return reply.split(separator: "\n")
            .map { line -> String in
                // Strip only a LEADING list marker ("1. ", "- ", "* "). A both-
                // ends character trim would mangle titles that begin or end with
                // a digit/dot ("2026 Goals" → "Goals", "1984" → ""), silently
                // dropping the link suggestion.
                let t = line.trimmingCharacters(in: .whitespaces)
                if let m = t.range(of: #"^([-*+]|\d+[.)])\s+"#, options: .regularExpression) {
                    return String(t[m.upperBound...])
                }
                return t
            }
            .compactMap { byLower[$0.lowercased()] }
            .filter { seen.insert($0).inserted }
    }
}
