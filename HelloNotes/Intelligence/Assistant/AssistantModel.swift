//
//  AssistantModel.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  The Assistant's view model: one long-lived `LanguageModelSession` per
//  collection, the conversation it has had, and sending, stopping and clearing.
//
//  What used to be here — a hand-written loop that streamed a turn, gathered
//  tool calls, ran them, appended their results and went round again, with an
//  iteration cap and a final tool-less turn — is what a Foundation Models session
//  does itself. What remains is what is actually the app's: which model, which
//  tools for which window, keeping the conversation across launches, and saying
//  clearly what went wrong.
//
//  The session is rebuilt, carrying the conversation, whenever something it was
//  built from changes: the model, the collection, agent mode, the creativity or
//  reasoning setting. Tools and instructions are fixed for a session's life —
//  changing them mid-session discards the model's cached work on them.
//

import Foundation
import FoundationModels
import Observation

@MainActor
@Observable
final class AssistantModel {
    let settings: IntelligenceSettings

    var input = ""
    /// The conversation: prompts, responses, reasoning, tool calls and results.
    private(set) var entries: [Transcript.Entry] = [] {
        didSet { stampNewReplies() }
    }

    /// Where each reply was made, by its entry's id (`ModelStamp`) — taken as
    /// the turn began, because the model can change while a conversation goes
    /// on. Kept beside the transcript; a reply from before this was kept has
    /// none, and says nothing rather than guess.
    private(set) var stamps: [String: ModelStamp] = [:]
    /// The turn under way: the model it runs on, and the replies there were
    /// before it, which are not this turn's to stamp.
    private var turn: (stamp: ModelStamp, earlier: Set<String>)?

    /// The message being sent, until the conversation holds it. What no
    /// longer fits may be summarised and a session built before it goes, and
    /// the field is cleared as it is sent — so it is shown meanwhile, and goes
    /// back in the field if it never went: it vanished for the seconds a
    /// summary took, with no progress line, and was gone if the turn failed
    /// before it was sent.
    private(set) var pendingPrompt: String?
    /// How many entries there were when `pendingPrompt` was sent.
    @ObservationIgnored private var pendingBase = 0
    /// Whether what no longer fits is being summarised before the message goes.
    private(set) var isSummarising = false

    /// The model for this conversation — an entry, so a particular MLX model
    /// and not merely MLX: the Settings default until the Assistant's menu
    /// chooses another, for this conversation only, never the default (the
    /// person's decision, 2026-10-18). Kept with the conversation; New
    /// Conversation goes back to the default.
    var conversationChoice: ModelOption? {
        didSet { if conversationChoice != oldValue { keepConversation() } }
    }
    private(set) var isResponding = false
    private(set) var errorText: String?

    /// **Use my notes**: when on, the Assistant searches and reads the
    /// collection through tools (it changes nothing in 1.3.5 — `NoteTools`).
    /// Kept with the conversation, because turning it off is how a
    /// conversation on a model off the device keeps the notes away from it:
    /// it came back on whenever the Assistant was made again — a note shown
    /// in its place was enough — while the conversation's Cloud (Apple)
    /// choice came back from disk.
    var agentMode = true {
        didSet { if agentMode != oldValue { keepConversation() } }
    }

    /// The focused collection's services. Set by the host.
    var toolContext: ToolContext? {
        didSet { if toolContext !== oldValue { session = nil } }
    }

    /// Where the conversation is kept. Set by the host alongside `toolContext`.
    var sessionStore: ChatSessionStore? {
        didSet {
            sessionStore?.onPersistenceError = { [weak self] message in self?.errorText = message }
            stop()
            // Another conversation now: nothing the old turn, or a summary
            // still on its way, writes is its.
            generation += 1
            turn = nil
            pendingPrompt = nil
            session = nil
            entries = sessionStore?.load() ?? []
            stamps = sessionStore?.loadStamps() ?? [:]
            let kept = sessionStore?.loadConversation() ?? ChatSessionStore.Conversation()
            restoring = true
            // Another collection's conversation, on the model it chose, or the
            // default: a choice made for one conversation is not another's.
            conversationChoice = kept.model.flatMap(ModelOption.init(id:)).flatMap(keptOption)
            agentMode = kept.useNotes ?? true
            restoring = false
            earlier.set(kept.summary.map { EarlierSummary.Value(text: $0, through: kept.summarisedThrough) })
        }
    }

    var permissions: PermissionBroker? { toolContext?.permissions }

    private var session: LanguageModelSession?
    private var sessionSignature: Signature?
    private var toolBudget = ToolCallBudget(limit: 16)
    private var task: Task<Void, Never>?
    @ObservationIgnored private var lastSync = ContinuousClock.now
    @ObservationIgnored private var trailingSync: Task<Void, Never>?
    /// Which conversation this is. A turn or a summary that comes back from an
    /// await to another one — the store changed, or New Conversation —
    /// writes nothing.
    @ObservationIgnored private var generation = 0
    /// Set while a conversation's own state is read back, so that reading it
    /// does not write it again.
    @ObservationIgnored private var restoring = false

    /// How often the conversation on screen follows a reply that is still
    /// arriving. See `syncEntriesWhileStreaming()`.
    private static let streamingRedraw: Duration = .milliseconds(100)

    /// Everything a session is built from. A difference means a rebuild.
    ///
    /// The model is its entry, not its name: an MLX model's title leaves out
    /// its organisation, so two models of one name shared a session, and the
    /// first went on answering after the menu ticked the second.
    private struct Signature: Equatable {
        var option: ModelOption
        var agentMode: Bool
        var canUseTools: Bool
        var temperature: Double
        var sampling: SamplingChoice
        var samplingTopK: Int
        var samplingThreshold: Double
        var samplingSeed: UInt64?
        var maximumReplyTokens: Int?
        var reasoning: ReasoningChoice
        var skills: Int
    }

    /// What has fallen out of the model's window, summarised, and how far
    /// the summary reaches — shown as a turn wherever a turn it covers is not
    /// (`HistoryWindow.fit`), so a long conversation keeps its thread instead
    /// of losing its start unseen. Kept with the conversation. Not part of the
    /// session's signature: the profile reads it before every request.
    let earlier = EarlierSummary()
    /// The summary's text, for a test or a look.
    var earlierSummary: String? { earlier.current?.text }
    /// The history budget the current session was built with — what decides
    /// which turns fall out (`HistoryWindow.fit`).
    @ObservationIgnored private var historyBudget: Int?
    /// The current session's turn room, which the note tools' results share.
    @ObservationIgnored private var room: TurnRoom?

    /// Room kept for a summary not yet written, when deciding what a turn will
    /// leave out: about what 150 words cost, as a turn.
    private static let summaryReserve = 320
    /// The most parts of a backlog folded into the summary before one
    /// message: a long backlog — a conversation moved from Cloud (Apple)'s
    /// window to this device's — costs a few seconds a message rather than a
    /// minute before the first, and the rest is folded before the next.
    private static let summaryPartsPerTurn = 3

    init(settings: IntelligenceSettings) {
        self.settings = settings
    }

    // MARK: - State

    /// The entry this conversation asked for: its own choice — found again
    /// under its new snapshot when its model has been updated
    /// (`LanguageModels.resolved`) — or the Settings default's. What the menu
    /// marks.
    var chosenOption: ModelOption {
        conversationChoice.map { settings.models.resolved($0) } ?? settings.option(for: settings.model)
    }

    /// The kind of model asked for.
    var chosenModel: ModelChoice { chosenOption.choice }

    /// The entry that answers: the one asked for — or Local (Apple) while
    /// Cloud (Apple)'s allowance for today is spent (`LanguageModels.serving`).
    var servingOption: ModelOption { settings.models.serving(option: chosenOption) }

    /// The kind of model that answers.
    var modelChoice: ModelChoice { servingOption.choice }

    /// What the Assistant's menu offers: the Settings picker's entries —
    /// Apple's, and **each MLX model in the models folder** — and this
    /// conversation's own when the folder no longer has it, so the menu says
    /// what the conversation is on. It offered one MLX entry, because one MLX
    /// model loads at a time: a fact about loading used to justify a fact
    /// about choosing, which CLAUDE.md names, and the person found one model
    /// where they had several (build 34).
    var menuOptions: [ModelOption] {
        let offered = settings.models.options
        return offered.contains(chosenOption) ? offered : offered + [chosenOption]
    }

    /// Choose `option` for this conversation — and only for it: an MLX model
    /// chosen here runs beside the default's, never in its place.
    func choose(_ option: ModelOption) {
        conversationChoice = option
    }

    /// Whether `option` is the model this conversation runs on.
    func isChosen(_ option: ModelOption) -> Bool { option == chosenOption }

    var modelName: String { settings.models.title(of: servingOption) }
    var modelTitle: String { settings.models.title(of: chosenOption) }
    var availability: IntelligenceAvailability { settings.models.availability(ofOption: servingOption) }

    /// Whether the chosen model can call tools at all. When it can't, the
    /// Assistant chats without them whatever agent mode says — a model given
    /// tools its template cannot show it writes imitation calls as its answer.
    var canUseTools: Bool { settings.models.supportsTools(option: servingOption) }

    var canSend: Bool {
        !isResponding && availability.isAvailable
            && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding else { return }
        input = ""
        start(text)
    }

    /// Ask `question` from outside the conversation — Ask the Assistant, on a
    /// selection — at once, as Ask Your Library did: making the person press
    /// Send again would only ask them to confirm what they just did. While a
    /// reply is still coming, or with no model to answer, it waits in the
    /// field instead.
    func ask(_ question: String) {
        guard !isResponding, availability.isAvailable else {
            input = question
            return
        }
        start(question)
    }

    private func start(_ text: String) {
        errorText = nil
        isResponding = true
        pendingPrompt = text
        pendingBase = entries.count
        let generation = generation
        task = Task { [weak self] in
            await self?.respond(to: text, generation: generation)
        }
    }

    func stop() {
        task?.cancel()
        trailingSync?.cancel()
        trailingSync = nil
        // A tool waiting on an approval nobody will now give must not keep the
        // response alive.
        permissions?.cancelPending()
    }

    func clear() {
        stop()
        generation += 1
        session = nil
        turn = nil
        pendingPrompt = nil
        earlier.set(nil)
        entries.removeAll()
        stamps.removeAll()
        restoring = true
        conversationChoice = nil
        restoring = false
        errorText = nil
        sessionStore?.clear()
        // The new conversation keeps Use my notes as it was: turning it back
        // on would send the notes to a model off the device that the person
        // had kept them from.
        keepConversation()
        // A blanket "Allow all" must not carry into a new conversation, where
        // injected content could drive mutating tools without a fresh approval.
        permissions?.reset()
    }

    // MARK: - Responding

    private func respond(to text: String, generation: Int) async {
        var option = servingOption
        var name = settings.models.title(of: option)
        turn = (ModelStamp(choice: option.choice, name: name), ChatSessionStore.replyIDs(in: entries))
        defer {
            isResponding = false
            task = nil
            if generation == self.generation {
                stampNewReplies()
                turn = nil
                // A message that never reached the conversation goes back
                // where it was typed.
                if let unsent = pendingPrompt, input.isEmpty { input = unsent }
                pendingPrompt = nil
                sessionStore?.save(entries, stamps: stamps)
            }
        }
        let before = entries
        do {
            do {
                // The session first: it decides the history's budget, which
                // decides what this message pushes out of the window.
                _ = try await currentSession(on: option)
                await summariseWhatFallsOut(adding: text, on: option, generation: generation)
                try Task.checkCancellation()
                try await stream(text, into: try await currentSession(on: option))
            } catch {
                guard let fallback = settings.models.fallback(after: error, on: option.choice) else { throw error }
                // Cloud (Apple) refused this message for today's limit: ask
                // it again on this device, from the conversation as it was
                // before it, and stamp the reply with the model that wrote it
                // — and with the one that refused it, which had been sent the
                // conversation so far.
                let refused = option.choice
                option = settings.option(for: fallback)
                name = settings.models.title(of: option)
                turn?.stamp = ModelStamp(choice: option.choice, name: name, after: refused)
                session = nil
                entries = before
                pendingPrompt = text
                try await stream(text, into: try await currentSession(on: option))
            }
        } catch is CancellationError {
            syncEntries()
        } catch let error as LanguageModelError {
            syncEntries()
            if case .contextSizeExceeded = error {
                // Older turns are already trimmed to fit before every request
                // (`HistoryWindow`), so an overflow is this turn's own weight —
                // usually a long note or page a tool read. Dropping history
                // would not help, so say what would.
                errorText = "That was more than \(name) can hold at once. Try asking about less at a time, or start a new conversation."
            } else {
                errorText = IntelligenceError.describe(error, modelName: name)
            }
        } catch {
            syncEntries()
            errorText = IntelligenceError.describe(error, modelName: name)
        }
    }

    private func stream(_ text: String, into session: LanguageModelSession) async throws {
        toolBudget.reset()
        let response = session.streamResponse(to: text, options: GenerationOptions())
        // The session's transcript updates as the response is generated — tool
        // calls, their results and the reply as it grows — so the view is drawn
        // from it directly rather than from a second copy assembled by hand.
        for try await _ in response {
            syncEntriesWhileStreaming()
        }
        trailingSync?.cancel()
        trailingSync = nil
        syncEntries()
    }

    /// Follow the transcript at most ten times a second, and always catch up
    /// when a burst goes quiet.
    ///
    /// Every snapshot used to redraw the conversation — about 40 a second from
    /// the on-device model, measured — and each redraw re-rendered the growing
    /// reply's Markdown from its first line: roughly a fifth of the main thread
    /// by an 8 KB reply and three fifths by 30 KB, while the person may be
    /// typing in a note. Ten a second reads as smooth. The trailing sync
    /// matters as much as the limit: a tool call that arrives inside the window
    /// and is followed by a pause — waiting for approval, say — must still
    /// appear, or the progress line would go on saying "Thinking…".
    private func syncEntriesWhileStreaming() {
        let elapsed = ContinuousClock.now - lastSync
        if elapsed >= Self.streamingRedraw {
            trailingSync?.cancel()
            trailingSync = nil
            syncEntries()
        } else if trailingSync == nil {
            trailingSync = Task { [weak self] in
                try? await Task.sleep(for: Self.streamingRedraw - elapsed)
                guard !Task.isCancelled, let self else { return }
                self.trailingSync = nil
                self.syncEntries()
            }
        }
    }

    // MARK: - Summarising what falls out

    /// Before a message goes, the turns it pushes out of the window are
    /// folded into the summary, oldest first, a few parts a message
    /// (`summaryPartsPerTurn`). Only what was summarised counts as covered: a
    /// part that fails, is stopped, or comes back to another conversation
    /// leaves the summary where it was, and its turns are folded in before a
    /// later message. What a turn's own results push out is folded in before
    /// the next.
    ///
    /// It lost the thread four ways (implemented.md §51.55): it read the
    /// opening of what fell out and marked all of it covered; it moved on when
    /// a summary failed; it measured before the new message was added, so a
    /// turn went a message late; and it was never kept, so the Assistant made
    /// again remembered none of what it had summarised.
    private func summariseWhatFallsOut(adding text: String, on option: ModelOption, generation: Int) async {
        guard let budget = historyBudget else { return }
        let current = earlier.current
        // What the first request of this turn leaves out, with room kept for
        // the summary it will then carry.
        let reserve = max(HistoryWindow.cost(ofSummary: current?.text ?? ""), Self.summaryReserve)
        let dropped = HistoryWindow.keptFrom(entries + [Self.promptEntry(text)], tokens: budget - reserve)
        let covered = current?.through.flatMap { id in entries.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        guard dropped > covered else { return }

        let window = await settings.models.contextSize(of: option.choice)
        let parts = Self.summaryParts(entries[covered..<dropped], tokens: max(400, window / 2))
        guard !parts.isEmpty, generation == self.generation else { return }

        isSummarising = true
        defer { isSummarising = false }
        var summary = current?.text
        var through = current?.through
        var option = option
        for part in parts.prefix(Self.summaryPartsPerTurn) {
            var folded: String?
            do {
                folded = try await Self.summarise(previous: summary, adding: part.text, on: option,
                                                  models: settings.models)
            } catch {
                // Cloud (Apple)'s limit is no reason to lose the thread: this
                // device summarises instead, as it answers instead.
                if let fallback = settings.models.fallback(after: error, on: option.choice) {
                    option = settings.option(for: fallback)
                    folded = try? await Self.summarise(previous: summary, adding: part.text, on: option,
                                                       models: settings.models)
                }
            }
            guard generation == self.generation, !Task.isCancelled, let folded else { break }
            summary = folded
            if let id = part.through { through = id }
        }
        guard generation == self.generation, let summary else { return }
        let updated = EarlierSummary.Value(text: summary, through: through)
        guard updated != current else { return }
        earlier.set(updated)
        fitRoom()
        keepConversation()
    }

    /// `text` as the prompt it will be, to measure what it pushes out.
    private static func promptEntry(_ text: String) -> Transcript.Entry {
        .prompt(Transcript.Prompt(segments: [.text(.init(content: text))]))
    }

    /// The person's words and the replies in `entries`, as parts of at most
    /// `tokens` — not the tool calls and their output, which are bulk, not
    /// the thread — each with the id of the last entry it finishes, so a
    /// summary covers exactly what it read. An entry longer than a part is
    /// read in several, never cut to its opening: a summary describes all of
    /// what it stands for.
    nonisolated static func summaryParts(_ entries: ArraySlice<Transcript.Entry>,
                                         tokens: Int) -> [(text: String, through: String?)] {
        var parts: [(text: String, through: String?)] = []
        var text = ""
        var used = 0
        /// The last entry wholly read by the part being made, or before it.
        var finished: String?
        for entry in entries {
            guard let line = conversationLine(entry) else {
                finished = entry.id
                continue
            }
            let cost = TokenBudget.estimate(line) + 2
            if used + cost > tokens, !text.isEmpty {
                parts.append((text, finished))
                text = ""
                used = 0
            }
            if cost > tokens {
                // Pieces that join back into the whole (`TokenBudget.chunks`);
                // the last goes on with what follows.
                var pieces = TokenBudget.chunks(line, tokens: tokens)
                text = pieces.removeLast()
                used = TokenBudget.estimate(text) + 2
                parts.append(contentsOf: pieces.map { ($0, finished) })
            } else {
                text += (text.isEmpty ? "" : "\n\n") + line
                used += cost
            }
            finished = entry.id
        }
        if !text.isEmpty { parts.append((text, finished)) }
        return parts
    }

    /// One entry of the thread, said as who said it — or `nil` for what is
    /// not the thread.
    nonisolated static func conversationLine(_ entry: Transcript.Entry) -> String? {
        switch AssistantRow.rows([entry]).first {
        case .prompt(_, let text)?: "Person: \(text)"
        case .response(_, let text)?: "Assistant: \(text)"
        default: nil
        }
    }

    static let summaryInstructions = "You keep a short running summary of a conversation between a person and the assistant in their notes app. Merge the summary so far with the new part of the conversation. Keep what may matter later: what the person asked, what was answered, the notes named, facts, numbers and decisions. At most 150 words. Reply with only the summary."

    /// The summary so far, with `text` folded in — on the conversation's own
    /// model, so nothing is sent anywhere the conversation was not. `nil` when
    /// the model has nothing to say; throws when it cannot answer, so that a
    /// caller can tell Cloud (Apple)'s limit from the rest.
    static func summarise(previous: String?, adding text: String, on option: ModelOption,
                          models: LanguageModels) async throws -> String? {
        guard !text.isEmpty else { return previous }
        let model = try models.model(forOption: option, purpose: .transforming)
        let prompt = "Summary so far:\n\(previous ?? "(none)")\n\nNew part of the conversation:\n\(text)"
        let session = LanguageModelSession(model: model, instructions: summaryInstructions)
        let reply = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2))
        let summary = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? nil : summary
    }

    // MARK: - Keeping the conversation

    /// Keep what this conversation is beside its transcript
    /// (`ChatSessionStore.Conversation`).
    private func keepConversation() {
        guard !restoring, let sessionStore else { return }
        let summary = earlier.current
        sessionStore.saveConversation(ChatSessionStore.Conversation(
            model: conversationChoice?.id, useNotes: agentMode,
            summary: summary?.text, summarisedThrough: summary?.through))
    }

    /// A kept choice, as this build can honour it. An MLX model is kept when
    /// the folder no longer lists it: the conversation then says so and sends
    /// nothing, where it used to move to the default — which may be off the
    /// device — with everything it had read (`LanguageModels.resolved` finds
    /// it again under a new snapshot). An entry this build offers no way to
    /// run at all is the default's.
    private func keptOption(_ option: ModelOption) -> ModelOption? {
        option.mlxModelID != nil || settings.models.options.contains(option) ? option : nil
    }

    // MARK: - Stamps and the transcript

    /// Every reply this turn has added, stamped with the turn's model.
    private func stampNewReplies() {
        guard let turn else { return }
        let stamped = Self.stamping(stamps, newRepliesIn: entries, notIn: turn.earlier, with: turn.stamp)
        if stamped.count != stamps.count { stamps = stamped }
    }

    /// `stamps`, with each reply in `entries` that is neither in `earlier` nor
    /// stamped already given `stamp`. A function, so a test can hold it.
    nonisolated static func stamping(_ stamps: [String: ModelStamp], newRepliesIn entries: [Transcript.Entry],
                                     notIn earlier: Set<String>, with stamp: ModelStamp) -> [String: ModelStamp] {
        var result = stamps
        for case .response(let reply) in entries where !earlier.contains(reply.id) && result[reply.id] == nil {
            result[reply.id] = stamp
        }
        return result
    }

    private func syncEntries() {
        lastSync = .now
        guard let session else { return }
        entries = ChatSessionStore.history(of: session.transcript)
        if pendingPrompt != nil, entries.count > pendingBase { pendingPrompt = nil }
    }

    /// What the current turn holds in the session's transcript — from its
    /// message on — how many tools its latest step asked for, and where it
    /// began (`TurnRoom`).
    private func heldThisTurn() -> TurnRoom.Held {
        let none = TurnRoom.Held(tokens: 0, calls: 0, turnStart: 0)
        guard let session else { return none }
        let entries = Array(session.transcript)
        guard let start = entries.lastIndex(where: { entry in
            if case .prompt = entry { return true }
            return false
        }) else { return none }
        var held = TurnRoom.Held(tokens: 0, calls: 0, turnStart: start)
        for entry in entries[start...] {
            held.tokens += HistoryWindow.estimate(entry)
            if case .toolCalls(let step) = entry { held.calls = Array(step).count }
        }
        return held
    }

    /// The turn room's budget: the history's, less the summary it may carry.
    private func fitRoom() {
        guard let room, let historyBudget else { return }
        room.budget = historyBudget - (earlier.current.map { HistoryWindow.cost(ofSummary: $0.text) } ?? 0)
    }

    /// The session for the current settings on `option`, built — carrying the
    /// conversation — when there is none or what it was built from has changed.
    private func currentSession(on option: ModelOption) async throws -> LanguageModelSession {
        let models = settings.models
        let choice = option.choice
        let canUseTools = models.supportsTools(option: option)
        let signature = Signature(
            option: option, agentMode: agentMode, canUseTools: canUseTools,
            temperature: settings.temperature,
            sampling: settings.sampling, samplingTopK: settings.samplingTopK,
            samplingThreshold: settings.samplingThreshold, samplingSeed: settings.samplingSeed,
            maximumReplyTokens: settings.maximumReplyTokens,
            reasoning: settings.reasoning,
            skills: toolContext?.skills?.skills.count ?? 0)
        if let session, signature == sessionSignature { return session }

        let carried = session.map { ChatSessionStore.history(of: $0.transcript) } ?? entries
        let model = try models.model(forOption: option)
        let window = await models.contextSize(of: choice)

        // Research, a tool that starts sessions of its own, runs on this
        // conversation's model — not the Settings default.
        toolContext?.modelChoice = option
        // The turn's room, which the note tools' results share; its budget is
        // the history's share, known once the tools' own cost is.
        let room = TurnRoom(budget: 0) { [weak self] in
            self?.heldThisTurn() ?? TurnRoom.Held(tokens: 0, calls: 0, turnStart: 0)
        }
        let tools: [any Tool] = agentMode && canUseTools
            ? (toolContext.map { NoteTools.tools(for: $0, contextTokens: window, room: room) } ?? [])
            : []
        let instructions = AssistantInstructions.text(
            toolNames: Set(tools.map(\.name)),
            collectionName: toolContext?.rootURL?.lastPathComponent,
            noteCount: toolContext?.notes.count ?? 0)

        // What the instructions and tool definitions cost, measured where the
        // model can measure it and estimated where it cannot.
        var fixedTokens = TokenBudget.estimate(instructions)
        if choice == .onDevice, let measured = try? await models.onDevice.tokenCount(for: tools) {
            fixedTokens += measured
        } else {
            fixedTokens += tools.reduce(0) { $0 + TokenBudget.estimate($1.description) + 80 }
        }
        let replyReserve = min(2_048, window / 4)
        let historyTokens = max(512, window - fixedTokens - replyReserve - window / 20)
        historyBudget = historyTokens
        self.room = room
        fitRoom()

        let budget = ToolCallBudget(limit: 16)
        toolBudget = budget
        let profile = AssistantProfile(
            model: model,
            instructions: instructions,
            tools: tools,
            temperature: settings.temperature,
            sampling: settings.samplingMode,
            maximumReplyTokens: settings.maximumReplyTokens,
            reasoning: models.reasoningLevel(settings.reasoning, for: choice),
            historyTokens: historyTokens,
            toolBudget: budget,
            earlier: earlier)
        let fresh = LanguageModelSession(profile: profile, history: carried)
        session = fresh
        sessionSignature = signature
        return fresh
    }
}
