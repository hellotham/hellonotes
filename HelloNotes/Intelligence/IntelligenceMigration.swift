//
//  IntelligenceMigration.swift
//  HelloNotes
//
//  Created by Chris Tham on 15/9/2026.
//
//  Carrying a 1.3.2 installation into the Foundation Models world, once.
//
//  1.3.2 stored its AI configuration as a JSON array of sixteen provider configs
//  (`llmProviders`), two provider picks (`llmActiveProvider` for chat,
//  `llmIntelligenceProvider` for the writing tools), a temperature, and one API
//  key per provider in the Keychain. All sixteen providers but two are gone.
//
//  * Apple on-device maps to `.onDevice`, and MLX to `.mlx` with its model id.
//  * Every other provider maps to `.onDevice` — the one model every eligible
//    device has, and the only default that sends nothing anywhere the person
//    did not already choose. *That* one was retired is remembered, so the
//    Assistant can say once what happened rather than silently answering from a
//    different model — but not *which*. This build names no AI service anywhere:
//    a string literal is compiled into the binary, and 1.3.3 re-enters the China
//    storefront, where naming an unlicensed generative-AI service is exactly
//    what a reviewer looks for. The person set the provider up; they know.
//  * The old keys are removed, and **the stored API keys are deleted**. They are
//    live credentials for services this build can no longer call; leaving them
//    in the Keychain would keep secrets on the device for no purpose. The
//    person still has them wherever they created them.
//
//  Idempotent: guarded by a flag, and every step tolerates a partial earlier
//  run. It decodes nothing it does not need, field by field — a throwing decode
//  of an old blob here would not be a crash, it would be a lost MLX model id.
//

import Foundation
import Security

nonisolated enum IntelligenceMigration {

    static let doneKey = "aiMigration133"

    nonisolated enum LegacyKeys {
        static let providers = "llmProviders"
        static let active = "llmActiveProvider"
        static let intelligence = "llmIntelligenceProvider"
        static let temperature = "llmTemperature"
        static let keychainService = "com.hellotham.HelloNotes.llm-credentials"
    }

    /// What a stored 1.3.2 provider becomes, and whether it was retired.
    static func map(provider raw: String?) -> (choice: ModelChoice, retired: Bool)? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw {
        case "apple": return (.onDevice, false)
        case "mlx": return (.mlx, false)
        default: return (.onDevice, true)
        }
    }

    /// The MLX model id from the old provider blob, if one was set.
    ///
    /// Only `kind` and `model` are read. The blob also held discovered model
    /// lists, budgets and temperatures for providers that no longer exist.
    static func legacyMLXModel(from data: Data?) -> String? {
        guard let data,
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        let model = array.first { ($0["kind"] as? String) == "mlx" }?["model"] as? String
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines),
              model.contains("/") else { return nil }
        return model
    }

    static func migrateIfNeeded(defaults: UserDefaults,
                                deleteCredentials: () -> Void = deleteLegacyCredentials) {
        guard !defaults.bool(forKey: doneKey) else { return }

        let chat = map(provider: defaults.string(forKey: LegacyKeys.active))
        let features = map(provider: defaults.string(forKey: LegacyKeys.intelligence))

        if defaults.string(forKey: IntelligenceSettings.Keys.assistant) == nil, let chat {
            defaults.set(chat.choice.rawValue, forKey: IntelligenceSettings.Keys.assistant)
        }
        if defaults.string(forKey: IntelligenceSettings.Keys.features) == nil, let features {
            defaults.set(features.choice.rawValue, forKey: IntelligenceSettings.Keys.features)
        }
        if chat?.retired == true || features?.retired == true {
            defaults.set(true, forKey: IntelligenceSettings.Keys.retiredProvider)
        }
        if defaults.string(forKey: MLXModelStore.Keys.model) == nil,
           let model = legacyMLXModel(from: defaults.data(forKey: LegacyKeys.providers)) {
            defaults.set(model, forKey: MLXModelStore.Keys.model)
        }
        if defaults.object(forKey: IntelligenceSettings.Keys.temperature) == nil,
           let temperature = defaults.object(forKey: LegacyKeys.temperature) as? Double {
            defaults.set(min(max(temperature, 0), 1), forKey: IntelligenceSettings.Keys.temperature)
        }

        for key in [LegacyKeys.providers, LegacyKeys.active, LegacyKeys.intelligence, LegacyKeys.temperature] {
            defaults.removeObject(forKey: key)
        }
        deleteCredentials()
        defaults.set(true, forKey: doneKey)
    }

    /// Remove every API key 1.3.2 stored.
    static func deleteLegacyCredentials() {
        deleteCredentials(service: LegacyKeys.keychainService)
    }

    /// Remove every generic password stored under `service`.
    ///
    /// The accounts are listed from the Keychain rather than from a table of
    /// provider ids, so nothing here needs to know what the providers were
    /// called. Deleted account by account and then by service: on the Mac's
    /// file-based keychain `SecItemDelete` has historically removed only the
    /// first match for a broad query, so the per-account pass is what guarantees
    /// none is left behind, and the bounded service-wide loop catches anything
    /// the listing could not see. The queries have the shape 1.3.2's own
    /// `deleteKey` used, so they reach whichever keychain it wrote to.
    static func deleteCredentials(service: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        var listing = base
        listing[kSecReturnAttributes as String] = true
        listing[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        if SecItemCopyMatching(listing as CFDictionary, &result) == errSecSuccess,
           let items = result as? [[String: Any]] {
            for account in Set(items.compactMap { $0[kSecAttrAccount as String] as? String }) {
                var query = base
                query[kSecAttrAccount as String] = account
                SecItemDelete(query as CFDictionary)
            }
        }
        var attempts = 0
        while attempts < 32, SecItemDelete(base as CFDictionary) == errSecSuccess { attempts += 1 }
    }
}
