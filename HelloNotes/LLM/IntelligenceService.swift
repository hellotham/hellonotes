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

#if os(macOS)
import Foundation

@MainActor
struct IntelligenceService {
    let settings: LLMSettings

    private var provider: ProviderKind { settings.intelligenceProvider }
    private var isApple: Bool { provider == .apple }

    private static let maxInputChars = 6000

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
            user: "Summarize this note:\n\n\(clean(noteText))")
    }

    func expand(_ noteText: String) async throws -> String {
        if isApple { return try await NoteIntelligence.expand(noteText) }
        return try await complete(
            system: "You expand brief notes and outlines into clear, well-structured Markdown prose. Preserve the author's intent, headings and lists. Return only the expanded note, no preamble.",
            user: "Expand and flesh out this note:\n\n\(clean(noteText))")
    }

    func answer(question: String, context: [(title: String, text: String)]) async throws -> String {
        if isApple { return try await NoteIntelligence.answer(question: question, context: context) }
        let perNote = max(400, Self.maxInputChars / max(context.count, 1))
        let contextText = context
            .map { "## \($0.title)\n\(String($0.text.prefix(perNote)))" }
            .joined(separator: "\n\n")
        return try await complete(
            system: "You answer questions using ONLY the provided notes from the user's library. Cite the note titles you used in brackets like [Title]. If the notes don't contain the answer, say you couldn't find it in the library.",
            user: "Notes from my library:\n\n\(contextText)\n\nQuestion: \(question)")
    }

    func suggestTags(for noteText: String, existing: [String]) async throws -> [String] {
        if isApple { return try await NoteIntelligence.suggestTags(for: noteText, existing: existing) }
        let existingList = existing.isEmpty ? "none" : existing.joined(separator: ", ")
        let reply = try await complete(
            system: "You suggest topical tags for personal notes. Prefer reusing your existing tags when they fit. Reply with ONLY 3–6 short, lowercase, single-word tags separated by commas — no '#', no other text.",
            user: "Existing tags: \(existingList)\n\nNote:\n\(clean(noteText))")
        return normalizeTags(reply)
    }

    func suggestLinks(for noteText: String, candidates: [String]) async throws -> [String] {
        guard !candidates.isEmpty else { return [] }
        if isApple { return try await NoteIntelligence.suggestLinks(for: noteText, candidates: candidates) }
        let reply = try await complete(
            system: "You recommend which other notes to link from the current note. Choose ONLY from the candidate list. Reply with one exact title per line and nothing else.",
            user: "Candidate note titles:\n\(candidates.prefix(60).joined(separator: "\n"))\n\nCurrent note:\n\(clean(noteText))")
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

    private func clean(_ text: String) -> String {
        String(FrontMatter.body(of: text).prefix(Self.maxInputChars))
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
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-*0123456789. \t")) }
            .compactMap { byLower[$0.lowercased()] }
            .filter { seen.insert($0).inserted }
    }
}
#endif
