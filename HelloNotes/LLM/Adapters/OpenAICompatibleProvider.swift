//
//  OpenAICompatibleProvider.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  One adapter for every provider that speaks the OpenAI Chat Completions wire
//  format — OpenAI, Mistral, OpenRouter, Groq, xAI, DeepSeek, Cerebras, Together,
//  Perplexity, Ollama (local + cloud), LM Studio. They differ only by
//  configuration (base URL, key, a couple of headers), so they share this
//  implementation. Backed by MacPaw/OpenAI.
//

import Foundation
import OpenAI

struct OpenAICompatibleProvider: LLMProvider {
    let kind: ProviderKind
    let baseURL: String
    let apiKey: String

    private func makeClient() throws -> OpenAI {
        guard let comps = URLComponents(string: baseURL), let host = comps.host else {
            throw LLMError.notConfigured("Invalid base URL for \(kind.displayName): \(baseURL)")
        }
        let scheme = comps.scheme ?? "https"
        let port = comps.port ?? (scheme == "https" ? 443 : 80)
        // Most providers namespace under /v1; Perplexity serves chat/completions
        // at the root. A bare user-entered URL still defaults to /v1.
        let basePath = comps.path.isEmpty ? (kind == .perplexity ? "" : "/v1") : comps.path

        var headers: [String: String] = [:]
        if kind == .openrouter {
            headers["HTTP-Referer"] = "https://hellotham.github.io/hellonotes/"
            headers["X-Title"] = "HelloNotes"
        }

        let configuration = OpenAI.Configuration(
            token: apiKey,
            host: host,
            port: port,
            scheme: scheme,
            basePath: basePath,
            timeoutInterval: 120,
            customHeaders: headers
        )
        return OpenAI(configuration: configuration)
    }

    func stream(_ context: LLMContext, model: String, options: LLMRequestOptions) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let client = try makeClient()
                    let query = try Self.makeQuery(context, model: model, options: options)
                    var toolNames: [Int: (id: String, name: String)] = [:]  // stream index → call
                    var sawToolCalls = false
                    var usage: LLMUsage?
                    var pendingStop: StopReason?

                    for try await result in client.chatsStream(query: query) {
                        if let u = result.usage {
                            usage = LLMUsage(inputTokens: u.promptTokens, outputTokens: u.completionTokens)
                        }
                        guard let choice = result.choices.first else { continue }
                        let delta = choice.delta

                        if let content = delta.content, !content.isEmpty {
                            continuation.yield(.textDelta(content))
                        }

                        if let calls = delta.toolCalls {
                            sawToolCalls = true
                            for call in calls {
                                if toolNames[call.index] == nil {
                                    let id = call.id ?? "call_\(call.index)"
                                    let name = call.function?.name ?? ""
                                    toolNames[call.index] = (id, name)
                                    continuation.yield(.toolCallStarted(id: id, name: name))
                                }
                                if let fragment = call.function?.arguments, !fragment.isEmpty,
                                   let entry = toolNames[call.index] {
                                    continuation.yield(.toolCallArgumentsDelta(id: entry.id, fragment: fragment))
                                }
                            }
                        }

                        if let reason = choice.finishReason, pendingStop == nil {
                            for (_, entry) in toolNames.sorted(by: { $0.key < $1.key }) {
                                continuation.yield(.toolCallCompleted(id: entry.id))
                            }
                            pendingStop = (reason == .toolCalls || sawToolCalls) ? .toolCalls
                                : (reason == .length ? .length : .stop)
                            // Don't finish here: with streamOptions.includeUsage set,
                            // servers send token usage in a SEPARATE trailing chunk
                            // (empty choices) AFTER the finish-reason chunk. Keep
                            // reading to the stream's end so `.usage` isn't dropped.
                        }
                    }
                    // Stream ended.
                    if let usage { continuation.yield(.usage(usage)) }
                    continuation.yield(.done(pendingStop ?? (sawToolCalls ? .toolCalls : .stop)))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.done(.cancelled))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Query construction

    private static func makeQuery(_ context: LLMContext, model: String, options: LLMRequestOptions) throws -> ChatQuery {
        var messages: [ChatQuery.ChatCompletionMessageParam] = []

        if let system = context.systemPrompt, !system.isEmpty {
            if let m = ChatQuery.ChatCompletionMessageParam(role: .system, content: system) {
                messages.append(m)
            }
        }

        for message in context.messages {
            switch message.role {
            case .system:
                if let m = ChatQuery.ChatCompletionMessageParam(role: .system, content: message.text) { messages.append(m) }
            case .user:
                if let m = ChatQuery.ChatCompletionMessageParam(role: .user, content: message.text) { messages.append(m) }
            case .assistant:
                let text = message.text
                let toolCalls = message.toolCalls.map { call in
                    ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam(
                        id: call.id,
                        function: .init(arguments: call.arguments, name: call.name)
                    )
                }
                if let m = ChatQuery.ChatCompletionMessageParam(
                    role: .assistant,
                    content: text.isEmpty ? nil : text,
                    toolCalls: toolCalls.isEmpty ? nil : toolCalls
                ) {
                    messages.append(m)
                }
            case .tool:
                for part in message.parts {
                    if case .toolResult(let result) = part {
                        if let m = ChatQuery.ChatCompletionMessageParam(
                            role: .tool, content: result.output, toolCallId: result.callID
                        ) {
                            messages.append(m)
                        }
                    }
                }
            }
        }

        let tools = try context.tools.map { tool -> ChatQuery.ChatCompletionToolParam in
            let schemaData = try JSONEncoder().encode(tool.parameters)
            let schema = try JSONDecoder().decode(JSONSchema.self, from: schemaData)
            return ChatQuery.ChatCompletionToolParam(
                function: .init(name: tool.name, description: tool.description, parameters: schema)
            )
        }

        return ChatQuery(
            messages: messages,
            model: model,
            maxCompletionTokens: options.maxTokens,
            temperature: options.temperature,
            tools: tools.isEmpty ? nil : tools,
            stream: true,
            streamOptions: .init(includeUsage: true)
        )
    }
}
