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

    /// Seed model IDs shown as suggestions (the user may enter any ID).
    var suggestedModels: [String] {
        switch self {
        case .openai: return ["gpt-4o", "gpt-4o-mini", "o4-mini"]
        case .anthropic: return ["claude-sonnet-4-5", "claude-opus-4-1", "claude-haiku-4-5"]
        case .gemini: return ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.0-flash"]
        case .mistral: return ["mistral-large-latest", "mistral-small-latest", "open-mistral-nemo"]
        case .openrouter: return ["openai/gpt-4o", "anthropic/claude-sonnet-4.5", "google/gemini-2.5-flash"]
        case .groq: return ["llama-3.3-70b-versatile", "openai/gpt-oss-120b"]
        case .xai: return ["grok-4", "grok-3", "grok-3-mini"]
        case .deepseek: return ["deepseek-chat", "deepseek-reasoner"]
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

    /// Whether this provider supports native tool calling. The on-device paths
    /// (MLX, and FoundationModels — whose native tools need compile-time types,
    /// not our dynamic registry) are chat-only, so agent mode falls back to plain
    /// chat for them rather than offering tools it can't actually call.
    var supportsTools: Bool { wire != .mlx && wire != .foundationModels }
}
