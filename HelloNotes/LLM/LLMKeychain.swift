//
//  LLMKeychain.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  BYO API keys live in the login Keychain, keyed by provider. Keys are never
//  hardcoded or shipped — required for App Store distribution.
//

import Foundation
import Security

enum LLMKeychain {
    private static let service = "com.hellotham.HelloNotes.llm-credentials"

    static func key(for provider: ProviderKind) -> String? {
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func setKey(_ value: String, for provider: ProviderKind) -> Bool {
        deleteKey(for: provider)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        var query = baseQuery(provider)
        query[kSecValueData as String] = Data(trimmed.utf8)
        // `ThisDeviceOnly`: BYO API keys are long-lived secrets — keep them out
        // of encrypted device backups / restore onto another device.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func deleteKey(for provider: ProviderKind) {
        SecItemDelete(baseQuery(provider) as CFDictionary)
    }

    static func hasKey(for provider: ProviderKind) -> Bool {
        key(for: provider)?.isEmpty == false
    }

    private static func baseQuery(_ provider: ProviderKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
    }
}
