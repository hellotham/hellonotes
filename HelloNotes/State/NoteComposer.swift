//
//  NoteComposer.swift
//  HelloNotes
//
//  Created by Chris Tham on 16/8/2026.
//
//  Composing and researching *into* the notebook.
//
//  Both jobs already had all their machinery. `create_note` and `write_note`
//  have existed since the agent shipped, and `DeepResearchTool` has been
//  decomposing questions, running web sub-agents and returning a cited synthesis
//  the whole time. What was missing was a front door — and, more than that, the
//  last step: research that ends as a chat reply is research you then have to
//  copy somewhere, and a note pasted in from outside arrives as an island. It
//  has no links, so nothing finds it again, which for a notebook is close to not
//  having it.
//
//  So the composer's real work is the connecting, and it is deliberately done in
//  two halves that fail differently. Before the model runs, the relatedness
//  index (`RelatednessIndex`) says which notes the prompt is *about*, and those
//  titles are offered as link targets. After it runs, every link it produced is
//  checked against the collection and the invented ones are unwrapped
//  (`ComposedNote`). The first half is a suggestion and is allowed to be wrong;
//  the second half is a guarantee and is not.
//

import Foundation

@MainActor
@Observable
final class NoteComposer {

    enum Phase: Equatable {
        case idle
        /// A human-readable stage, because research takes minutes and a
        /// spinner that never says what it is doing reads as a hang.
        case working(String)
        case ready(NoteDraft)
        case failed(String)
    }

    enum Mode: String, CaseIterable, Identifiable {
        case write, research
        var id: String { rawValue }

        var title: String {
            switch self {
            case .write: "Write"
            case .research: "Research"
            }
        }

        var needs: IntelligenceNeeds {
            switch self {
            case .write: .compose
            case .research: .deepResearch
            }
        }
    }

    private(set) var phase: Phase = .idle
    private var task: Task<Void, Never>?

    var isWorking: Bool { if case .working = phase { return true }; return false }

    /// How many of the collection's notes are offered to the model as link
    /// targets. Ten, matching the cap the Phase 4 measurement settled on for
    /// link proposals — the same index, the same reason: past ten, relatedness
    /// scores flatten out and the extra titles are noise the model then tries
    /// to find a use for.
    private static let relatedTitleLimit = 10

    // MARK: - Availability

    /// Why `mode` cannot run, or `nil` when it can.
    ///
    /// The two modes route to different providers, and that is not an oversight
    /// to be tidied away: writing a note is an intelligence feature and follows
    /// the intelligence provider (on-device by default, which is the right
    /// default for something composed from your own notes); research drives
    /// tools and web sub-agents, which is the assistant's provider. Collapsing
    /// them would force one of the two to be wrong.
    ///
    /// Static, and the single answer for both platforms *and* for
    /// `DeepResearchTool` itself — so the sheet can never offer a run that the
    /// tool then refuses, which is the failure mode that makes a feature look
    /// broken rather than unconfigured.
    static func unavailableReason(for mode: Mode, settings: LLMSettings) -> String? {
        switch mode {
        case .write:
            let intelligence = IntelligenceService(settings: settings)
            if case .unavailable(let why) = intelligence.availability { return why }
            guard intelligence.can(.compose) else {
                return "\(intelligence.providerName) can't hold enough context to write a note."
            }
            return nil

        case .research:
            let kind = settings.activeProvider
            guard settings.isReady(kind) else {
                return "\(kind.displayName) isn't set up. Add it in Assistant Settings, or choose another provider there."
            }
            let caps = ProviderCapabilities.of(kind, config: settings.config(for: kind))
            guard IntelligenceNeeds.deepResearch.satisfied(by: caps) else {
                return caps.toolUse
                    ? "\(kind.displayName) can't hold enough context for deep research."
                    : "\(kind.displayName) can't search the web. Research needs a provider that can call tools."
            }
            return nil
        }
    }

    // MARK: - Running

    func reset() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    /// Write a note from `prompt`, linking notes the collection already has.
    func compose(prompt: String, in collection: Collection, settings: LLMSettings) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        run { [weak self] in
            guard let self else { return }
            phase = .working("Finding related notes…")
            let related = await relatedTitles(to: prompt, in: collection)

            phase = .working("Writing…")
            let reply = try await IntelligenceService(settings: settings)
                .compose(prompt: prompt, relatedTitles: related)
            try Task.checkCancellation()

            let draft = ComposedNote.draft(
                from: reply, prompt: prompt, knownTitles: collection.notes.map(\.title))
            phase = draft.body.isEmpty
                ? .failed("The model returned an empty note.")
                : .ready(draft)
        }
    }

    /// Research `question` on the web and land the cited synthesis as a note.
    func research(question: String, depth: Int, context: ToolContext, settings: LLMSettings) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        run { [weak self] in
            guard let self else { return }
            let collection = context.collection
            phase = .working("Finding related notes…")
            let related = await relatedTitles(to: question, in: collection)

            // Deep research decomposes the question and runs a web sub-agent per
            // sub-question, so this is minutes, not seconds.
            phase = .working("Researching — this can take a few minutes…")
            let synthesis = try await DeepResearchTool().run(
                .object(["question": .string(researchBrief(question, offering: related)),
                         "depth": .int(depth)]),
                context: context)
            try Task.checkCancellation()

            phase = .working("Linking to your notes…")
            let draft = ComposedNote.researchDraft(
                question: question,
                synthesis: synthesis,
                knownTitles: collection.notes.map(\.title),
                date: Date())
            phase = draft.body.isEmpty
                ? .failed("The research returned nothing.")
                : .ready(draft)
        }
    }

    /// Create the note and return it.
    ///
    /// The draft is written whole rather than through `create_note`: that tool
    /// exists to gate the *model* acting unprompted, and this note is one the
    /// user asked for and has just read on screen. Putting an approval sheet in
    /// front of a draft they are looking at would be ceremony, not consent.
    func create(_ draft: NoteDraft, in collection: Collection) async -> Note? {
        guard let note = await collection.createNote(title: draft.title) else { return nil }
        do {
            try FileIO.write(Data(draft.markdown.utf8), to: note.fileURL)
        } catch {
            collection.lastError = "Couldn't write the note: \(error.localizedDescription)"
            return note
        }
        // The same path an ordinary save takes: it patches the link graph,
        // search and relatedness indexes, records the write so the file watcher
        // does not treat it as an external change, and uploads it on a cloud
        // collection. Reaching past it into the individual indexes is how a
        // composed note ends up invisible to Open Quickly.
        collection.noteDidSave(note.fileURL, text: draft.markdown)
        phase = .idle
        return note
    }

    // MARK: - Helpers

    /// The collection's notes most related to `text`.
    ///
    /// Falls back to nothing rather than to *something*: with no index built
    /// yet, an arbitrary handful of titles would be worse than none, because
    /// the model would dutifully find a way to link them.
    private func relatedTitles(to text: String, in collection: Collection) async -> [String] {
        guard collection.hasRelatednessIndex || !collection.notes.isEmpty else { return [] }
        let related = await collection.relatedNotes(
            to: text, excluding: nil, limit: Self.relatedTitleLimit)
        return related.map(\.title)
    }

    /// The question, plus the note titles the synthesiser may link.
    ///
    /// Deep research takes a single string, so the vault context has to travel
    /// inside it. That is also why the wording is explicit about the list being
    /// the user's own notes: without it the sub-agents treat the titles as
    /// search terms and go looking for them on the web.
    private func researchBrief(_ question: String, offering titles: [String]) -> String {
        guard !titles.isEmpty else { return question }
        return """
        \(question)

        The person asking keeps these notes of their own (titles only — they are \
        not web sources, and are not part of the question):
        \(titles.joined(separator: "\n"))

        In the final answer, where you genuinely refer to one of those topics, \
        link it as [[Exact Title]] using the title exactly as written above. \
        Keep citing web sources as URLs.
        """
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            do { try await work() }
            catch is CancellationError { phase = .idle }
            catch { phase = .failed(error.localizedDescription) }
        }
    }
}
