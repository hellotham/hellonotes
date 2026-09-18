//
//  IntelligenceSettings.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Which model does what, and how the Assistant behaves.
//
//  Two roles, as there always were: the **Assistant** (chat, editing the
//  collection through tools, research) and the **writing tools** (Summarise,
//  Suggest Tags and Links, Rewrite, Compose, Ask Library, ghost text). They stay
//  separate because the right answer genuinely differs — a person may want
//  research on Private Cloud Compute's larger window while their note text is
//  only ever summarised on-device.
//
//  Everything is plain `UserDefaults`, read once and written on change. No
//  Keychain: with no third-party services there are no credentials to keep.
//

import Foundation
import FoundationModels
import Observation

@MainActor
@Observable
final class IntelligenceSettings {

    /// The model, for everything: the Assistant, Summarise, Suggest, Rewrite,
    /// Compose, Ask Library and Research.
    ///
    /// One choice, not one per role. Two were offered — the Assistant's and the
    /// writing tools' — and with MLX they could not even be different, since
    /// one MLX model is loaded at a time. Either the app is using Apple's
    /// model, or it is using yours.
    var model: ModelChoice {
        didSet { defaults.set(model.rawValue, forKey: Keys.model) }
    }

    /// The Assistant's creativity, 0–2 as `GenerationOptions.temperature` is.
    /// The writing tools set their own temperature per task — rewriting wants
    /// determinism whatever the person chose for conversation.
    var temperature: Double {
        didSet { defaults.set(temperature, forKey: Keys.temperature) }
    }

    /// How the model picks each next word — `GenerationOptions.SamplingMode`.
    var sampling: SamplingChoice {
        didSet { defaults.set(sampling.rawValue, forKey: Keys.sampling) }
    }

    /// How many words top-k samples from.
    var samplingTopK: Int {
        didSet { defaults.set(samplingTopK, forKey: Keys.samplingTopK) }
    }

    /// The probability mass top-p samples from.
    var samplingThreshold: Double {
        didSet { defaults.set(samplingThreshold, forKey: Keys.samplingThreshold) }
    }

    /// Fixes the sampler, so a run can be repeated. `nil` — the ordinary case —
    /// leaves it to the framework.
    var samplingSeed: UInt64? {
        didSet {
            if let samplingSeed { defaults.set(String(samplingSeed), forKey: Keys.samplingSeed) }
            else { defaults.removeObject(forKey: Keys.samplingSeed) }
        }
    }

    /// `GenerationOptions.maximumResponseTokens`. `nil` is the framework's own
    /// limit, which is the right answer unless someone wants a shorter one.
    var maximumReplyTokens: Int? {
        didSet {
            if let maximumReplyTokens { defaults.set(maximumReplyTokens, forKey: Keys.maximumReply) }
            else { defaults.removeObject(forKey: Keys.maximumReply) }
        }
    }

    /// How hard a reasoning model thinks, where the model reasons at all.
    var reasoning: ReasoningChoice {
        didSet { defaults.set(reasoning.rawValue, forKey: Keys.reasoning) }
    }

    /// Whether a 1.3.2 installation was using a provider that no longer exists,
    /// so the Assistant can say once, plainly, what changed. Cleared when
    /// acknowledged. Deliberately not the provider's name — see
    /// `IntelligenceMigration`.
    private(set) var hasRetiredProvider: Bool

    let models: LanguageModels
    var mlx: MLXModelStore { models.mlx }

    private let defaults: UserDefaults

    /// `nonisolated` so the migration, which runs before any actor exists to
    /// run it on, can name the keys it writes.
    nonisolated enum Keys {
        static let model = "aiModel"
        /// 1.3.3 offered a model per role for a few days. Read once, on upgrade.
        static let legacyAssistant = "aiAssistantModel"
        static let legacyFeatures = "aiFeaturesModel"
        static let temperature = "aiTemperature"
        static let sampling = "aiSampling"
        static let samplingTopK = "aiSamplingTopK"
        static let samplingThreshold = "aiSamplingThreshold"
        static let samplingSeed = "aiSamplingSeed"
        static let maximumReply = "aiMaximumReplyTokens"
        static let reasoning = "aiReasoning"
        static let retiredProvider = "aiRetiredProvider"
    }

    init(defaults: UserDefaults = .standard, models: LanguageModels? = nil) {
        // First, before anything reads a key: the MLX store restores its model
        // the moment `LanguageModels.shared` is touched, and it has to find the
        // id the migration carries over from 1.3.2.
        IntelligenceMigration.migrateIfNeeded(defaults: defaults)
        self.defaults = defaults
        self.models = models ?? .shared

        // A choice this build cannot offer — Private Cloud Compute, stored by a
        // build that had the entitlement — reads as the default rather than as
        // a setting nothing in the interface can show or change.
        let offered = LanguageModels.offeredChoices
        // The two roles this replaced: whichever of them was set, preferring the
        // Assistant's, so an upgrade keeps the model the person chose rather
        // than resetting to the default.
        let stored = defaults.string(forKey: Keys.model)
            ?? defaults.string(forKey: Keys.legacyAssistant)
            ?? defaults.string(forKey: Keys.legacyFeatures)
        let choice = ModelChoice(stored: stored, fallback: .onDevice)
        model = offered.contains(choice) ? choice : .onDevice
        temperature = min(max(defaults.object(forKey: Keys.temperature) as? Double ?? 0.7, 0), 2)
        sampling = SamplingChoice(rawValue: defaults.string(forKey: Keys.sampling) ?? "") ?? .automatic
        samplingTopK = min(max(defaults.object(forKey: Keys.samplingTopK) as? Int ?? 50, 1), 100)
        samplingThreshold = min(max(defaults.object(forKey: Keys.samplingThreshold) as? Double ?? 0.9, 0.05), 1)
        samplingSeed = defaults.string(forKey: Keys.samplingSeed).flatMap(UInt64.init)
        maximumReplyTokens = (defaults.object(forKey: Keys.maximumReply) as? Int).map { max(1, $0) }
        reasoning = ReasoningChoice(rawValue: defaults.string(forKey: Keys.reasoning) ?? "") ?? .automatic
        hasRetiredProvider = defaults.bool(forKey: Keys.retiredProvider)
    }

    // MARK: - Picker entries

    /// The chosen sampler as `GenerationOptions` wants it. `nil` is Automatic:
    /// the framework's own, which is not the same as any setting here.
    var samplingMode: GenerationOptions.SamplingMode? {
        switch sampling {
        case .automatic: nil
        case .greedy: .greedy
        case .topK: .random(top: samplingTopK, seed: samplingSeed)
        case .topP: .random(probabilityThreshold: samplingThreshold, seed: samplingSeed)
        }
    }

    /// The picker entry the model shows now.
    func option(for choice: ModelChoice) -> ModelOption {
        switch choice {
        case .onDevice: .onDevice
        case .privateCloud: .privateCloud
        case .mlx: .mlx
        }
    }

    /// Choose a picker entry. Which MLX model MLX means is chosen in the MLX
    /// section, where the models are.
    func choose(_ option: ModelOption) { model = option.choice }

    /// Dismiss the "your provider was retired" notice for good.
    func acknowledgeRetiredProvider() {
        hasRetiredProvider = false
        defaults.removeObject(forKey: Keys.retiredProvider)
    }
}
