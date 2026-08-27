//
//  CloudAccounts.swift
//  HelloNotes
//
//  Created by Chris Tham on 25/8/2026.
//
//  The cloud accounts a person has connected, and the folders they have taken
//  collections from.
//
//  This exists because both halves of "add a cloud collection" were written as
//  though a service could only ever be connected **once**. `CloudBrowser` has a
//  single case per provider, and `RemoteTokenStore` keys its Keychain items by
//  the provider's name — so signing in to a work OneDrive overwrote the token
//  for a personal one, silently, and the app had no way to name, list or
//  choose between them. Anyone with two accounts on the same service (which is
//  the ordinary case for OneDrive and Google Drive) could use exactly one.
//
//  An account therefore gets an identity of its own — a generated id, which is
//  what the Keychain is keyed by — and the provider becomes an *attribute* of
//  the account rather than the thing being stored.
//

import Foundation

/// One connected cloud account: which service, and how to tell it apart from
/// the other account on the same service.
struct CloudAccount: Identifiable, Codable, Equatable, Sendable {
    /// Stable, generated, and the Keychain key for this account's token.
    ///
    /// Not the provider name and not the user's email: the first collides for
    /// exactly the case this type exists to fix, and the second is a personal
    /// identifier we would then be storing in `UserDefaults` in the clear.
    let id: String
    /// Which service this is an account on.
    let provider: CloudBrowser
    /// What to call it in a list — the account's own label where the provider
    /// tells us one ("chris@work.com"), otherwise something the user can edit.
    var label: String
    var connectedAt: Date

    init(id: String = UUID().uuidString, provider: CloudBrowser,
         label: String, connectedAt: Date = Date()) {
        self.id = id
        self.provider = provider
        self.label = label
        self.connectedAt = connectedAt
    }

    /// What to show as the account's name.
    ///
    /// The label alone, not "OneDrive · Jane's OneDrive". Once a person has
    /// renamed an account the label is what they chose to call it, and
    /// prefixing the provider onto it reads as a stutter exactly in the case
    /// renaming exists for. Which service it is stays visible beside the name
    /// — the row shows it — so nothing is lost by not repeating it here.
    var displayName: String {
        label.isEmpty ? provider.displayName : label
    }
}

/// A cloud folder already used as a collection, so it can be offered again
/// without re-navigating to it.
///
/// This is the app's answer to a question the sandbox will not let it ask
/// directly. It cannot list `~/Library/CloudStorage` to discover that OneDrive
/// mounted as `OneDrive-Personal` and `OneDrive-Contoso` — it holds only
/// `files.user-selected.read-write`, so a location becomes knowable at the
/// moment the user points at it and not before. Remembering that moment is
/// what lets the *second* visit start where the first one ended.
struct CloudLocation: Identifiable, Codable, Equatable, Sendable {
    var id: String { bookmarkKey }
    /// Path of the picked folder, used as the identity.
    var bookmarkKey: String
    var name: String
    /// The provider's name where we could recognise it from the path.
    var providerName: String?
    var bookmark: Data
    var lastUsed: Date

    var url: URL? { Bookmark.resolve(bookmark)?.url }
}

@MainActor
@Observable
final class CloudAccountsStore {
    private(set) var accounts: [CloudAccount] = []
    private(set) var locations: [CloudLocation] = []

    private static let accountsKey = "cloudAccounts"
    private static let locationsKey = "cloudLocations"
    private let maxLocations = 12

    init() { load() }

    func accounts(for provider: CloudBrowser) -> [CloudAccount] {
        accounts.filter { $0.provider == provider }
    }

    /// Record an account that has **actually** signed in.
    ///
    /// Called after the sign-in succeeds, never before: an account written at
    /// the moment someone clicks a provider survives a cancelled or failed
    /// sign-in, and then sits in "Connected Accounts" with no token behind it.
    func adopt(_ account: CloudAccount) {
        guard !accounts.contains(where: { $0.id == account.id }) else { return }
        accounts.append(account)
        persist()
    }

    /// Forget an account **and its token**. Dropping the record without the
    /// token would leave a credential in the Keychain that nothing can name,
    /// reach or revoke.
    func disconnect(_ account: CloudAccount) {
        RemoteTokenStore.setToken(nil, for: account.id)
        RemoteTokenStore.setToken(nil, for: account.id + "-refresh")
        accounts.removeAll { $0.id == account.id }
        persist()
    }

    func rename(_ account: CloudAccount, to label: String) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index].label = label
        persist()
    }

    /// Remember a mounted cloud folder that was just opened.
    func remember(_ url: URL) {
        let key = url.standardizedFileURL.path
        guard let bookmark = Bookmark.data(for: url) else { return }
        let location = CloudLocation(
            bookmarkKey: key,
            name: url.lastPathComponent,
            providerName: CloudProvider.name(for: url),
            bookmark: bookmark,
            lastUsed: Date()
        )
        locations.removeAll { $0.bookmarkKey == key }
        locations.insert(location, at: 0)
        if locations.count > maxLocations { locations.removeLast(locations.count - maxLocations) }
        persist()
    }

    func forget(_ location: CloudLocation) {
        locations.removeAll { $0.bookmarkKey == location.bookmarkKey }
        persist()
    }

    // MARK: - Persistence

    private func load() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.accountsKey),
           let decoded = try? JSONDecoder().decode([CloudAccount].self, from: data) {
            accounts = decoded
        }
        if let data = defaults.data(forKey: Self.locationsKey),
           let decoded = try? JSONDecoder().decode([CloudLocation].self, from: data) {
            locations = decoded
        }
    }

    private func persist() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: Self.accountsKey)
        }
        if let data = try? JSONEncoder().encode(locations) {
            defaults.set(data, forKey: Self.locationsKey)
        }
    }
}
