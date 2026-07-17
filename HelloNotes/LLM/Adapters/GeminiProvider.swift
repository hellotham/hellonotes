//
//  GeminiProvider.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Google Gemini via streamGenerateContent (SSE). Own URLSession adapter — the
//  official Swift SDK was deprecated in favour of a Firebase dependency, which
//  we avoid. Gemini emits complete functionCall parts (no arg streaming), so we
//  surface each tool call in one shot.
//

import Foundation

struct GeminiProvider: LLMProvider {
    var baseURL: String = "https://generativelanguage.googleapis.com"
    let apiKey: String

    func stream(_ context: LLMContext, model: String, options: LLMRequestOptions) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(context, model: model, options: options)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.provider("No HTTP response from Gemini.")
                    }
                    guard (200...299).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 16_384 { break } }
                        throw LLMError.provider("Gemini HTTP \(http.statusCode): \(Self.extractError(body))")
                    }

                    var usage = LLMUsage()
                    var sawToolCall = false
                    var callCounter = 0
                    var stop: StopReason = .stop

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !json.isEmpty, let data = json.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(GResp.self, from: data) else { continue }

                        if let meta = chunk.usageMetadata {
                            usage = LLMUsage(inputTokens: meta.promptTokenCount ?? usage.inputTokens,
                                             outputTokens: meta.candidatesTokenCount ?? usage.outputTokens)
                        }
                        guard let candidate = chunk.candidates?.first else { continue }
                        for part in candidate.content?.parts ?? [] {
                            if let text = part.text, !text.isEmpty {
                                continuation.yield(.textDelta(text))
                            }
                            if let call = part.functionCall {
                                sawToolCall = true
                                let id = "call_\(callCounter)"; callCounter += 1
                                continuation.yield(.toolCallStarted(id: id, name: call.name))
                                let argsJSON = (call.args ?? .object([:])).jsonString
                                continuation.yield(.toolCallArgumentsDelta(id: id, fragment: argsJSON))
                                continuation.yield(.toolCallCompleted(id: id))
                            }
                        }
                        if let reason = candidate.finishReason {
                            stop = reason == "MAX_TOKENS" ? .length : (sawToolCall ? .toolCalls : .stop)
                        }
                    }
                    if sawToolCall { stop = .toolCalls }
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
        guard let url = URL(string: "\(baseURL)/v1beta/models/\(model):streamGenerateContent?alt=sse") else {
            throw LLMError.notConfigured("Invalid Gemini model or base URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        // callID → function name, so tool results can name their function.
        var names: [String: String] = [:]
        for message in context.messages where message.role == .assistant {
            for call in message.toolCalls { names[call.id] = call.name }
        }

        let body = GeminiRequest(
            contents: Self.mapContents(context.messages, names: names),
            tools: context.tools.isEmpty ? nil : [.init(functionDeclarations: context.tools.map {
                .init(name: $0.name, description: $0.description, parameters: $0.parameters)
            })],
            systemInstruction: context.systemPrompt?.nonEmpty.map { .init(parts: [.text($0)]) },
            generationConfig: options.temperature.map { .init(temperature: $0) }
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private static func mapContents(_ messages: [LLMMessage], names: [String: String]) -> [GeminiRequest.Content] {
        var out: [GeminiRequest.Content] = []
        for message in messages {
            switch message.role {
            case .system:
                continue
            case .user:
                out.append(.init(role: "user", parts: [.text(message.text)]))
            case .assistant:
                var parts: [GeminiRequest.Part] = []
                if !message.text.isEmpty { parts.append(.text(message.text)) }
                for call in message.toolCalls {
                    parts.append(.functionCall(name: call.name, args: call.parsedArguments))
                }
                if !parts.isEmpty { out.append(.init(role: "model", parts: parts)) }
            case .tool:
                let parts: [GeminiRequest.Part] = message.parts.compactMap { part in
                    if case .toolResult(let r) = part {
                        let name = names[r.callID] ?? r.callID
                        return .functionResponse(name: name, response: .object(["result": .string(r.output)]))
                    }
                    return nil
                }
                if !parts.isEmpty { out.append(.init(role: "user", parts: parts)) }
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

    private struct GeminiRequest: Encodable {
        let contents: [Content]
        let tools: [ToolBlock]?
        let systemInstruction: SysInstr?
        let generationConfig: GenConfig?

        struct Content: Encodable { let role: String; let parts: [Part] }
        struct ToolBlock: Encodable { let functionDeclarations: [FuncDecl] }
        struct FuncDecl: Encodable { let name: String; let description: String; let parameters: JSONValue }
        struct SysInstr: Encodable { let parts: [Part] }
        struct GenConfig: Encodable { let temperature: Double? }

        enum Part: Encodable {
            case text(String)
            case functionCall(name: String, args: JSONValue)
            case functionResponse(name: String, response: JSONValue)

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .text(let text):
                    try c.encode(text, forKey: .text)
                case .functionCall(let name, let args):
                    try c.encode(FunctionCall(name: name, args: args), forKey: .functionCall)
                case .functionResponse(let name, let response):
                    try c.encode(FunctionResponse(name: name, response: response), forKey: .functionResponse)
                }
            }
            enum CodingKeys: String, CodingKey { case text, functionCall, functionResponse }
            struct FunctionCall: Encodable { let name: String; let args: JSONValue }
            struct FunctionResponse: Encodable { let name: String; let response: JSONValue }
        }
    }

    private struct GResp: Decodable {
        let candidates: [Cand]?
        let usageMetadata: UsageMeta?
        struct Cand: Decodable { let content: Content?; let finishReason: String? }
        struct Content: Decodable { let parts: [Part]?; let role: String? }
        struct Part: Decodable { let text: String?; let functionCall: FCall? }
        struct FCall: Decodable { let name: String; let args: JSONValue? }
        struct UsageMeta: Decodable { let promptTokenCount: Int?; let candidatesTokenCount: Int? }
    }
}
