//
//  AgentRunner.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  A headless agent loop (no UI). Used by sub-agents — e.g. the deep-research
//  tool spawns several of these in parallel, each with its own scoped tools and
//  message history, and collects their final reports.
//

import Foundation

@MainActor
struct AgentRunner {
    let provider: LLMProvider
    let model: String
    let tools: [AgentTool]
    let context: ToolContext
    let systemPrompt: String
    var options = LLMRequestOptions()
    var maxIterations = 8

    private var registry: ToolRegistry { ToolRegistry(tools: tools) }

    /// Run the loop to a final text answer for `userPrompt`.
    func run(_ userPrompt: String) async throws -> String {
        var messages: [LLMMessage] = [LLMMessage(role: .user, text: userPrompt)]
        let llmTools = registry.llmTools

        for _ in 0..<maxIterations {
            let ctx = LLMContext(systemPrompt: systemPrompt, messages: messages, tools: llmTools)
            var assistant = LLMMessage(role: .assistant, parts: [])
            var calls: [String: ToolCall] = [:]
            var order: [String] = []
            var stop: StopReason = .stop

            for try await event in provider.stream(ctx, model: model, options: options) {
                switch event {
                case .textDelta(let d):
                    appendText(d, to: &assistant)
                case .toolCallStarted(let id, let name):
                    calls[id] = ToolCall(id: id, name: name, arguments: ""); order.append(id)
                case .toolCallArgumentsDelta(let id, let frag):
                    calls[id]?.arguments += frag
                case .toolCallCompleted, .thinkingDelta, .usage:
                    break
                case .done(let reason):
                    stop = reason
                }
            }
            for id in order { if let c = calls[id] { assistant.parts.append(.toolCall(c)) } }
            messages.append(assistant)

            guard stop == .toolCalls, !order.isEmpty else { return assistant.text }

            var results: [MessagePart] = []
            for id in order {
                guard let call = calls[id] else { continue }
                if let tool = registry.tool(named: call.name) {
                    do { results.append(.toolResult(ToolResult(callID: id, output: try await tool.run(call.parsedArguments, context: context)))) }
                    catch { results.append(.toolResult(ToolResult(callID: id, output: error.localizedDescription, isError: true))) }
                } else {
                    results.append(.toolResult(ToolResult(callID: id, output: "Unknown tool \(call.name)", isError: true)))
                }
            }
            messages.append(LLMMessage(role: .tool, parts: results))
        }
        return messages.last(where: { $0.role == .assistant })?.text ?? ""
    }

    private func appendText(_ delta: String, to message: inout LLMMessage) {
        if case .text(let existing)? = message.parts.last {
            message.parts[message.parts.count - 1] = .text(existing + delta)
        } else {
            message.parts.append(.text(delta))
        }
    }
}
