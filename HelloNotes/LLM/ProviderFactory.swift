//
//  ProviderFactory.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Builds a concrete `LLMProvider` from the user's settings for a given provider
//  kind. Additional wire formats (Anthropic, Gemini, FoundationModels, MLX) are
//  wired in as they land.
//

import Foundation

enum ProviderFactory {
    /// Returns a ready provider and the model ID to use, or throws if the
    /// provider isn't configured (missing key, unsupported yet).
    @MainActor
    static func make(for kind: ProviderKind, settings: LLMSettings) throws -> (provider: LLMProvider, model: String) {
        let config = settings.config(for: kind)
        switch kind.wire {
        case .openAICompatible:
            let key: String
            if kind.requiresAPIKey {
                guard let stored = LLMKeychain.key(for: kind), !stored.isEmpty else {
                    throw LLMError.missingAPIKey(kind.displayName)
                }
                key = stored
            } else {
                key = kind.placeholderKey ?? "not-needed"
            }
            let provider = OpenAICompatibleProvider(kind: kind, baseURL: config.baseURL, apiKey: key)
            return (provider, config.model)

        case .anthropic:
            guard let key = LLMKeychain.key(for: kind), !key.isEmpty else {
                throw LLMError.missingAPIKey(kind.displayName)
            }
            return (AnthropicProvider(baseURL: config.baseURL, apiKey: key), config.model)

        case .gemini:
            guard let key = LLMKeychain.key(for: kind), !key.isEmpty else {
                throw LLMError.missingAPIKey(kind.displayName)
            }
            return (GeminiProvider(baseURL: config.baseURL, apiKey: key), config.model)

        case .foundationModels:
            #if os(macOS)
            return (FoundationModelsProvider(), config.model)
            #else
            throw LLMError.unsupported("On-device models require macOS.")
            #endif

        case .mlx:
            #if os(macOS)
            return (MLXProvider(), config.model)
            #else
            throw LLMError.unsupported("On-device models require macOS.")
            #endif
        }
    }
}
