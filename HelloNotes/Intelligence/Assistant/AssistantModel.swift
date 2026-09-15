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
    private(set) var entries: [Transcript.Entry] = []
    private(set) var isResponding = false
    private(set) var errorText: String?

    /// When on, the Assistant can read and change the collection through tools.
    var agentMode = true

    /// The focused collection's services. Set by the host.
    var toolContext: ToolContext? {
        didSet { if toolContext !== oldValue { session = nil } }
    }

    /// Where the conversation is kept. Set by the host alongside `toolContext`.
    var sessionStore: ChatSessionStore? {
        didSet {
            sessionStore?.onPersistenceError = { [weak self] message in self?.errorText = message }
            stop()
            session = nil
            entries = sessionStore?.load() ?? []
        }
    }

    var permissions: PermissionBroker? { toolContext?.permissions }

    private var session: LanguageModelSession?
    private var sessionSignature: Signature?
    private var toolBudget = ToolCallBudget(limit: 16)
    private var task: Task<Void, Never>?
    @ObservationIgnored private var lastSync = ContinuousClock.now
    @ObservationIgnored private var trailingSync: Task<Void, Never>?

    /// How often the conversation on screen follows a reply that is still
    /// arriving. See `syncEntriesWhileStreaming()`.
    private static let streamingRedraw: Duration = .milliseconds(100)

    /// Everything a session is built from. A difference means a rebuild.
    private struct Signature: Equatable {
        var choice: ModelChoice
        var modelName: String
        var agentMode: Bool
        var canUseTools: Bool
        var temperature: Double
        var reasoning: ReasoningChoice
        var skills: Int
    }

    init(settings: IntelligenceSettings) {
        self.settings = settings
    }

    // MARK: - State

    var modelChoice: ModelChoice { settings.assistantModel }
    var modelName: String { settings.models.name(of: modelChoice) }
    var modelTitle: String { settings.models.title(of: modelChoice) }
    var availability: IntelligenceAvailability { settings.models.availability(of: modelChoice) }

    /// Whether the chosen model can call tools at all. When it can't, the
    /// Assistant chats without them whatever agent mode says — a model given
    /// tools its template cannot show it writes imitation calls as its answer.
    var canUseTools: Bool { settings.models.supportsTools(modelChoice) }

    var canSend: Bool {
        !isResponding && availability.isAvailable
            && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding else { return }
        input = ""
        errorText = nil
        isResponding = true
        task = Task { [weak self] in
            await self?.respond(to: text)
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
        session = nil
        entries.removeAll()
        errorText = nil
        sessionStore?.clear()
        // A blanket "Allow all" must not carry into a new conversation, where
        // injected content could drive mutating tools without a fresh approval.
        permissions?.reset()
    }

    // MARK: - Responding

    private func respond(to text: String) async {
        defer {
            isResponding = false
            task = nil
            sessionStore?.save(entries)
        }
        do {
            try await stream(text, into: try await currentSession())
        } catch is CancellationError {
            syncEntries()
        } catch let error as LanguageModelError {
            syncEntries()
            if case .contextSizeExceeded = error {
                // Older turns are already trimmed to fit before every request
                // (`HistoryWindow`), so an overflow is this turn's own weight —
                // usually a long note or page a tool read. Dropping history
                // would not help, so say what would.
                errorText = "That was more than \(modelName) can hold at once. Try asking about less at a time, or start a new conversation."
            } else {
                errorText = IntelligenceError.describe(error, modelName: modelName)
            }
        } catch {
            syncEntries()
            errorText = IntelligenceError.describe(error, modelName: modelName)
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

    private func syncEntries() {
        lastSync = .now
        guard let session else { return }
        entries = ChatSessionStore.history(of: session.transcript)
    }

    /// The session for the current settings, built — carrying the conversation —
    /// when there is none or what it was built from has changed.
    private func currentSession() async throws -> LanguageModelSession {
        let models = settings.models
        let choice = modelChoice
        let signature = Signature(
            choice: choice, modelName: models.name(of: choice), agentMode: agentMode,
            canUseTools: canUseTools,
            temperature: settings.temperature, reasoning: settings.reasoning,
            skills: toolContext?.skills?.skills.count ?? 0)
        if let session, signature == sessionSignature { return session }

        let carried = session.map { ChatSessionStore.history(of: $0.transcript) } ?? entries
        let model = try models.model(for: choice)
        let window = await models.contextSize(of: choice)

        let tools: [any Tool] = agentMode && canUseTools
            ? (toolContext.map { NoteTools.tools(for: $0, contextTokens: window) } ?? [])
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

        let budget = ToolCallBudget(limit: 16)
        toolBudget = budget
        let profile = AssistantProfile(
            model: model,
            instructions: instructions,
            tools: tools,
            temperature: settings.temperature,
            reasoning: models.reasoningLevel(settings.reasoning, for: choice),
            historyTokens: historyTokens,
            toolBudget: budget)
        let fresh = LanguageModelSession(profile: profile, history: carried)
        session = fresh
        sessionSignature = signature
        return fresh
    }
}
