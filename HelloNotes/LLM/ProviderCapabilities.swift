//
//  ProviderCapabilities.swift
//  HelloNotes
//
//  Created by Chris Tham on 16/8/2026.
//
//  What a provider can do, described rather than assumed.
//
//  Every AI feature used to ask the same question — `provider == .apple` — and
//  branch on the answer. That works exactly until the answer stops meaning what
//  it meant. "Apple Intelligence" is not one model: it is whatever the on-device
//  model is on the OS you happen to be running, and it grows. A call site that
//  says `if isApple { short path } else { long path }` has hard-coded a guess
//  about a model's *limits* into a check about its *identity*, and when the
//  limits move the guess is silently wrong — the feature keeps working and keeps
//  being worse than it needs to be, which is the hardest kind of bug to notice.
//
//  So features declare what they need and providers declare what they offer.
//  Adopting a better on-device model then means editing one declaration in this
//  file; features that become newly possible light up on their own, and features
//  that still exceed it keep routing to the cloud. Nothing in this file predicts
//  what a future OS will offer — it only makes the answer a thing you state in
//  one place rather than a thing scattered across a dozen call sites.
//

import Foundation

/// What a provider can do.
struct ProviderCapabilities: Equatable, Sendable {
    /// How much input text to send, in characters.
    ///
    /// Characters rather than tokens on purpose: the callers are trimming note
    /// bodies, tokenisers differ per provider, and a rough honest number beats a
    /// precise one computed with the wrong tokeniser. Roughly 4 characters per
    /// token, held well under the true window to leave room for the reply.
    var inputBudget: Int

    /// Returns output constrained to a schema — so a list of tags arrives as a
    /// list of tags, not as prose that has to be parsed back into one.
    var structuredOutput: Bool

    /// Can call tools, which is what deep research and the agent are built on.
    var toolUse: Bool

    /// Runs on this device: no network, no per-token cost, no data leaving the
    /// Mac, and latency low enough for something that reacts to typing.
    var onDevice: Bool

    /// Free at the point of use. Distinct from `onDevice` — a local Ollama is
    /// both, a hosted model is neither, and there is no reason to assume they
    /// move together.
    var isFree: Bool
}

/// What a feature needs in order to be worth offering.
///
/// A requirement is a statement about the *feature*, not about any provider —
/// which is what lets a new provider satisfy it without anyone revisiting the
/// feature.
struct IntelligenceNeeds: Equatable, Sendable {
    var inputBudget: Int = 0
    var structuredOutput = false
    var toolUse = false
    /// Set only where a network round trip would break the feature rather than
    /// merely slow it — ghost text, and nothing else so far.
    var onDevice = false

    func satisfied(by c: ProviderCapabilities) -> Bool {
        c.inputBudget >= inputBudget
            && (!structuredOutput || c.structuredOutput)
            && (!toolUse || c.toolUse)
            && (!onDevice || c.onDevice)
    }
}

extension IntelligenceNeeds {
    /// A note fits, and prose is the answer. Works anywhere.
    static let summarise = IntelligenceNeeds(inputBudget: 4_000)
    /// Rewriting sends the passage and gets a passage back.
    static let rewrite = IntelligenceNeeds(inputBudget: 4_000)
    /// Tags and links are *lists*. Schema-constrained output is not required —
    /// there is a reply parser for providers without it — but it is the
    /// difference between clean results and results that depend on a model
    /// remembering to answer in the requested shape.
    static let suggestTags = IntelligenceNeeds(inputBudget: 4_000)
    static let suggestLinks = IntelligenceNeeds(inputBudget: 6_000)
    /// Ask Library stuffs several whole notes into one prompt.
    static let askLibrary = IntelligenceNeeds(inputBudget: 12_000)
    /// Deep research decomposes a question, runs sub-agents and cites them.
    static let deepResearch = IntelligenceNeeds(inputBudget: 24_000, toolUse: true)
    /// Ghost text must appear between keystrokes. A cloud round trip cannot.
    static let inlineCompletion = IntelligenceNeeds(inputBudget: 2_000, onDevice: true)
}

extension ProviderCapabilities {
    /// What `kind` can do.
    ///
    /// The cloud numbers are deliberately conservative floors rather than each
    /// provider's headline context window: the user types their own model ID, so
    /// the *declared* provider says almost nothing about which model is actually
    /// behind it. A floor that every model of that family clears is a promise we
    /// can keep; a headline number is a promise the user's chosen model may not.
    static func of(_ kind: ProviderKind) -> ProviderCapabilities {
        switch kind {
        case .apple:
            return appleOnDevice
        case .mlx:
            // A local model the user chose and sized themselves. On-device and
            // free; tool use depends entirely on that model, so assume not.
            return .init(inputBudget: 6_000, structuredOutput: false,
                         toolUse: false, onDevice: true, isFree: true)
        case .ollama, .lmstudio:
            return .init(inputBudget: 8_000, structuredOutput: false,
                         toolUse: true, onDevice: true, isFree: true)
        case .anthropic, .openai, .gemini:
            return .init(inputBudget: 100_000, structuredOutput: true,
                         toolUse: true, onDevice: false, isFree: false)
        case .mistral, .openrouter, .groq, .xai, .deepseek,
             .cerebras, .together, .ollamaCloud:
            return .init(inputBudget: 24_000, structuredOutput: false,
                         toolUse: true, onDevice: false, isFree: false)
        case .perplexity:
            // Search-backed, so its own retrieval is the point; tool use through
            // our layer is not what it is for.
            return .init(inputBudget: 16_000, structuredOutput: false,
                         toolUse: false, onDevice: false, isFree: false)
        }
    }

    /// Apple's on-device model, as this OS actually presents it.
    ///
    /// **This is the seam a new OS moves.** The current on-device model takes a
    /// small context and does support guided generation (`@Generable`), which is
    /// why structured output is true while the budget is low. When the on-device
    /// model grows — or when the framework starts reporting its own limits —
    /// this property is the single place that changes, and every feature that
    /// becomes newly possible starts routing here without being touched.
    ///
    /// The version check is the honest form of "we don't know yet": we can state
    /// what today's model does, and we deliberately do not guess at tomorrow's.
    static var appleOnDevice: ProviderCapabilities {
        var caps = ProviderCapabilities(inputBudget: 4_000, structuredOutput: true,
                                        toolUse: false, onDevice: true, isFree: true)
        if #available(macOS 27.0, iOS 27.0, *) {
            // Raise these once the shipping model's limits are known. Left equal
            // to the 26 figures on purpose: an optimistic guess here would route
            // Ask Library at a context the model cannot hold, and the failure
            // would look like the *feature* being bad rather than the guess.
            caps.inputBudget = 4_000
        }
        return caps
    }
}

extension ProviderKind {
    var capabilities: ProviderCapabilities { .of(self) }
}
