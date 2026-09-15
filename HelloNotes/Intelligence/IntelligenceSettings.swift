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
import Observation

@MainActor
@Observable
final class IntelligenceSettings {

    /// The model behind the Assistant window.
    var assistantModel: ModelChoice {
        didSet { defaults.set(assistantModel.rawValue, forKey: Keys.assistant) }
    }

    /// The model behind Summarise, Suggest, Rewrite, Compose and Ask Library.
    var featuresModel: ModelChoice {
        didSet { defaults.set(featuresModel.rawValue, forKey: Keys.features) }
    }

    /// The Assistant's creativity, 0–1. The writing tools set their own
    /// temperature per task — rewriting wants determinism whatever the person
    /// chose for conversation.
    var temperature: Double {
        didSet { defaults.set(temperature, forKey: Keys.temperature) }
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
        static let assistant = "aiAssistantModel"
        static let features = "aiFeaturesModel"
        static let temperature = "aiTemperature"
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
        let assistant = ModelChoice(stored: defaults.string(forKey: Keys.assistant), fallback: .onDevice)
        let features = ModelChoice(stored: defaults.string(forKey: Keys.features), fallback: .onDevice)
        assistantModel = offered.contains(assistant) ? assistant : .onDevice
        featuresModel = offered.contains(features) ? features : .onDevice
        temperature = min(max(defaults.object(forKey: Keys.temperature) as? Double ?? 0.7, 0), 1)
        reasoning = ReasoningChoice(rawValue: defaults.string(forKey: Keys.reasoning) ?? "") ?? .automatic
        hasRetiredProvider = defaults.bool(forKey: Keys.retiredProvider)
    }

    /// Dismiss the "your provider was retired" notice for good.
    func acknowledgeRetiredProvider() {
        hasRetiredProvider = false
        defaults.removeObject(forKey: Keys.retiredProvider)
    }
}
