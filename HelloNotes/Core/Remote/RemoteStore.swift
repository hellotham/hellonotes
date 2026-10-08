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
import Synchronization

/// A file tree hosted behind a provider's REST API.
///
/// **`nonisolated`, as are the stores and everything they hand back.** In
/// this target an unannotated type is main-actor, so every store was, and a
/// walk's listings — called from a walk away from the main actor — each
/// started on the main thread, with its token read from the Keychain and its
/// page parsed there, and no warning about any of it. A store's methods now
/// run where they are called, and do their heavy part — parsing a page of a
/// thousand entries — in `offMain`, so a listing a change makes from the
/// main actor parses its page off it too. Only sign-in, which presents a
/// sheet, is the main actor's.
nonisolated protocol RemoteStore: AnyObject, Sendable {
    /// Human-readable provider name (for UI).
    var providerName: String { get }
    /// Which connected account's credentials this store uses.
    ///
    /// Recorded in a collection's manifest, because a provider name alone no
    /// longer identifies a set of credentials — a person may hold a personal
    /// and a work account on one service, and restoring the collection has to
    /// pick the same one it was created with.
    var accountID: String { get }
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
    /// Move or rename a file or folder, contents and all, keeping its identity
    /// on the provider — its history, its sharing — which a re-upload under
    /// the new name and a delete of the old would not. The destination's
    /// folder exists and nothing is at the destination: the caller sees to
    /// both, and a provider that could replace what is there is asked not to.
    func move(from source: String, to destination: String) async throws
    /// Make an empty folder in a folder that exists. Box and Google Drive put
    /// a file only into a folder they already have, so a folder made here is
    /// made there before anything is uploaded into it.
    func createFolder(path: String) async throws

    /// Everything that changed under `path` since `cursor`.
    ///
    /// Returning `nil` means "this provider has no delta support wired up here"
    /// and the caller should re-list. That default keeps the refresh mechanism
    /// whole for every provider while the efficient path is added one at a time.
    ///
    /// Every provider *has* such a mechanism — Dropbox's `list_folder/continue`,
    /// Box's `/events` stream position, Graph's `/delta`, Drive's
    /// `changes.list` — which is what makes cursor-based refresh the right
    /// design rather than polling the tree.
    func changes(since cursor: String?, path: String) async throws -> RemoteChangeSet?

    /// Every entry under `path`, at every depth, in as few round trips as the
    /// provider allows — or `nil` when it has no such call wired up here.
    ///
    /// **This is the difference between one request and one per folder.** The
    /// walk is latency-bound: `RemoteTreeSource` overlaps six listings precisely
    /// because each is a round trip the app spends idle, and six-at-a-time is
    /// still N/6 latencies for N folders. Every provider can return a whole
    /// subtree in paginated batches instead — Dropbox `list_folder` with
    /// `recursive: true`, Graph `/delta`, Drive `files.list` with a folder
    /// query, Box `/folders/:id/items` recursed server-side — turning a few
    /// hundred round trips into a few.
    ///
    /// `nil` is not a failure: the caller falls back to walking directory by
    /// directory, so a provider gains this one at a time and nothing regresses
    /// while it does.
    func listRecursively(path: String) async throws -> [RemoteEntry]?

    /// A cursor marking "everything up to now", **without** fetching any data.
    ///
    /// Taken at the end of a full sync so the *first* refresh can already use
    /// the cheap path. Without it the first refresh re-lists the whole folder
    /// merely to obtain a position — a full traversal spent on bookkeeping.
    ///
    /// Every provider offers this directly: Dropbox `list_folder/get_latest_cursor`,
    /// Graph `/delta?token=latest`, Box `/events?stream_position=now`, Drive
    /// `changes/startPageToken`.
    func latestCursor(path: String) async throws -> String?
}

nonisolated extension RemoteStore {
    func listRecursively(path: String) async throws -> [RemoteEntry]? { nil }
    func changes(since cursor: String?, path: String) async throws -> RemoteChangeSet? { nil }
    func latestCursor(path: String) async throws -> String? { nil }
}

/// What changed on the provider since a cursor was issued.
nonisolated struct RemoteChangeSet: Sendable {
    /// Files and folders added or modified. For a delta feed this is the item's
    /// *latest state*, not a log of each edit.
    var changed: [RemoteEntry] = []
    /// Provider-absolute paths that no longer exist.
    var deleted: [String] = []
    /// The cursor to pass next time.
    var cursor: String?
    /// The provider says start over — Dropbox `409 reset`, Graph
    /// `410 resyncRequired`. A delta can never be treated as authoritative for
    /// deletion, so this is the only path that may prune.
    var requiresFullResync = false
}

/// One entry in a remote folder listing.
nonisolated struct RemoteEntry: Equatable, Sendable {
    var path: String        // provider-absolute path, e.g. "/Notes/Idea.md"
    var name: String
    var isDirectory: Bool
    var size: Int
    var modified: Date?
    var rev: String?        // provider revision id, for conflict detection
}

/// The dates in the providers' listings: ISO 8601, with `Z` or an offset, with
/// fractional seconds or without — Dropbox and Box without, Drive with three
/// digits, Graph with up to seven.
///
/// `Date.ISO8601FormatStyle` rather than `ISO8601DateFormatter`, which took
/// 126 ms of a 2,000-entry Dropbox page to parse its dates — on the main actor,
/// once per listing, and a cloud collection lists a folder before each save,
/// move and new folder (measured by the concurrency review of implemented.md
/// §51.21; the same 2,000 dates take 3 ms here). The formatter without
/// fractional seconds also returned nil for a date that had them.
nonisolated enum RemoteDate {
    static func parse(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: .iso8601) { return date }
        return try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}

nonisolated enum RemoteStoreError: LocalizedError, Equatable {
    case notConfigured(String)
    case notAuthenticated
    case http(Int, String)
    case decoding(String)
    case cancelled
    /// The Keychain could not be read — locked, a prompt refused. Not a
    /// rejected sign-in: signing in again signs out first, which deletes
    /// tokens that are fine.
    case keychainUnavailable

    var errorDescription: String? {
        switch self {
        case .notConfigured(let why): return why
        case .notAuthenticated:       return "Not signed in to this provider."
        case .http(let code, let body): return "Provider returned \(code): \(body)"
        case .decoding(let what):     return "Couldn't read the provider's response (\(what))."
        case .cancelled:              return "Sign-in was cancelled."
        case .keychainUnavailable:    return "Couldn't read this account's sign-in from the Keychain. Unlock it, then try again."
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

    /// One per token account, for the whole process. A store is made per
    /// collection and per browser, each with a coordinator of its own, so two
    /// collections on one Box or OneDrive account each spent the same
    /// single-use refresh token, and the loser's save failed with
    /// `invalid_grant` (implemented.md §51.36).
    nonisolated private static let byAccount = Mutex<[String: RefreshCoordinator]>([:])

    nonisolated static func `for`(_ account: String) -> RefreshCoordinator {
        byAccount.withLock { coordinators in
            if let coordinator = coordinators[account] { return coordinator }
            let coordinator = RefreshCoordinator()
            coordinators[account] = coordinator
            return coordinator
        }
    }

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
/// (`ThisDeviceOnly` — long-lived secrets stay off backups), keyed by a
/// provider id string, and kept in memory once read (`TokenCache`).
/// `nonisolated`: the stores ask from wherever they are called.
nonisolated enum RemoteTokenStore {
    static let shared = TokenCache(keychain: SystemTokenKeychain(service: "com.hellotham.HelloNotes.remote-tokens"))

    static func token(for provider: String) -> String? {
        shared.token(for: provider)
    }

    /// The account's token, or why there is none: signed out, or a Keychain
    /// that could not be read — which the browser must not answer with
    /// "sign in again" (`RemoteStoreError.keychainUnavailable`).
    static func requireToken(for provider: String) throws -> String {
        try shared.require(provider)
    }

    @discardableResult
    static func setToken(_ value: String?, for provider: String) -> Bool {
        shared.setToken(value, for: provider)
    }
}

/// Exchanging an account's refresh token for a new access token — one way,
/// for every provider: each store says how to ask and how to read the
/// answer (`exchange`), and this does the rest.
///
/// - **One at a time per account** (`RefreshCoordinator.for`), across every
///   store of it.
/// - **A refused refresh token is read again, once.** Box and OneDrive spend a
///   refresh token when they hand out the next, and another process — a
///   Debug and a Release build open at once — may have rotated it; this
///   process's copy is then spent, and only the Keychain has the new one.
/// - **What comes back is kept only if nothing wrote the refresh token
///   meanwhile.** A sign-out that landed while the exchange was out stays
///   signed out; the refresh wrote the tokens back.
nonisolated enum TokenRefresh {
    static func refresh(account: String, refreshAccount: String,
                        in cache: TokenCache = RemoteTokenStore.shared,
                        exchange: @escaping @Sendable (String) async throws -> (access: String, rotated: String?))
        async throws -> String {
        try await RefreshCoordinator.for(account).refresh {
            var refused: String?
            for _ in 0..<2 {
                let refreshToken = try cache.require(refreshAccount)
                guard refreshToken != refused else { break }
                let writes = cache.writes(of: refreshAccount)
                do {
                    let result = try await exchange(refreshToken)
                    guard cache.storeRefreshed(result.access, for: account, rotated: result.rotated,
                                               for: refreshAccount, unlessWrittenSince: writes) else {
                        throw RemoteStoreError.notAuthenticated
                    }
                    return result.access
                } catch RemoteStoreError.http(let code, _) where code == 400 || code == 401 {
                    refused = refreshToken
                    cache.forget(refreshAccount)
                    cache.forget(account)
                }
            }
            throw RemoteStoreError.notAuthenticated
        }
    }
}

/// What reading one account's item found.
nonisolated enum TokenRead: Sendable, Equatable {
    case found(String)
    /// No such item: the account is signed out.
    case absent
    /// The Keychain could not say — locked, a prompt refused, `securityd` out
    /// of reach. Not the same as signed out.
    case failed
}

/// Where the tokens are kept between launches.
nonisolated protocol TokenKeychain: Sendable {
    func read(_ account: String) -> TokenRead
    /// `value` stored for `account`, or the item deleted for nil; whether it took.
    func write(_ value: String?, for account: String) -> Bool
}

/// The login Keychain.
nonisolated struct SystemTokenKeychain: TokenKeychain {
    let service: String

    func read(_ account: String) -> TokenRead {
        var item = query(account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return .absent }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else { return .failed }
        return .found(token)
    }

    /// Replaced where it is, and added only when there is none. It was
    /// deleted and added again, and when the add failed there was no item at
    /// all.
    func write(_ value: String?, for account: String) -> Bool {
        guard let value else {
            let status = SecItemDelete(query(account) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let updated = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard updated == errSecItemNotFound else { return updated == errSecSuccess }
        var item = query(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Each account's tokens, read from the Keychain once and then kept.
///
/// Every request a store makes reads its access token, and a Keychain read is
/// an XPC round trip to `securityd` — six at a time during a Box walk, and on
/// the main actor while the stores were main-actor (implemented.md §51.34).
/// Each token is kept in memory from the first read and with every write, so
/// the Keychain is read again only for an account not yet asked about: only
/// the app compiles this, and every write goes through `setToken`, a
/// refresh's included.
///
/// - **A read that fails is not remembered.** A locked keychain, a refused
///   prompt or `securityd` out of reach is not a signed-out account; only a
///   missing item is (`TokenRead.absent`). Remembered as one, it refused every
///   request until the app quit — and "sign in again" signs out first, which
///   deletes the tokens that were there all along.
/// - **A write is kept in memory whatever becomes of it.** A refresh token Box
///   or OneDrive has just rotated is the only valid one there is, and a write
///   that failed and was forgotten signed the account out.
/// - **No Keychain call is made under the lock a read takes.** A main-actor
///   read of one account never waits on another's XPC call. A read made
///   outside it is kept only if nothing was written meanwhile, and each
///   account's writes take a lock of that account's, so its item and its
///   memory change in one order and no account's write waits on another's.
nonisolated final class TokenCache: Sendable {
    /// One account's token as this process last knew it.
    nonisolated private struct Known: Sendable {
        /// `.some(nil)`: known to be absent — read so, or deleted here.
        var value: String??
        /// Writes made here, so a read that began before one is not kept.
        var writes: Int
    }

    /// Held across one account's write, and only that account's.
    nonisolated private final class AccountLock: Sendable {
        let mutex = Mutex<Void>(())
    }

    private let keychain: any TokenKeychain
    private let known = Mutex<[String: Known]>([:])
    private let writeLocks = Mutex<[String: AccountLock]>([:])

    init(keychain: any TokenKeychain) {
        self.keychain = keychain
    }

    func token(for account: String) -> String? {
        if case .found(let token) = lookup(account) { return token }
        return nil
    }

    /// The account's token, or the error that says why there is none.
    func require(_ account: String) throws -> String {
        switch lookup(account) {
        case .found(let token): return token
        case .absent:           throw RemoteStoreError.notAuthenticated
        case .failed:           throw RemoteStoreError.keychainUnavailable
        }
    }

    /// What the account's item holds: from memory once known, from the
    /// Keychain otherwise — a missing item remembered as signed out, a
    /// failure not remembered at all.
    func lookup(_ account: String) -> TokenRead {
        let seen = known.withLock { $0[account] }
        if let value = seen?.value { return value.map(TokenRead.found) ?? .absent }
        let writes = seen?.writes ?? 0
        let read = keychain.read(account)
        return known.withLock { entries in
            // Written while the Keychain was being read: the write is newer.
            if let now = entries[account], now.writes != writes, let value = now.value {
                return value.map(TokenRead.found) ?? .absent
            }
            switch read {
            case .found(let token): entries[account] = Known(value: .some(token), writes: writes)
            case .absent:           entries[account] = Known(value: .some(nil), writes: writes)
            case .failed:           break
            }
            return read
        }
    }

    @discardableResult
    func setToken(_ value: String?, for account: String) -> Bool {
        writeLock(for: account).mutex.withLock { _ in writeHeld(value, for: account) }
    }

    /// How many times this process has written the account's token — so a
    /// refresh can tell whether a sign-out landed while it was out.
    func writes(of account: String) -> Int {
        known.withLock { $0[account]?.writes ?? 0 }
    }

    /// What memory says the account holds, forgotten: the next ask reads the
    /// Keychain, where another process may have put a newer token. Counted as
    /// a write, so a read already under way is not kept over it.
    func forget(_ account: String) {
        writeLock(for: account).mutex.withLock { _ in
            known.withLock { entries in
                entries[account] = Known(value: nil, writes: (entries[account]?.writes ?? 0) + 1)
            }
        }
    }

    /// The tokens a refresh got, kept only if nothing wrote the refresh token
    /// since the refresh read it: a sign-out that landed while the exchange
    /// was out stays signed out. It wrote the tokens back.
    func storeRefreshed(_ access: String, for account: String, rotated: String?, for refreshAccount: String,
                        unlessWrittenSince writes: Int) -> Bool {
        writeLock(for: refreshAccount).mutex.withLock { _ in
            guard known.withLock({ $0[refreshAccount]?.writes ?? 0 }) == writes else { return false }
            setToken(access, for: account)
            if let rotated { _ = writeHeld(rotated, for: refreshAccount) }
            return true
        }
    }

    /// The write, with the account's lock held: memory first, then the Keychain.
    private func writeHeld(_ value: String?, for account: String) -> Bool {
        let value = value.flatMap { $0.isEmpty ? nil : $0 }
        known.withLock { entries in
            entries[account] = Known(value: .some(value), writes: (entries[account]?.writes ?? 0) + 1)
        }
        return keychain.write(value, for: account)
    }

    private func writeLock(for account: String) -> AccountLock {
        writeLocks.withLock { locks in
            if let lock = locks[account] { return lock }
            let lock = AccountLock()
            locks[account] = lock
            return lock
        }
    }
}
