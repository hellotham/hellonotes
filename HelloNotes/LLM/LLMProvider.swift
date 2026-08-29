//
//  LLMProvider.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  The single seam every model backend implements. Cloud SDKs (OpenAI-compatible,
//  Anthropic, Gemini) and in-process backends (Apple FoundationModels, MLX) all
//  hide their quirks behind one `stream()` method returning provider-agnostic
//  `StreamEvent`s.
//

import Foundation

/// A tool the model may call, described by a JSON-Schema parameter object.
struct LLMTool: Sendable, Equatable {
    var name: String
    var description: String
    var parameters: JSONValue   // a JSON-Schema `object`
}

/// Everything a provider needs to generate the next assistant turn.
struct LLMContext: Sendable {
    var systemPrompt: String?
    var messages: [LLMMessage]
    var tools: [LLMTool]

    init(systemPrompt: String? = nil, messages: [LLMMessage], tools: [LLMTool] = []) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
    }
}

/// Generation knobs common across providers.
///
/// `maxTokens` existed here for a year and no caller ever set it, so every
/// request took whatever default the provider felt like — which is how a
/// summary could arrive truncated with nothing in the app able to say why.
/// `ProviderConfig` now supplies it, discovered or user-set.
struct LLMRequestOptions: Sendable {
    var temperature: Double?
    var maxTokens: Int?
    init(temperature: Double? = nil, maxTokens: Int? = nil) {
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
}

protocol LLMProvider: Sendable {
    /// Stream the next assistant turn for `context` using `model`.
    func stream(_ context: LLMContext, model: String, options: LLMRequestOptions) -> AsyncThrowingStream<StreamEvent, Error>

    /// Ask the provider which models this key can actually use.
    ///
    /// Fourteen of the sixteen providers answer this; the two that cannot are
    /// the on-device ones and they inherit the default below. Throwing rather
    /// than returning `[]` is deliberate — "this provider publishes no list" and
    /// "this key has no models" are different answers and the UI says different
    /// things about them.
    func availableModels() async throws -> [ModelInfo]
}

extension LLMProvider {
    func stream(_ context: LLMContext, model: String) -> AsyncThrowingStream<StreamEvent, Error> {
        stream(context, model: model, options: LLMRequestOptions())
    }

    func availableModels() async throws -> [ModelInfo] {
        throw LLMError.unsupported("This provider does not publish a model list.")
    }
}

enum LLMError: LocalizedError {
    case missingAPIKey(String)
    case notConfigured(String)
    case unsupported(String)
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let p): return "No API key set for \(p). Add one in Assistant Settings."
        case .notConfigured(let m): return m
        case .unsupported(let m): return m
        case .provider(let m): return m
        }
    }
}
