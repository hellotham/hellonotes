//
//  ModelDiscovery.swift
//  HelloNotes
//
//  Created by Chris Tham on 27/8/2026.
//
//  Asking each provider what models it has, and what they can hold.
//
//  Support is uneven and the differences are not cosmetic, so the mapping is
//  written out per provider rather than guessed by pattern:
//
//    Gemini      /v1beta/models        inputTokenLimit, outputTokenLimit,
//                                      maxTemperature, supportedGenerationMethods
//    Anthropic   /v1/models            max_input_tokens, max_tokens,
//                                      capabilities.structured_outputs
//    OpenRouter  /models               context_length, top_provider.*,
//                                      supported_parameters
//    Mistral     /models               max_context_length, capabilities.*
//    Groq        /models               context_window, max_completion_tokens
//    Together    /models               context_length
//    LM Studio   /api/v0/models        max_context_length, type
//    Ollama      /api/tags + /api/show model_info["<arch>.context_length"]
//    OpenAI, DeepSeek, Cerebras,
//    Perplexity, xAI                   IDs only — no window is published
//
//  **xAI is the reason this is an allow-list and not a heuristic.** Its models
//  response carries `long_context_threshold`, which is the token count above
//  which input is billed at a higher rate — not the context window. Anything
//  that scooped up "the field with `context` in the name" would report 200k for
//  a model that holds far more, and that exact misreading is a filed bug in
//  another client. A key is mapped here only where it has been checked to mean
//  what this file wants it to mean.
//
//  One more asymmetry worth stating: Gemini and Anthropic report an **input**
//  limit directly, while the OpenAI-compatible family reports a **total** window
//  covering input and output together. `inputTokens(total:output:)` reconciles
//  the two so `ModelInfo.inputTokenLimit` means one thing everywhere.
//

import Foundation

enum ModelDiscovery {

    // MARK: - Transport

    /// A JSON GET with the provider's own auth headers.
    ///
    /// A short timeout on purpose: this runs behind a button the user pressed
    /// and is expected to answer or fail, not hang. A provider that is slow to
    /// list models is not a provider whose list is worth waiting a minute for.
    static func get(_ url: URL, headers: [String: String], timeout: TimeInterval = 20) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        return try await send(request)
    }

    static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.provider("No HTTP response listing models.")
        }
        guard (200...299).contains(http.statusCode) else {
            throw LLMError.provider("Listing models failed: HTTP \(http.statusCode). \(briefError(data))")
        }
        return data
    }

    /// The useful sentence out of an error body, without dumping a page of JSON
    /// into a label.
    private static func briefError(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let message = object["error"] as? String { return message }
        if let message = object["message"] as? String { return message }
        return ""
    }

    /// Trim a base URL back to its origin, for the providers whose *native* API
    /// sits beside the OpenAI-compatible one rather than under it. Ollama's
    /// configured base is `http://localhost:11434/v1`, and `/api/tags` is not
    /// under `/v1`.
    static func origin(of baseURL: String) -> URL? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        components.path = ""
        components.query = nil
        return components.url
    }

    // MARK: - Normalising

    /// The input allowance, given a **total** window and whatever the provider
    /// says about output.
    ///
    /// The OpenAI-compatible family reports one number covering both directions,
    /// so sending all of it as input leaves no room for the reply and the
    /// request is rejected at the far end. Where the provider states an output
    /// cap we reserve exactly that; where it does not we reserve an eighth, and
    /// never let the reservation take more than half the window — a model
    /// advertising a 4,096-token output cap on an 8,192-token window should
    /// still be usable.
    static func inputTokens(total: Int?, output: Int?) -> Int? {
        guard let total, total > 0 else { return nil }
        let reserve = output.map { min($0, total / 2) } ?? min(4_096, total / 8)
        return max(total - reserve, total / 2)
    }

    /// Model IDs that are not chat models.
    ///
    /// A heuristic, and labelled as one: several providers return embeddings,
    /// speech and image models from the same endpoint with nothing in the
    /// payload that distinguishes them. Where a provider *does* say — Together's
    /// `type`, LM Studio's `type` — that answer is used instead and this is not
    /// consulted. Erring towards showing a model the user cannot chat with is
    /// better than hiding one they can.
    private static let nonChatMarkers = [
        "embed", "whisper", "tts-", "-tts", "dall-e", "moderation",
        "rerank", "guard", "stable-diffusion", "flux", "clip-",
    ]

    static func looksLikeChatModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        return !nonChatMarkers.contains { lower.contains($0) }
    }

    /// Newest-looking first, then alphabetical — the ordering a picker wants.
    /// Providers disagree about ordering (Anthropic promises newest-first,
    /// others promise nothing), so we impose one.
    static func sorted(_ models: [ModelInfo]) -> [ModelInfo] {
        models.sorted { lhs, rhs in
            let l = lhs.inputTokenLimit ?? 0, r = rhs.inputTokenLimit ?? 0
            if l != r { return l > r }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }
}
