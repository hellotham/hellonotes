//
//  AssistantModel.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  The chat view-model: owns the conversation, drives a streaming turn against
//  the active provider, and folds `StreamEvent`s into the live assistant message.
//  Phase 1 runs a single turn; the agent tool-loop is layered on in Phase 3
//  (see `runTurn` — the seam where tool execution slots in).
//

import Foundation
import Observation

@MainActor
@Observable
final class AssistantModel {
    let settings: LLMSettings

    var messages: [LLMMessage] = []
    var input: String = ""
    private(set) var isStreaming = false
    private(set) var errorText: String?
    private(set) var totalUsage = LLMUsage()

    /// When on (and the provider supports tools), the assistant can read and edit
    /// the collection through tools. Off = plain chat.
    var agentMode = true

    /// Collection tools + services. Set by the host view when a collection is open.
    var registry: ToolRegistry?
    var toolContext: ToolContext?

    /// Persists the conversation across launches (set by the host view).
    var sessionStore: ChatSessionStore? {
        didSet { if messages.isEmpty { messages = sessionStore?.load() ?? [] } }
    }

    /// Live permission prompts (for the approval UI) come from the broker.
    var permissions: PermissionBroker? { toolContext?.permissions }

    /// Base persona; collection context and tool guidance are appended at send time.
    var basePrompt: String =
        "You are the HelloNotes assistant, embedded in a local Markdown notes app. " +
        "Be concise and helpful. Format answers in Markdown."

    private let maxToolIterations = 12
    private var currentTask: Task<Void, Never>?

    init(settings: LLMSettings) {
        self.settings = settings
    }

    var activeProvider: ProviderKind { settings.activeProvider }

    /// Whether tools are actually in play this turn.
    private var toolsActive: Bool {
        agentMode && settings.activeProvider.supportsTools && registry != nil && toolContext != nil
    }

    private var systemPrompt: String {
        var prompt = basePrompt
        if let ctx = toolContext, let root = ctx.rootURL {
            prompt += "\n\nThe focused collection is “\(root.lastPathComponent)” with \(ctx.notes.count) notes."
            if toolsActive {
                prompt += " You can read and modify it using the provided tools. " +
                    "Prefer search_notes/grep_collection/read_note to ground answers in the collection before responding. " +
                    "Use edit_note for small changes and write_note for full rewrites. " +
                    "Every file change is shown to the user for approval and committed to Git, so make focused, well-explained edits. " +
                    "Use web_search/web_fetch for external facts, and deep_research for questions needing thorough, multi-source investigation."
                if let store = ctx.skills, !store.skills.isEmpty {
                    prompt += "\n\nAvailable skills (call load_skill with the name to get full instructions):\n" + store.discoveryList
                }
            }
        }
        return prompt
    }
    var canSend: Bool {
        !isStreaming && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        input = ""
        messages.append(LLMMessage(role: .user, text: text))
        start()
    }

    func stop() {
        currentTask?.cancel()
    }

    func clear() {
        stop()
        messages.removeAll()
        errorText = nil
        totalUsage = LLMUsage()
        sessionStore?.clear()
        // A blanket "Allow all" grant must not carry across conversations —
        // reset it when the chat is cleared so injected content in a new thread
        // can't drive mutating tools without a fresh approval.
        permissions?.reset()
    }

    private func start() {
        errorText = nil
        isStreaming = true
        sessionStore?.save(messages)
        currentTask = Task { [weak self] in
            guard let self else { return }
            await self.runTurn()
            self.isStreaming = false
            self.sessionStore?.save(self.messages)
        }
    }

    /// Run the conversation to completion: stream a turn, and if it ends in tool
    /// calls, execute them, append the results, and continue — up to a cap.
    private func runTurn() async {
        let kind = settings.activeProvider
        let provider: LLMProvider
        let model: String
        do {
            (provider, model) = try ProviderFactory.make(for: kind, settings: settings)
        } catch {
            errorText = error.localizedDescription
            return
        }

        let options = LLMRequestOptions(temperature: settings.temperature)
        let tools = toolsActive ? (registry?.llmTools ?? []) : []

        for _ in 0..<maxToolIterations {
            let context = LLMContext(systemPrompt: systemPrompt, messages: messages, tools: tools)
            let outcome = await streamOne(provider: provider, model: model, context: context, options: options)

            guard case .success(let stop, let calls) = outcome else { return }
            guard stop == .toolCalls, !calls.isEmpty, toolsActive else { return }

            // Execute each requested tool and append the results as a tool turn.
            var results: [MessagePart] = []
            for call in calls {
                let result = await execute(call)
                results.append(.toolResult(result))
            }
            messages.append(LLMMessage(role: .tool, parts: results))
        }
    }

    private enum TurnOutcome { case success(StopReason, [ToolCall]); case aborted }

    /// Stream a single assistant turn, folding deltas into a live message and
    /// accumulating any tool calls.
    private func streamOne(provider: LLMProvider, model: String, context: LLMContext, options: LLMRequestOptions) async -> TurnOutcome {
        var assistant = LLMMessage(role: .assistant, parts: [])
        messages.append(assistant)
        let index = messages.count - 1
        func flush() { if messages.indices.contains(index) { messages[index] = assistant } }

        var callIndex: [String: Int] = [:]   // tool-call id → part index
        var stop: StopReason = .stop

        do {
            for try await event in provider.stream(context, model: model, options: options) {
                switch event {
                case .textDelta(let delta):
                    appendText(delta, to: &assistant); flush()
                case .thinkingDelta(let delta):
                    appendThinking(delta, to: &assistant); flush()
                case .toolCallStarted(let id, let name):
                    assistant.parts.append(.toolCall(ToolCall(id: id, name: name, arguments: "")))
                    callIndex[id] = assistant.parts.count - 1
                    flush()
                case .toolCallArgumentsDelta(let id, let fragment):
                    if let i = callIndex[id], case .toolCall(var call) = assistant.parts[i] {
                        call.arguments += fragment
                        assistant.parts[i] = .toolCall(call)
                        flush()
                    }
                case .toolCallCompleted:
                    break
                case .usage(let usage):
                    assistant.usage = usage; totalUsage = totalUsage + usage; flush()
                case .done(let reason):
                    stop = reason; flush()
                }
            }
        } catch is CancellationError {
            return .aborted
        } catch {
            errorText = error.localizedDescription
            if assistant.parts.isEmpty, messages.indices.contains(index) { messages.remove(at: index) }
            return .aborted
        }
        return .success(stop, assistant.toolCalls)
    }

    private func execute(_ call: ToolCall) async -> ToolResult {
        guard let registry, let ctx = toolContext, let tool = registry.tool(named: call.name) else {
            return ToolResult(callID: call.id, output: "Unknown tool: \(call.name)", isError: true)
        }
        do {
            let output = try await tool.run(call.parsedArguments, context: ctx)
            return ToolResult(callID: call.id, output: output)
        } catch {
            return ToolResult(callID: call.id, output: error.localizedDescription, isError: true)
        }
    }

    // MARK: - Part accumulation

    private func appendText(_ delta: String, to message: inout LLMMessage) {
        if case .text(let existing)? = message.parts.last {
            message.parts[message.parts.count - 1] = .text(existing + delta)
        } else {
            message.parts.append(.text(delta))
        }
    }

    private func appendThinking(_ delta: String, to message: inout LLMMessage) {
        if case .thinking(let existing)? = message.parts.last {
            message.parts[message.parts.count - 1] = .thinking(existing + delta)
        } else {
            message.parts.append(.thinking(delta))
        }
    }
}
