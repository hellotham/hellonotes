//
//  ModelInfo.swift
//  HelloNotes
//
//  Created by Chris Tham on 27/8/2026.
//
//  What a provider says about one of its models — asked, not remembered.
//
//  `ModelCatalog.suggestedModels` is a hand-written array, and a hand-written
//  array of model IDs is stale the week after it is written. Worse, it was the
//  *only* thing the app knew: the context window came from a `switch` over
//  provider identity, so a 1M-token model and a 32k one behind the same provider
//  were told they could read the same 100,000 characters.
//
//  Every field here is optional except the ID, because provider support is
//  genuinely uneven and pretending otherwise is how a wrong number gets treated
//  as a fact. Of the sixteen providers, fourteen publish a model list and eight
//  of those state a context window; the rest fall back to `ProviderCapabilities`
//  and the user's own override, in that order.
//

import Foundation

/// One model a provider reports, with whatever it chose to tell us about it.
///
/// `nil` means **"the provider did not say"** — never "no" and never a default.
/// A caller that wants a number when the provider was silent asks
/// `ProviderCapabilities`, which is where the fallbacks live.
struct ModelInfo: Codable, Equatable, Sendable, Identifiable {
    /// The identifier to put on the wire.
    var id: String
    /// A human label. Falls back to `id` where the provider offers no other name.
    var displayName: String
    /// Maximum **input** tokens.
    ///
    /// Normalised on the way in: Groq reports one `context_window` covering
    /// input *and* output, so its adapter subtracts `max_completion_tokens`
    /// before storing it here. What this property means is the same for every
    /// provider — how much may be *sent*.
    var inputTokenLimit: Int?
    /// Maximum tokens the model may generate.
    var outputTokenLimit: Int?
    /// The provider's own default sampling temperature.
    var defaultTemperature: Double?
    /// The highest temperature this model accepts. Gemini states it per model
    /// (`maxTemperature`, commonly 2.0); Anthropic's ceiling is 1.0.
    var maxTemperature: Double?
    /// Whether the provider says this model can call tools.
    var supportsTools: Bool?
    /// Whether the provider says this model can return schema-constrained output.
    var supportsStructuredOutput: Bool?

    init(id: String,
         displayName: String? = nil,
         inputTokenLimit: Int? = nil,
         outputTokenLimit: Int? = nil,
         defaultTemperature: Double? = nil,
         maxTemperature: Double? = nil,
         supportsTools: Bool? = nil,
         supportsStructuredOutput: Bool? = nil) {
        self.id = id
        self.displayName = displayName.flatMap { $0.isEmpty ? nil : $0 } ?? id
        self.inputTokenLimit = inputTokenLimit
        self.outputTokenLimit = outputTokenLimit
        self.defaultTemperature = defaultTemperature
        self.maxTemperature = maxTemperature
        self.supportsTools = supportsTools
        self.supportsStructuredOutput = supportsStructuredOutput
    }

    /// Decoded defensively: this type is persisted in `ProviderConfig`, and a
    /// field added here later must not make an older stored blob undecodable.
    /// `LLMSettings` decodes with `try?` and falls back to *defaults for every
    /// provider*, so one throw would silently wipe the user's keys-adjacent
    /// configuration. Every property is `decodeIfPresent`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? id
        inputTokenLimit = try c.decodeIfPresent(Int.self, forKey: .inputTokenLimit)
        outputTokenLimit = try c.decodeIfPresent(Int.self, forKey: .outputTokenLimit)
        defaultTemperature = try c.decodeIfPresent(Double.self, forKey: .defaultTemperature)
        maxTemperature = try c.decodeIfPresent(Double.self, forKey: .maxTemperature)
        supportsTools = try c.decodeIfPresent(Bool.self, forKey: .supportsTools)
        supportsStructuredOutput = try c.decodeIfPresent(Bool.self, forKey: .supportsStructuredOutput)
    }
}

extension ModelInfo {
    /// Characters per token, for turning a provider's token limit into the
    /// character budget the trimming code actually works in.
    ///
    /// Deliberately below the ~4 that English prose averages. The conversion is
    /// only ever used to decide *how much to send*, so erring low costs a little
    /// unused window and erring high costs a rejected request — and notes are not
    /// always English prose. Code, CJK and heavy Markdown all tokenise denser
    /// than 4 characters per token.
    static let charactersPerToken = 3.5

    /// The input limit in characters, when the provider stated one.
    var inputCharacterLimit: Int? {
        guard let inputTokenLimit, inputTokenLimit > 0 else { return nil }
        return Int(Double(inputTokenLimit) * Self.charactersPerToken)
    }

    /// A short "1M context" / "128k context" label for the picker.
    var contextLabel: String? {
        guard let limit = inputTokenLimit, limit > 0 else { return nil }
        if limit >= 1_000_000 {
            let millions = Double(limit) / 1_048_576
            return "\(millions < 1.5 ? "1" : String(Int(millions.rounded())))M context"
        }
        if limit >= 1_000 { return "\(limit / 1_024)k context" }
        return "\(limit) tokens"
    }
}
