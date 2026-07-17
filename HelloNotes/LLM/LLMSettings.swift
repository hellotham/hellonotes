//
//  LLMSettings.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  User configuration for the assistant: which providers are enabled, their base
//  URLs (for local servers), the selected model per provider, and the active
//  provider/model. API keys live in the Keychain (see LLMKeychain); everything
//  else is UserDefaults JSON.
//

import Foundation
import Observation

/// Per-provider settings the user can edit.
struct ProviderConfig: Codable, Equatable, Sendable {
    var kind: ProviderKind
    var enabled: Bool
    var baseURL: String        // overridable (local servers, self-hosted)
    var model: String          // selected/typed model ID

    init(kind: ProviderKind, enabled: Bool = false, baseURL: String? = nil, model: String? = nil) {
        self.kind = kind
        self.enabled = enabled
        self.baseURL = baseURL ?? kind.defaultBaseURL
        self.model = model ?? kind.suggestedModels.first ?? ""
    }
}

@MainActor
@Observable
final class LLMSettings {
    /// Config for every provider kind, keyed by kind.
    private(set) var providers: [ProviderKind: ProviderConfig] = [:]

    /// The active provider/model used for new chats.
    var activeProvider: ProviderKind {
        didSet { UserDefaults.standard.set(activeProvider.rawValue, forKey: Keys.active) }
    }

    /// The provider powering the "intelligence" features (Summarize, Suggest
    /// Tags/Links, Expand, Ask Library). Defaults to on-device Apple Intelligence.
    var intelligenceProvider: ProviderKind {
        didSet { UserDefaults.standard.set(intelligenceProvider.rawValue, forKey: Keys.intelligence) }
    }

    var temperature: Double {
        didSet { UserDefaults.standard.set(temperature, forKey: Keys.temperature) }
    }

    private enum Keys {
        static let providers = "llmProviders"
        static let active = "llmActiveProvider"
        static let intelligence = "llmIntelligenceProvider"
        static let temperature = "llmTemperature"
    }

    init() {
        activeProvider = UserDefaults.standard.string(forKey: Keys.active)
            .flatMap(ProviderKind.init(rawValue:)) ?? .openai
        intelligenceProvider = UserDefaults.standard.string(forKey: Keys.intelligence)
            .flatMap(ProviderKind.init(rawValue:)) ?? .apple
        temperature = UserDefaults.standard.object(forKey: Keys.temperature) as? Double ?? 0.7

        if let data = UserDefaults.standard.data(forKey: Keys.providers),
           let decoded = try? JSONDecoder().decode([ProviderConfig].self, from: data) {
            for config in decoded { providers[config.kind] = config }
        }
        // Ensure every kind has a config (fills in newly added kinds).
        for kind in ProviderKind.allCases where providers[kind] == nil {
            providers[kind] = ProviderConfig(kind: kind)
        }
    }

    func config(for kind: ProviderKind) -> ProviderConfig {
        providers[kind] ?? ProviderConfig(kind: kind)
    }

    func update(_ config: ProviderConfig) {
        providers[config.kind] = config
        persist()
    }

    func setEnabled(_ enabled: Bool, for kind: ProviderKind) {
        var c = config(for: kind); c.enabled = enabled; update(c)
    }

    func setModel(_ model: String, for kind: ProviderKind) {
        var c = config(for: kind); c.model = model; update(c)
    }

    func setBaseURL(_ url: String, for kind: ProviderKind) {
        var c = config(for: kind); c.baseURL = url; update(c)
    }

    /// Providers the user has switched on (and that are usable — a cloud provider
    /// needs a key; local ones just need to be enabled).
    var enabledProviders: [ProviderKind] {
        ProviderKind.allCases.filter { config(for: $0).enabled }
    }

    /// Whether a provider is ready to use (enabled + has a key when required).
    func isReady(_ kind: ProviderKind) -> Bool {
        let c = config(for: kind)
        guard c.enabled else { return false }
        if kind.requiresAPIKey { return LLMKeychain.hasKey(for: kind) }
        return true
    }

    private func persist() {
        let all = ProviderKind.allCases.map { config(for: $0) }
        // Only overwrite the stored blob if encoding succeeds — never write nil,
        // which would silently wipe every saved provider config.
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: Keys.providers)
    }
}
