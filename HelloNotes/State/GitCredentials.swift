//
//  GitCredentials.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Git commit identity + hosting-service accounts (GitHub, GitLab, …). Account
//  metadata (service/host/username) lives in UserDefaults; the access token is
//  stored in the login Keychain, keyed by host. Tokens are used to authenticate
//  HTTPS push/fetch by embedding them in the remote URL (SwiftGitX exposes no
//  credential callback).
//

import Foundation
import Security

// MARK: - Hosting services

enum GitHostService: String, CaseIterable, Codable, Identifiable, Sendable {
    case github, gitlab, gitea, custom
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .github: return "GitHub"
        case .gitlab: return "GitLab"
        case .gitea: return "Gitea / Forgejo"
        case .custom: return "Other (custom host)"
        }
    }

    var defaultHost: String {
        switch self {
        case .github: return "github.com"
        case .gitlab: return "gitlab.com"
        case .gitea, .custom: return ""
        }
    }

    var symbol: String {
        switch self {
        case .github: return "cat.circle"
        case .gitlab: return "hare.circle"
        case .gitea: return "cup.and.saucer"
        case .custom: return "server.rack"
        }
    }

    /// Where the user creates a Personal Access Token, and the scope they need.
    var tokenPageURL: URL? {
        switch self {
        case .github: return URL(string: "https://github.com/settings/tokens/new?scopes=repo&description=HelloNotes")
        case .gitlab: return URL(string: "https://gitlab.com/-/user_settings/personal_access_tokens")
        case .gitea, .custom: return nil
        }
    }

    var scopeHint: String {
        switch self {
        case .github: return "Create a token with the “repo” scope."
        case .gitlab: return "Create a token with the “write_repository” scope."
        case .gitea: return "Create a token with repository read/write access."
        case .custom: return "Use a token/app-password with repository read/write access."
        }
    }
}

// MARK: - Account model

struct GitAccount: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var service: GitHostService
    var host: String
    var username: String
}

// MARK: - Keychain token storage

enum GitKeychain {
    private static let service = "com.hellotham.HelloNotes.git-credentials"

    static func token(forHost host: String) -> String? {
        var query: [String: Any] = baseQuery(host: host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func setToken(_ token: String, forHost host: String) -> Bool {
        deleteToken(forHost: host)
        var query = baseQuery(host: host)
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func deleteToken(forHost host: String) {
        SecItemDelete(baseQuery(host: host) as CFDictionary)
    }

    private static func baseQuery(host: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host.lowercased(),
        ]
    }
}

// MARK: - Observable accounts + identity store

@MainActor
@Observable
final class GitAccountsStore {
    private(set) var accounts: [GitAccount] = []

    /// Commit identity, persisted in UserDefaults (also read by GitService).
    var identityName: String {
        didSet { UserDefaults.standard.set(identityName, forKey: Keys.name) }
    }
    var identityEmail: String {
        didSet { UserDefaults.standard.set(identityEmail, forKey: Keys.email) }
    }

    private enum Keys {
        static let accounts = "gitAccounts"
        static let name = "gitUserName"
        static let email = "gitUserEmail"
    }

    init() {
        identityName = UserDefaults.standard.string(forKey: Keys.name) ?? ""
        identityEmail = UserDefaults.standard.string(forKey: Keys.email) ?? ""
        if let data = UserDefaults.standard.data(forKey: Keys.accounts),
           let decoded = try? JSONDecoder().decode([GitAccount].self, from: data) {
            accounts = decoded
        }
    }

    /// Add or update an account and store its token in the Keychain.
    func save(service: GitHostService, host: String, username: String, token: String) {
        let host = host.trimmingCharacters(in: .whitespaces).lowercased()
        GitKeychain.setToken(token.trimmingCharacters(in: .whitespaces), forHost: host)
        if let idx = accounts.firstIndex(where: { $0.host == host }) {
            accounts[idx].service = service
            accounts[idx].username = username
        } else {
            accounts.append(GitAccount(service: service, host: host, username: username))
        }
        persist()
    }

    func remove(_ account: GitAccount) {
        GitKeychain.deleteToken(forHost: account.host)
        accounts.removeAll { $0.id == account.id }
        persist()
    }

    /// The account (if any) that authenticates the given host.
    func account(forHost host: String) -> GitAccount? {
        accounts.first { $0.host.caseInsensitiveCompare(host) == .orderedSame }
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(accounts), forKey: Keys.accounts)
    }
}

// MARK: - Authenticated remote URLs

enum GitRemoteURL {
    /// The bare `https://host/path` form with any embedded credentials stripped
    /// (for display and host matching).
    static func sanitized(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.user = nil
        comps.password = nil
        return comps.url ?? url
    }

    /// `https://username:token@host/path`, for authenticating an HTTPS remote.
    /// Returns `nil` for non-HTTPS URLs (SSH etc.).
    static func authenticated(_ url: URL, username: String, token: String) -> URL? {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              comps.scheme?.lowercased() == "https" else { return nil }
        comps.user = username.isEmpty ? "git" : username
        comps.password = token
        return comps.url
    }

    static func host(of url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.host
    }
}

extension String {
    /// `nil` when the string is empty (after no trimming); handy for optionals.
    var nonEmpty: String? { isEmpty ? nil : self }
}
