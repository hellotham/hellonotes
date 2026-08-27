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
            // OpenRouter attribution. Use the canonical custom domain — the old
            // hellotham.github.io URL only 301s here.
            headers["HTTP-Referer"] = "https://hellotham.com/hellonotes/"
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
                    continuation.finish(throwing: Self.attributed(error, to: kind))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Name the provider in the message.
    ///
    /// Twelve providers share this adapter and the SDK's error says which of
    /// them it is nowhere — so a failure arrived as a bare sentence with no
    /// clue where it came from. That is worst in the exact situation the message
    /// exists for: switching providers to find out which one is broken, and
    /// getting two anonymous errors. Gemini's path has always said
    /// "Gemini HTTP 503: …"; this makes the other twelve say who they are too.
    private static func attributed(_ error: Error, to kind: ProviderKind) -> Error {
        // Ours already name themselves.
        if error is LLMError { return error }
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return LLMError.provider("\(kind.displayName): \(text)")
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

// MARK: - Model discovery

extension OpenAICompatibleProvider {

    /// Twelve providers speak this wire format, and they disagree about what a
    /// models listing looks like — wrapped in `data` or a bare array, with the
    /// context window under one of three different keys or absent entirely.
    /// Ollama and LM Studio have richer *native* endpoints beside the
    /// compatibility one, and use them.
    func availableModels() async throws -> [ModelInfo] {
        switch kind {
        case .ollama: return try await ollamaModels()
        case .lmstudio: return try await lmStudioModels()
        default: return try await openAIStyleModels()
        }
    }

    // MARK: OpenAI-compatible /models

    private func openAIStyleModels() async throws -> [ModelInfo] {
        guard let url = URL(string: "\(modelsBase)/models") else {
            throw LLMError.notConfigured("Invalid base URL for \(kind.displayName): \(baseURL)")
        }
        var headers = ["Authorization": "Bearer \(apiKey)"]
        if kind == .openrouter {
            headers["HTTP-Referer"] = "https://hellotham.com/hellonotes/"
            headers["X-Title"] = "HelloNotes"
        }
        let data = try await ModelDiscovery.get(url, headers: headers)
        let entries = try Self.decodeEntries(data)

        return ModelDiscovery.sorted(entries.compactMap { entry -> ModelInfo? in
            // Groq marks retired models inactive; there is no point offering one.
            if entry.active == false { return nil }
            // Where the provider states a kind, believe it. Together says
            // "chat"/"embedding"/"image"; only the first is usable here.
            if let type = entry.type?.lowercased(),
               !["chat", "language", "llm", "vlm"].contains(type) { return nil }
            // Otherwise fall back to the ID heuristic.
            if entry.type == nil, !ModelDiscovery.looksLikeChatModel(entry.id) { return nil }

            let output = entry.max_completion_tokens ?? entry.top_provider?.max_completion_tokens
            return ModelInfo(
                id: entry.id,
                displayName: entry.display_name ?? entry.name,
                // Every key consulted below reports a **total** window, so the
                // reply's share is reserved. `long_context_threshold` is not
                // consulted anywhere — see ModelDiscovery's header.
                inputTokenLimit: ModelDiscovery.inputTokens(total: entry.totalContextTokens, output: output),
                outputTokenLimit: output,
                supportsTools: entry.declaredToolSupport,
                supportsStructuredOutput: entry.declaredStructuredOutput)
        })
    }

    /// The path a models listing hangs off, mirroring `makeClient`: most
    /// providers namespace under `/v1`, Perplexity serves at the root, and a
    /// user-entered base URL is taken as given.
    private var modelsBase: String {
        guard let comps = URLComponents(string: baseURL) else { return baseURL }
        if !comps.path.isEmpty { return baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL }
        return kind == .perplexity ? baseURL : "\(baseURL)/v1"
    }

    /// `{"data": [...]}` or a bare `[...]` — Together returns the latter.
    private static func decodeEntries(_ data: Data) throws -> [OpenAIModelEntry] {
        let decoder = JSONDecoder()
        if let wrapped = try? decoder.decode(OpenAIModelPage.self, from: data) { return wrapped.data }
        if let bare = try? decoder.decode([OpenAIModelEntry].self, from: data) { return bare }
        throw LLMError.provider("Could not read the model list — unexpected format.")
    }

    // MARK: Ollama

    /// Ollama's OpenAI-compatible `/v1/models` returns names and nothing else,
    /// while `/api/tags` plus `/api/show` reports the context length baked into
    /// the GGUF and whether the model was built for tool calling. Both live
    /// beside `/v1`, not under it.
    private func ollamaModels() async throws -> [ModelInfo] {
        guard let root = ModelDiscovery.origin(of: baseURL),
              let tags = URL(string: "\(root.absoluteString)/api/tags") else {
            throw LLMError.notConfigured("Invalid Ollama base URL: \(baseURL)")
        }
        let data = try await ModelDiscovery.get(tags, headers: [:], timeout: 10)
        let listed = try JSONDecoder().decode(OllamaTagList.self, from: data).models

        // One /api/show per model, concurrently and bounded — it is localhost,
        // but a library of thirty models is still thirty round trips and there
        // is no reason to pay for them one at a time. A model whose details
        // cannot be read is still offered, just without a stated window.
        let details = await withTaskGroup(of: (String, OllamaShowResponse?).self) { group in
            for entry in listed.prefix(100) {
                group.addTask { (entry.name, try? await self.ollamaShow(entry.name, root: root)) }
            }
            var byName: [String: OllamaShowResponse] = [:]
            for await (name, response) in group { if let response { byName[name] = response } }
            return byName
        }

        return ModelDiscovery.sorted(listed.map { entry in
            let shown = details[entry.name]
            return ModelInfo(
                id: entry.name,
                // `parameter_size` comes back as an empty *string* rather than
                // absent for MLX-format models, so `.map` alone would render
                // "qwen3.8:27b-mlx · " with a dangling separator.
                displayName: entry.details?.sizeLabel.map { "\(entry.name) · \($0)" } ?? entry.name,
                // A GGUF's context length is the whole window.
                inputTokenLimit: ModelDiscovery.inputTokens(total: shown?.contextLength, output: nil),
                supportsTools: shown?.capabilities.map { $0.contains("tools") })
        })
    }

    private func ollamaShow(_ model: String, root: URL) async throws -> OllamaShowResponse {
        guard let url = URL(string: "\(root.absoluteString)/api/show") else {
            throw LLMError.notConfigured("Invalid Ollama base URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model])
        return try JSONDecoder().decode(OllamaShowResponse.self, from: try await ModelDiscovery.send(request))
    }

    // MARK: LM Studio

    /// LM Studio's native listing states `max_context_length` and, usefully, a
    /// `type` — so embedding models can be excluded by what the server says
    /// rather than by guessing from the name.
    private func lmStudioModels() async throws -> [ModelInfo] {
        guard let root = ModelDiscovery.origin(of: baseURL),
              let url = URL(string: "\(root.absoluteString)/api/v0/models") else {
            throw LLMError.notConfigured("Invalid LM Studio base URL: \(baseURL)")
        }
        let data = try await ModelDiscovery.get(url, headers: [:], timeout: 10)
        let entries = try JSONDecoder().decode(LMStudioModelPage.self, from: data).data
        return ModelDiscovery.sorted(entries.compactMap { entry in
            guard ["llm", "vlm"].contains((entry.type ?? "llm").lowercased()) else { return nil }
            return ModelInfo(
                id: entry.id,
                displayName: entry.id,
                inputTokenLimit: ModelDiscovery.inputTokens(total: entry.max_context_length, output: nil))
        })
    }
}

// MARK: - Wire shapes

private struct OpenAIModelPage: Decodable { let data: [OpenAIModelEntry] }

/// The union of every models-listing field this app has verified the meaning of.
///
/// Adding a key here is a claim that it has been checked. xAI's
/// `long_context_threshold` is deliberately absent: it is a billing breakpoint,
/// and reading it as a window under-reports a 1M-token model as 200k.
private struct OpenAIModelEntry: Decodable {
    let id: String
    let name: String?                  // OpenRouter
    let display_name: String?
    let type: String?                  // Together, LM Studio
    let active: Bool?                  // Groq
    let context_length: Int?           // OpenRouter, Together — total
    let context_window: Int?           // Groq — total
    let max_context_length: Int?       // Mistral — total
    let max_completion_tokens: Int?    // Groq
    let top_provider: OpenRouterTopProvider?
    let capabilities: MistralCapabilities?
    let supported_parameters: [String]?

    /// The total window, from whichever verified key the provider used.
    var totalContextTokens: Int? {
        context_length ?? context_window ?? max_context_length ?? top_provider?.context_length
    }

    /// Tool support where the provider states it, `nil` where it does not.
    ///
    /// The empty-array guard is not defensive padding: three of OpenRouter's
    /// 417 models return `supported_parameters: []`, and reading that as
    /// `false` would be *worse than not asking* — a discovered `false`
    /// overrides the table's `true` and switches Deep Research off for a model
    /// that may support tools perfectly well. An empty list is silence.
    var declaredToolSupport: Bool? {
        if let mistral = capabilities?.function_calling { return mistral }
        guard let parameters = supported_parameters, !parameters.isEmpty else { return nil }
        return parameters.contains("tools")
    }

    /// Schema-constrained output, same rule.
    var declaredStructuredOutput: Bool? {
        guard let parameters = supported_parameters, !parameters.isEmpty else { return nil }
        return parameters.contains("structured_outputs") || parameters.contains("response_format")
    }
}

private struct OpenRouterTopProvider: Decodable {
    let context_length: Int?
    let max_completion_tokens: Int?
}

private struct MistralCapabilities: Decodable {
    let function_calling: Bool?
    let completion_chat: Bool?
}

private struct OllamaTagList: Decodable {
    let models: [OllamaTag]
}

private struct OllamaTag: Decodable {
    let name: String
    let details: OllamaTagDetails?
}

private struct OllamaTagDetails: Decodable {
    let family: String?
    let parameter_size: String?

    /// `nil` for both "absent" and "present but empty" — Ollama reports the
    /// latter for safetensors/MLX models.
    var sizeLabel: String? {
        guard let parameter_size, !parameter_size.isEmpty else { return nil }
        return parameter_size
    }
}

private struct OllamaShowResponse: Decodable {
    let capabilities: [String]?
    let model_info: [String: JSONValue]?

    /// The key is architecture-prefixed — `llama.context_length`,
    /// `qwen2.context_length`, `gemma3.context_length` — so it is found by
    /// suffix rather than named.
    var contextLength: Int? {
        guard let model_info else { return nil }
        for (key, value) in model_info where key.hasSuffix(".context_length") {
            if case .int(let n) = value { return n }
            if case .double(let d) = value { return Int(d) }
        }
        return nil
    }
}

private struct LMStudioModelPage: Decodable { let data: [LMStudioModelEntry] }

private struct LMStudioModelEntry: Decodable {
    let id: String
    let type: String?
    let max_context_length: Int?
}
