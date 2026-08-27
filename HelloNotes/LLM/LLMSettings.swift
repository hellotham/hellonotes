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
///
/// The three `…Override` properties are all the same shape and all mean the
/// same thing: **`nil` = whatever was discovered or defaulted; a value = the
/// user has decided.** Nothing here guesses — a number the user did not type
/// comes from `ProviderCapabilities`, which says where it came from.
struct ProviderConfig: Codable, Equatable, Sendable {
    var kind: ProviderKind
    var enabled: Bool
    var baseURL: String        // overridable (local servers, self-hosted)
    var model: String          // selected/typed model ID

    /// What the provider said when last asked. Empty until a refresh succeeds,
    /// which is why `ModelCatalog.suggestedModels` still exists as the seed.
    var models: [ModelInfo] = []
    var modelsRefreshedAt: Date?

    /// Input allowance in **characters**. Overrides both discovery and the table.
    var inputBudgetOverride: Int?
    /// Sampling temperature for this provider. Overrides the global slider —
    /// necessary because the ranges genuinely differ (Anthropic tops out at 1.0,
    /// most of the rest at 2.0), so one global value cannot mean one thing.
    var temperatureOverride: Double?
    /// Cap on generated tokens. `maxTokens` has been on `LLMRequestOptions`
    /// since the beginning and no caller ever set it.
    var maxOutputTokensOverride: Int?

    init(kind: ProviderKind, enabled: Bool = false, baseURL: String? = nil, model: String? = nil) {
        self.kind = kind
        self.enabled = enabled
        self.baseURL = baseURL ?? kind.defaultBaseURL
        self.model = model ?? kind.suggestedModels.first ?? ""
    }

    /// Decoded field by field, every one optional.
    ///
    /// `LLMSettings.init` decodes the stored blob with `try?` and falls back to
    /// **defaults for every provider** — so a single missing key throwing here
    /// would not fail loudly, it would silently reset the user's entire provider
    /// configuration. Synthesised decoding does exactly that for a
    /// non-optional property added after the blob was written, which is why
    /// this is written out.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(ProviderKind.self, forKey: .kind)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? kind.defaultBaseURL
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? kind.suggestedModels.first ?? ""
        models = try c.decodeIfPresent([ModelInfo].self, forKey: .models) ?? []
        modelsRefreshedAt = try c.decodeIfPresent(Date.self, forKey: .modelsRefreshedAt)
        inputBudgetOverride = try c.decodeIfPresent(Int.self, forKey: .inputBudgetOverride)
        temperatureOverride = try c.decodeIfPresent(Double.self, forKey: .temperatureOverride)
        maxOutputTokensOverride = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokensOverride)
    }
}

extension ProviderConfig {
    /// What the provider said about the model that is actually selected.
    ///
    /// Matched leniently: several providers list a model under a versioned ID
    /// and accept an unversioned alias in a request (and vice versa), so an
    /// exact-only match would report "unknown" for a model the user picked from
    /// this very list.
    var selectedModelInfo: ModelInfo? {
        let wanted = model.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        if let exact = models.first(where: { $0.id == wanted }) { return exact }
        return models.first { $0.id.hasPrefix(wanted) || wanted.hasPrefix($0.id) }
    }

    /// The IDs to offer in the picker: what was discovered, or the seed list.
    var offeredModels: [ModelInfo] {
        models.isEmpty ? kind.suggestedModels.map { ModelInfo(id: $0) } : models
    }

    /// The highest temperature this provider/model accepts.
    var temperatureCeiling: Double {
        selectedModelInfo?.maxTemperature ?? kind.defaultMaxTemperature
    }

    /// `wanted`, held to what this provider will actually accept.
    ///
    /// Pure and on the value rather than inside `LLMSettings.requestOptions`,
    /// so the clamp can be tested without standing up a settings object over
    /// the user's real `UserDefaults`.
    func clampedTemperature(_ wanted: Double) -> Double {
        min(max(wanted, 0), temperatureCeiling)
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

    /// Whether the active provider can actually run: a local provider needs no
    /// key; a cloud provider needs an API key in the Keychain. Drives the
    /// Assistant's "set up AI" empty state.
    var isActiveProviderConfigured: Bool {
        activeProvider.requiresAPIKey ? LLMKeychain.hasKey(for: activeProvider) : true
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

    func setInputBudgetOverride(_ characters: Int?, for kind: ProviderKind) {
        var c = config(for: kind); c.inputBudgetOverride = characters; update(c)
    }

    func setTemperatureOverride(_ value: Double?, for kind: ProviderKind) {
        var c = config(for: kind); c.temperatureOverride = value; update(c)
    }

    func setMaxOutputTokensOverride(_ tokens: Int?, for kind: ProviderKind) {
        var c = config(for: kind); c.maxOutputTokensOverride = tokens; update(c)
    }

    /// The temperature to actually send: this provider's own, or the global.
    ///
    /// Clamped to the provider's ceiling rather than to a hard-coded 1.0.
    /// Anthropic rejects anything above 1.0 outright, while Gemini and the
    /// OpenAI-compatible family accept up to 2.0 — so a single global slider
    /// pinned to 0...1 was simultaneously the wrong range for one provider and
    /// half the available range for the rest.
    func resolvedTemperature(for kind: ProviderKind) -> Double {
        let c = config(for: kind)
        return c.clampedTemperature(c.temperatureOverride ?? temperature)
    }

    /// The generation cap to send — **only when the user asked for one**.
    ///
    /// Deliberately *not* `?? selectedModelInfo?.outputTokenLimit`. A discovered
    /// ceiling is information, not an instruction: pinning every request to a
    /// model's maximum output is a worse default than the provider's own, and on
    /// several providers it is an outright error. Groq counts prompt and
    /// completion against one `context_window`, so asking for the full
    /// `max_completion_tokens` leaves no room for the prompt; OpenAI's o-series
    /// rejects `max_tokens` altogether in favour of `max_completion_tokens`.
    ///
    /// `maxTokens` had been on `LLMRequestOptions` since the beginning with no
    /// caller ever setting it, and the first thing that set it sent the maximum
    /// on every request. The discovered number belongs in the field's
    /// placeholder, which is where it now stays.
    func resolvedMaxOutputTokens(for kind: ProviderKind) -> Int? {
        config(for: kind).maxOutputTokensOverride
    }

    /// The request knobs for `kind`, ready to hand to a provider.
    ///
    /// `override` is for a caller with a *feature* temperature of its own —
    /// rewriting wants determinism whatever the user chose for chat. It is
    /// clamped like any other: the ceiling is the provider's, and a caller
    /// asking for 1.4 against Anthropic must still be held to 1.0 or the
    /// request is rejected at the far end.
    func requestOptions(for kind: ProviderKind, temperature override: Double? = nil) -> LLMRequestOptions {
        let c = config(for: kind)
        return LLMRequestOptions(temperature: c.clampedTemperature(override ?? resolvedTemperature(for: kind)),
                                 maxTokens: resolvedMaxOutputTokens(for: kind))
    }

    // MARK: - Discovery

    /// Ask the provider what models it has, and remember the answer.
    ///
    /// Throws what the provider said — a bad key, an unreachable local server
    /// and "this provider publishes no list" are three different problems and
    /// the settings screen reports each one in its own words.
    func refreshModels(for kind: ProviderKind) async throws {
        let (provider, _) = try ProviderFactory.make(for: kind, settings: self)
        let discovered = try await provider.availableModels()
        var c = config(for: kind)
        c.models = discovered
        c.modelsRefreshedAt = Date()
        // Only *fill* an empty selection. A model the user typed that the
        // listing does not mention is very often a fine-tune or a deployment
        // alias that works perfectly well, so it is never overwritten here.
        if c.model.trimmingCharacters(in: .whitespaces).isEmpty, let first = discovered.first {
            c.model = first.id
        }
        update(c)
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
