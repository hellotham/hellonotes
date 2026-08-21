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
            // Gated on the *framework*, not the platform, because that is what
            // `FoundationModelsProvider` itself is gated on — and Foundation
            // Models ships on iOS 26 too, where `IntelligenceService` and
            // `NoteIntelligence` already run it. Gating on `os(macOS)` told an
            // iPad that was running the model it needed a Mac, while the
            // provider picker went on offering "Apple Intelligence (on-device)"
            // there: every chat turn failed on a claim that was untrue.
            #if canImport(FoundationModels)
            return (FoundationModelsProvider(), config.model)
            #else
            // The framework is genuinely absent: name the OS version *this*
            // reader would need, not the Mac's.
            throw LLMError.unsupported(NoteIntelligence.tooOldMessage)
            #endif

        case .mlx:
            // This one really is Mac-only — `MLXProvider` is `#if os(macOS)`, so
            // off the Mac the type does not exist to return.
            #if os(macOS)
            return (MLXProvider(), config.model)
            #else
            throw LLMError.unsupported("MLX models run on the Mac only.")
            #endif
        }
    }
}
