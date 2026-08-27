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

    /// Where `inputBudget` came from.
    ///
    /// Carried so the settings screen can *say*. A discovered 3.6M-character
    /// budget and a fallback 100,000-character one look identical as numbers
    /// and mean completely different things — one is what the model reported,
    /// the other is a floor the app picked because the provider would not say.
    var budgetSource: BudgetSource = .providerDefault
}

/// How `ProviderCapabilities.inputBudget` was arrived at.
enum BudgetSource: Equatable, Sendable {
    /// The user typed a number in Settings.
    case userOverride
    /// The provider reported it for this model.
    case discovered(model: String)
    /// Nobody asked or nobody answered — the table below.
    case providerDefault
}

/// What a feature needs in order to be worth offering.
///
/// A requirement is a statement about the *feature*, not about any provider —
/// which is what lets a new provider satisfy it without anyone revisiting the
/// feature.
struct IntelligenceNeeds: Equatable, Sendable {
    /// The least a provider must offer for this feature to be worth offering
    /// at all. A **floor**, tested by `satisfied(by:)`.
    var minimumBudget: Int = 0

    /// The most input this feature can put to use, or `nil` for "as much as the
    /// provider will hold". A **ceiling**, and a different question entirely.
    ///
    /// These were one field, and one field cannot be both. `askLibrary`
    /// declaring `12_000` meant *both* "needs at least 12,000 characters" and
    /// "never send more than 12,000 characters", because the eligibility check
    /// read it as a floor while `IntelligenceService.budget(for:)` read the same
    /// number as a cap through `min(feature, provider)`. The floor was always
    /// the smaller operand, so the provider's number never once mattered: a
    /// million-token model was fed 12,000 characters — about 0.3% of its window
    /// — and raising the provider's declared budget changed nothing at all,
    /// which is exactly why the symptom was invisible.
    var inputCeiling: Int?

    var structuredOutput = false
    var toolUse = false
    /// Set only where a network round trip would break the feature rather than
    /// merely slow it — ghost text, and nothing else so far.
    var onDevice = false

    func satisfied(by c: ProviderCapabilities) -> Bool {
        c.inputBudget >= minimumBudget
            && (!structuredOutput || c.structuredOutput)
            && (!toolUse || c.toolUse)
            && (!onDevice || c.onDevice)
    }
}

extension IntelligenceNeeds {
    //
    //  Every content-bearing feature below declares a floor and **no ceiling**.
    //
    //  That is the behaviour change: summarising a 20,000-character note used to
    //  summarise its first 4,000 characters and present the result as a summary
    //  of the note, saying nothing about the other 16,000. The truncation was
    //  never a judgement about the feature — it was the eligibility floor being
    //  read as a cap. What the provider can hold is now the only limit, and the
    //  user can lower it per provider in Settings if they would rather pay less.
    //

    /// A note fits, and prose is the answer. Works anywhere.
    static let summarise = IntelligenceNeeds(minimumBudget: 4_000)
    /// Rewriting sends the passage and gets a passage back.
    static let rewrite = IntelligenceNeeds(minimumBudget: 4_000)
    /// Tags and links are *lists*. Schema-constrained output is not required —
    /// there is a reply parser for providers without it — but it is the
    /// difference between clean results and results that depend on a model
    /// remembering to answer in the requested shape.
    static let suggestTags = IntelligenceNeeds(minimumBudget: 4_000)
    static let suggestLinks = IntelligenceNeeds(minimumBudget: 6_000)
    /// Composing a note sends a prompt and a list of note titles to link, and
    /// gets prose back. The budget is for the titles, not the prompt.
    static let compose = IntelligenceNeeds(minimumBudget: 4_000)
    /// Ask Library stuffs several whole notes into one prompt.
    static let askLibrary = IntelligenceNeeds(minimumBudget: 12_000)
    /// Deep research decomposes a question, runs sub-agents and cites them.
    static let deepResearch = IntelligenceNeeds(minimumBudget: 24_000, toolUse: true)
    /// Ghost text must appear between keystrokes. A cloud round trip cannot.
    ///
    /// The one feature that keeps a ceiling, and keeps it for a reason that is
    /// about the feature rather than the provider: the completion continues the
    /// text at the caret, so a wider window is not a better answer — it is a
    /// slower one, and this is the only feature racing a keystroke.
    static let inlineCompletion = IntelligenceNeeds(minimumBudget: 2_000,
                                                    inputCeiling: 2_000,
                                                    onDevice: true)
}

extension ProviderCapabilities {
    /// What `kind` can do **when nobody has asked the provider**.
    ///
    /// The cloud numbers are deliberately conservative floors rather than each
    /// provider's headline context window: the user types their own model ID, so
    /// the *declared* provider says almost nothing about which model is actually
    /// behind it. A floor that every model of that family clears is a promise we
    /// can keep; a headline number is a promise the user's chosen model may not.
    ///
    /// That reasoning is sound and it is also the wrong trade to still be making,
    /// because the premise — that we cannot know which model is behind the
    /// provider — stopped being true. Eight providers state a per-model context
    /// window, and `of(_:config:)` below prefers what they said. This remains the
    /// answer for the other eight, and for any provider not yet refreshed.
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

    /// What `kind` can do **given the model the user actually selected**.
    ///
    /// Resolution order, most specific first:
    ///
    /// 1. the user's own override, because a person who typed a number has
    ///    settled the question;
    /// 2. what the provider reported for this model, when it reports one;
    /// 3. the table above.
    ///
    /// Tool use and structured output resolve the same way, and for the same
    /// reason: Anthropic's models endpoint states `structured_outputs` per model
    /// and Mistral's states `function_calling`, so a capability the provider
    /// will tell us about should not be a constant keyed on its name.
    static func of(_ kind: ProviderKind, config: ProviderConfig) -> ProviderCapabilities {
        var caps = of(kind)
        let info = config.selectedModelInfo

        if let override = config.inputBudgetOverride, override > 0 {
            caps.inputBudget = override
            caps.budgetSource = .userOverride
        } else if let discovered = info?.inputCharacterLimit {
            caps.inputBudget = discovered
            caps.budgetSource = .discovered(model: info?.id ?? config.model)
        }

        if let tools = info?.supportsTools { caps.toolUse = tools }
        if let structured = info?.supportsStructuredOutput { caps.structuredOutput = structured }
        return caps
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
