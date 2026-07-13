//
//  AnthropicProvider.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Anthropic Claude via the Messages API. A thin URLSession + SSE adapter rather
//  than a third-party SDK: the content-block model (tool_use / tool_result) and
//  arbitrary nested tool schemas round-trip cleanly through our own JSONValue,
//  which the structured SDK types can't express.
//

import Foundation

struct AnthropicProvider: LLMProvider {
    var baseURL: String = "https://api.anthropic.com"
    let apiKey: String

    private static let version = "2023-06-01"

    func stream(_ context: LLMContext, model: String, options: LLMRequestOptions) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(context, model: model, options: options)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.provider("No HTTP response from Anthropic.")
                    }
                    guard (200...299).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw LLMError.provider("Anthropic HTTP \(http.statusCode): \(Self.extractError(body))")
                    }

                    var indexToCall: [Int: String] = [:]
                    var toolIndices = Set<Int>()
                    var usage = LLMUsage()
                    var stop: StopReason = .stop

                    for try await line in bytes.lines {
                        // The `event:` lines are redundant with each chunk's own
                        // `type` field, so only `data:` lines are parsed.
                        if line.hasPrefix("data:") {
                            let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            guard let data = json.data(using: .utf8),
                                  let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else { continue }
                            switch chunk.type {
                            case "message_start":
                                if let input = chunk.message?.usage?.input_tokens { usage.inputTokens = input }
                            case "content_block_start":
                                if let block = chunk.content_block, block.type == "tool_use",
                                   let idx = chunk.index, let id = block.id {
                                    indexToCall[idx] = id
                                    toolIndices.insert(idx)
                                    continuation.yield(.toolCallStarted(id: id, name: block.name ?? ""))
                                }
                            case "content_block_delta":
                                guard let delta = chunk.delta else { break }
                                switch delta.type {
                                case "text_delta":
                                    if let t = delta.text { continuation.yield(.textDelta(t)) }
                                case "thinking_delta":
                                    if let t = delta.thinking { continuation.yield(.thinkingDelta(t)) }
                                case "input_json_delta":
                                    if let idx = chunk.index, let id = indexToCall[idx], let frag = delta.partial_json {
                                        continuation.yield(.toolCallArgumentsDelta(id: id, fragment: frag))
                                    }
                                default: break
                                }
                            case "content_block_stop":
                                if let idx = chunk.index, toolIndices.contains(idx), let id = indexToCall[idx] {
                                    continuation.yield(.toolCallCompleted(id: id))
                                }
                            case "message_delta":
                                if let out = chunk.usage?.output_tokens { usage.outputTokens = out }
                                if let reason = chunk.delta?.stop_reason {
                                    stop = reason == "tool_use" ? .toolCalls : (reason == "max_tokens" ? .length : .stop)
                                }
                            case "message_stop":
                                continuation.yield(.usage(usage))
                                continuation.yield(.done(stop))
                                continuation.finish()
                                return
                            default: break
                            }
                        }
                    }
                    continuation.yield(.usage(usage))
                    continuation.yield(.done(stop))
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

    // MARK: - Request

    private func makeRequest(_ context: LLMContext, model: String, options: LLMRequestOptions) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)/v1/messages") else {
            throw LLMError.notConfigured("Invalid Anthropic base URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.version, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body = AnthropicRequest(
            model: model,
            max_tokens: options.maxTokens ?? 4096,
            system: context.systemPrompt?.nonEmpty,
            messages: Self.mapMessages(context.messages),
            tools: context.tools.isEmpty ? nil : context.tools.map {
                .init(name: $0.name, description: $0.description, input_schema: $0.parameters)
            },
            temperature: options.temperature,
            stream: true
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// Convert our role-tagged messages into Anthropic's content-block turns.
    /// Tool results become `tool_result` blocks in a user turn (Anthropic's rule).
    private static func mapMessages(_ messages: [LLMMessage]) -> [AnthropicRequest.Msg] {
        var out: [AnthropicRequest.Msg] = []
        for message in messages {
            switch message.role {
            case .system:
                continue  // folded into top-level `system`
            case .user:
                out.append(.init(role: "user", content: [.text(message.text)]))
            case .assistant:
                var blocks: [AnthropicRequest.Block] = []
                let text = message.text
                if !text.isEmpty { blocks.append(.text(text)) }
                for call in message.toolCalls {
                    blocks.append(.toolUse(id: call.id, name: call.name, input: call.parsedArguments))
                }
                if !blocks.isEmpty { out.append(.init(role: "assistant", content: blocks)) }
            case .tool:
                let blocks: [AnthropicRequest.Block] = message.parts.compactMap { part in
                    if case .toolResult(let r) = part {
                        return .toolResult(toolUseID: r.callID, content: r.output, isError: r.isError)
                    }
                    return nil
                }
                if !blocks.isEmpty { out.append(.init(role: "user", content: blocks)) }
            }
        }
        return out
    }

    private static func extractError(_ body: String) -> String {
        guard let data = body.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let message = value["error"]?["message"]?.stringValue else { return body }
        return message
    }

    // MARK: - Wire types

    private struct AnthropicRequest: Encodable {
        let model: String
        let max_tokens: Int
        let system: String?
        let messages: [Msg]
        let tools: [ToolDef]?
        let temperature: Double?
        let stream: Bool

        struct Msg: Encodable {
            let role: String
            let content: [Block]
        }

        struct ToolDef: Encodable {
            let name: String
            let description: String
            let input_schema: JSONValue
        }

        enum Block: Encodable {
            case text(String)
            case toolUse(id: String, name: String, input: JSONValue)
            case toolResult(toolUseID: String, content: String, isError: Bool)

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .text(let text):
                    try c.encode("text", forKey: .type)
                    try c.encode(text, forKey: .text)
                case .toolUse(let id, let name, let input):
                    try c.encode("tool_use", forKey: .type)
                    try c.encode(id, forKey: .id)
                    try c.encode(name, forKey: .name)
                    try c.encode(input, forKey: .input)
                case .toolResult(let toolUseID, let content, let isError):
                    try c.encode("tool_result", forKey: .type)
                    try c.encode(toolUseID, forKey: .tool_use_id)
                    try c.encode(content, forKey: .content)
                    if isError { try c.encode(true, forKey: .is_error) }
                }
            }
            enum CodingKeys: String, CodingKey {
                case type, text, id, name, input, tool_use_id, content, is_error
            }
        }
    }

    private struct Chunk: Decodable {
        let type: String
        let index: Int?
        let content_block: CBlock?
        let delta: DeltaObj?
        let usage: UsageObj?
        let message: MsgStart?

        struct CBlock: Decodable { let type: String; let id: String?; let name: String? }
        struct DeltaObj: Decodable {
            let type: String?; let text: String?; let partial_json: String?
            let thinking: String?; let stop_reason: String?
        }
        struct UsageObj: Decodable { let input_tokens: Int?; let output_tokens: Int? }
        struct MsgStart: Decodable { let usage: UsageObj? }
    }
}
