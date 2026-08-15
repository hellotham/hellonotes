//
//  RemoteStore.swift
//  HelloNotes
//
//  Created by Chris Tham on 21/7/2026.
//
//  Phase 4 (direct provider API) foundation — the roadmap's optional, isolated
//  pilot for reaching a cloud account *without* the provider's desktop/mobile
//  client installed (unlike Phases 0–3, which ride the OS File Provider layer).
//
//  `RemoteStore` is the small abstraction a "direct" cloud collection would sit
//  on: list / read / write / delete a remote file tree, plus auth state. The
//  first conformance is `DropboxStore` (Dropbox API v2 over URLSession — no SDK
//  dependency). Wiring a RemoteStore into the filesystem-based `Collection`
//  model is a larger, separate refactor and is intentionally NOT done here; this
//  file + its provider clients are a self-contained, tested unit meant to be
//  adopted once the direct-API path is chosen.
//

import Foundation
import Security

/// A file tree hosted behind a provider's REST API.
protocol RemoteStore: AnyObject, Sendable {
    /// Human-readable provider name (for UI).
    var providerName: String { get }
    /// Whether a usable access token is stored.
    var isAuthenticated: Bool { get }

    /// Present the provider's OAuth flow and persist the resulting token.
    func authenticate() async throws
    /// Forget the stored token.
    func signOut()

    /// List the immediate children of a folder (`""` / `"/"` = root).
    func list(path: String) async throws -> [RemoteEntry]
    /// Download a file's bytes.
    func read(path: String) async throws -> Data
    /// Upload (create or overwrite) a file.
    func write(_ data: Data, to path: String) async throws
    /// Delete a file or folder.
    func delete(path: String) async throws
}

/// One entry in a remote folder listing.
struct RemoteEntry: Equatable, Sendable {
    var path: String        // provider-absolute path, e.g. "/Notes/Idea.md"
    var name: String
    var isDirectory: Bool
    var size: Int
    var modified: Date?
    var rev: String?        // provider revision id, for conflict detection
}

enum RemoteStoreError: LocalizedError, Equatable {
    case notConfigured(String)
    case notAuthenticated
    case http(Int, String)
    case decoding(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConfigured(let why): return why
        case .notAuthenticated:       return "Not signed in to this provider."
        case .http(let code, let body): return "Provider returned \(code): \(body)"
        case .decoding(let what):     return "Couldn't read the provider's response (\(what))."
        case .cancelled:              return "Sign-in was cancelled."
        }
    }
}

/// Serializes token refreshes so concurrent 401s share one exchange.
///
/// Box and OneDrive issue **single-use** refresh tokens: the refresh response
/// carries a replacement, and the old one is spent. Two uploads that both hit a
/// 401 would otherwise each POST the same refresh token — one wins, the other
/// gets `invalid_grant` and fails a save the user made. With this, the first
/// caller performs the exchange and everyone else awaits the same result.
actor RefreshCoordinator {
    private var inFlight: Task<String, Error>?

    /// Run `exchange` unless one is already running, in which case await that.
    func refresh(_ exchange: @escaping @Sendable () async throws -> String) async throws -> String {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await exchange() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}

/// Access tokens for direct-API providers, stored in the login Keychain
/// (`ThisDeviceOnly` — long-lived secrets stay off backups). Mirrors the shape
/// of `LLMKeychain`, keyed by a provider id string.
enum RemoteTokenStore {
    private static let service = "com.hellotham.HelloNotes.remote-tokens"

    static func token(for provider: String) -> String? {
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func setToken(_ value: String?, for provider: String) -> Bool {
        SecItemDelete(baseQuery(provider) as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        var query = baseQuery(provider)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func baseQuery(_ provider: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider,
        ]
    }
}
