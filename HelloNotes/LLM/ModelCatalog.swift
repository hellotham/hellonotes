//
//  ModelCatalog.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Data-driven description of the providers HelloNotes can talk to and their
//  suggested models. Model IDs churn and users bring their own keys, so these
//  are seeds/suggestions — Settings lets the user type any model ID.
//

import Foundation

/// Which wire adapter a provider uses. The OpenAI-speakers all collapse into
/// one adapter (they differ only by config), so only three HTTP formats plus two
/// in-process paths exist.
enum LLMWireFormat: Sendable {
    case openAICompatible   // OpenAI, Mistral, OpenRouter, Groq, xAI, DeepSeek, Cerebras, Together, Perplexity, Ollama (local + cloud), LM Studio
    case anthropic          // Claude Messages API
    case gemini             // Google generateContent
    case foundationModels   // Apple on-device (macOS 26+)
    case mlx                // in-process MLX
}

enum ProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case openai, anthropic, gemini, mistral, openrouter, groq
    case xai, deepseek, cerebras, together, perplexity, ollamaCloud
    case ollama, lmstudio, apple, mlx
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic (Claude)"
        case .gemini: return "Google Gemini"
        case .mistral: return "Mistral"
        case .openrouter: return "OpenRouter"
        case .groq: return "Groq"
        case .xai: return "xAI (Grok)"
        case .deepseek: return "DeepSeek"
        case .cerebras: return "Cerebras"
        case .together: return "Together AI"
        case .perplexity: return "Perplexity"
        case .ollamaCloud: return "Ollama Cloud"
        case .ollama: return "Ollama (local)"
        case .lmstudio: return "LM Studio (local)"
        case .apple: return "Apple Intelligence (on-device)"
        case .mlx: return "MLX (on-device)"
        }
    }

    var wire: LLMWireFormat {
        switch self {
        case .openai, .mistral, .openrouter, .groq, .xai, .deepseek, .cerebras,
             .together, .perplexity, .ollamaCloud, .ollama, .lmstudio:
            return .openAICompatible
        case .anthropic: return .anthropic
        case .gemini: return .gemini
        case .apple: return .foundationModels
        case .mlx: return .mlx
        }
    }

    /// Full base URL for HTTP providers (scheme://host[:port]/basePath).
    var defaultBaseURL: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .mistral: return "https://api.mistral.ai/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .xai: return "https://api.x.ai/v1"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .cerebras: return "https://api.cerebras.ai/v1"
        case .together: return "https://api.together.xyz/v1"
        case .perplexity: return "https://api.perplexity.ai"
        case .ollamaCloud: return "https://ollama.com/v1"
        case .ollama: return "http://localhost:11434/v1"
        case .lmstudio: return "http://localhost:1234/v1"
        case .anthropic: return "https://api.anthropic.com"
        case .gemini: return "https://generativelanguage.googleapis.com"
        case .apple, .mlx: return ""
        }
    }

    /// Whether the user must supply an API key (local servers / on-device don't).
    var requiresAPIKey: Bool {
        switch self {
        case .openai, .anthropic, .gemini, .mistral, .openrouter, .groq,
             .xai, .deepseek, .cerebras, .together, .perplexity, .ollamaCloud:
            return true
        case .ollama, .lmstudio, .apple, .mlx: return false
        }
    }

    var isLocal: Bool {
        switch self {
        case .ollama, .lmstudio, .apple, .mlx: return true
        default: return false
        }
    }

    /// Local servers accept an ignored placeholder key.
    var placeholderKey: String? {
        switch self {
        case .ollama: return "ollama"
        case .lmstudio: return "lm-studio"
        default: return nil
        }
    }

    var symbol: String {
        switch self {
        case .openai: return "cpu"
        case .anthropic: return "sparkle"
        case .gemini: return "diamond"
        case .mistral: return "wind"
        case .openrouter: return "arrow.triangle.branch"
        case .groq: return "bolt"
        case .xai: return "x.circle"
        case .deepseek: return "water.waves"
        case .cerebras: return "brain"
        case .together: return "person.2"
        case .perplexity: return "magnifyingglass"
        case .ollamaCloud: return "cloud"
        case .ollama: return "shippingbox"
        case .lmstudio: return "desktopcomputer"
        case .apple: return "apple.logo"
        case .mlx: return "memorychip"
        }
    }

    var tokenPageURL: URL? {
        switch self {
        case .openai: return URL(string: "https://platform.openai.com/api-keys")
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        case .mistral: return URL(string: "https://console.mistral.ai/api-keys")
        case .openrouter: return URL(string: "https://openrouter.ai/keys")
        case .groq: return URL(string: "https://console.groq.com/keys")
        case .xai: return URL(string: "https://console.x.ai")
        case .deepseek: return URL(string: "https://platform.deepseek.com/api_keys")
        case .cerebras: return URL(string: "https://cloud.cerebras.ai")
        case .together: return URL(string: "https://api.together.ai/settings/api-keys")
        case .perplexity: return URL(string: "https://www.perplexity.ai/settings/api")
        case .ollamaCloud: return URL(string: "https://ollama.com/settings/keys")
        default: return nil
        }
    }

    /// Seed model IDs, used **only until the provider has been asked**.
    ///
    /// This array used to be the whole story, and a hand-written array of model
    /// IDs is stale the week after it is written — this one still offered
    /// `gemini-2.0-flash` and `gpt-4o` a generation and a half after both were
    /// superseded. `LLMSettings.refreshModels(for:)` replaces it with what the
    /// key can actually reach, for the fourteen providers that publish a list.
    ///
    /// So these are a first guess for an unconfigured provider, nothing more.
    /// **Checked 27 August 2026**; where a provider offers a self-updating alias
    /// (Mistral's `-latest`) that is preferred, because it cannot go stale.
    var suggestedModels: [String] {
        switch self {
        case .openai: return ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]
        case .anthropic: return ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"]
        case .gemini: return ["gemini-3.7-flash", "gemini-3.5-flash", "gemini-2.5-pro"]
        case .mistral: return ["mistral-large-latest", "mistral-medium-latest", "mistral-small-latest"]
        case .openrouter: return ["openai/gpt-5.6-sol", "anthropic/claude-opus-5", "google/gemini-3.7-flash"]
        case .groq: return ["llama-3.3-70b-versatile", "openai/gpt-oss-120b"]
        case .xai: return ["grok-4.6", "grok-4.3", "grok-4.1-fast"]
        case .deepseek: return ["deepseek-v4-pro", "deepseek-v4-flash"]
        case .cerebras: return ["llama-3.3-70b", "gpt-oss-120b", "qwen-3-235b-a22b-instruct-2507"]
        case .together: return ["meta-llama/Llama-3.3-70B-Instruct-Turbo", "deepseek-ai/DeepSeek-V3", "Qwen/Qwen2.5-72B-Instruct-Turbo"]
        case .perplexity: return ["sonar", "sonar-pro", "sonar-reasoning-pro"]
        case .ollamaCloud: return ["gpt-oss:120b", "deepseek-v3.1:671b", "gemma4:31b"]
        case .ollama: return ["llama3.2", "qwen2.5", "mistral"]
        case .lmstudio: return []
        case .apple: return ["apple-on-device"]
        case .mlx: return ["mlx-community/Qwen3-4B-4bit", "mlx-community/Llama-3.2-3B-Instruct-4bit"]
        }
    }

    /// The highest sampling temperature this provider accepts, before discovery.
    ///
    /// Not cosmetic, and not one number: Anthropic rejects anything above 1.0,
    /// while Gemini and the OpenAI-compatible family go to 2.0 — so the single
    /// `0...1` slider the app shipped was the wrong *range* for one provider and
    /// half the available range for the rest. Gemini states a per-model
    /// `maxTemperature`, which supersedes this when a refresh has run.
    var defaultMaxTemperature: Double {
        switch self {
        case .anthropic: return 1.0
        case .mistral: return 1.5
        case .apple, .mlx: return 1.0
        default: return 2.0
        }
    }

    /// Whether this provider can be asked for its model list.
    ///
    /// Mirrors which adapters implement `availableModels()`. Used only to decide
    /// whether to *offer* a Refresh control — a button that always answers
    /// "this provider does not publish a model list" is a button that should
    /// not be there.
    var supportsModelDiscovery: Bool {
        switch wire {
        case .foundationModels, .mlx: return false
        case .openAICompatible, .anthropic, .gemini: return true
        }
    }

    /// Whether the provider states a context window alongside the model list.
    ///
    /// Eight of the sixteen do. The rest list IDs only, so their context budget
    /// still comes from `ProviderCapabilities` unless the user sets one — and
    /// the settings screen says which of the two it is showing rather than
    /// presenting a fallback as a discovered fact.
    var publishesContextWindow: Bool {
        switch self {
        case .gemini, .anthropic, .openrouter, .mistral, .groq, .together, .ollama, .lmstudio:
            return true
        case .openai, .xai, .deepseek, .cerebras, .perplexity, .ollamaCloud, .apple, .mlx:
            return false
        }
    }

    /// Whether this provider supports native tool calling. The on-device paths
    /// (MLX, and FoundationModels — whose native tools need compile-time types,
    /// not our dynamic registry) are chat-only, so agent mode falls back to plain
    /// chat for them rather than offering tools it can't actually call.
    var supportsTools: Bool { wire != .mlx && wire != .foundationModels }
}
