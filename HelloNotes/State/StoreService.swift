//
//  StoreService.swift
//  HelloNotes
//
//  Voluntary support: two products, nothing gated.
//
//  HelloNotes is free and complete. Neither product unlocks a feature, hides
//  one, or changes what the app does — which is a design decision, not an
//  oversight, and the reason this file has no `isPro` anywhere in it. Anything
//  reading a purchase to decide whether a feature runs would be a bug.
//
//    • **Champion** — a one-off contribution someone can make more than once.
//      A *consumable*, because that is the only StoreKit product type that can
//      be bought repeatedly; a non-consumable answers the second purchase with
//      "You've already bought this."
//    • **Commercial** — an annual licence for using HelloNotes at work. An
//      auto-renewable subscription, which is what makes it a licence rather
//      than a donation, and what puts guideline 3.1.2(c)'s disclosures on the
//      purchase screen (`SupportSettingsView` renders them).
//
//  ## Counting a consumable is the app's job, not StoreKit's
//
//  `Transaction.currentEntitlements` never contains consumables — an
//  entitlement is a thing you still hold, and a contribution is a thing you
//  did. So "5× Champion" has to be remembered here, and the naive spelling
//  (an `Int` in UserDefaults) loses the count on reinstall and disagrees
//  between a Mac and an iPad.
//
//  The count is therefore the **maximum** of three independent sources:
//
//    1. `UserDefaults` — this device, authoritative and instant.
//    2. `NSUbiquitousKeyValueStore` — the user's other devices.
//    3. `Transaction.all` filtered to the Champion product — the App Store's
//       own history, which survives a wipe.
//
//  Maximum, never last-write-wins. A count that only ever goes up cannot be
//  merged by overwriting: a device that has been offline holds a *stale*
//  number, not an older one, and `CloudPrefs`' generic mirror would happily
//  push 2 over 3. That is why this key is deliberately **not** in
//  `CloudPrefs.keys` and is synced here instead.
//

import Foundation
import StoreKit
import Observation

@Observable
final class StoreService {

    // MARK: - Products

    enum ProductID {
        /// Consumable. Repeatable — see the note above on why this is not the
        /// older `…​.champion`, which was created as a non-consumable and whose
        /// type App Store Connect will not change.
        static let champion = "com.hellotham.HelloNotes.champion.contribution"
        /// Auto-renewable, 1 year, in the "Support HelloNotes" group.
        static let commercial = "com.hellotham.HelloNotes.commercial"

        static let all: Set<String> = [champion, commercial]
    }

    /// What the store is currently doing, so the UI never has to guess.
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        /// The App Store could not be reached, or returned no products.
        case failed(String)
    }

    private(set) var loadState: LoadState = .idle
    private(set) var champion: Product?
    private(set) var commercial: Product?

    /// Non-nil while a purchase is in flight, holding that product's id, so a
    /// button can show progress without a second piece of state falling out of
    /// step with this one.
    private(set) var purchasing: String?

    /// How many times this person has backed the app. See the file comment:
    /// merged as a maximum across device, iCloud and App Store history.
    private(set) var championCount: Int = 0

    /// Whether a commercial licence is currently active. Read for
    /// *acknowledgement only* — no feature consults it.
    private(set) var hasCommercialLicence = false
    /// When the active licence renews or lapses, if the App Store said.
    private(set) var commercialRenewal: Date?

    /// Whether an in-app support request can be sent.
    ///
    /// **The one thing a purchase decides.** Everything the app *does* is
    /// included for everyone — the editor, the index, the Intelligence
    /// features, all of it — and `SupportContractTests` fails the build if any
    /// of that starts consulting a purchase. What backing buys is a channel to
    /// the person who makes it, which is a promise about someone's time rather
    /// than a capability withheld from the binary.
    ///
    /// Stated as one property so there is one answer, and so the test that
    /// polices the boundary has a single name to allow.
    var canRequestSupport: Bool { championCount > 0 || hasCommercialLicence }

    /// How the entitlement was earned, for the request itself to quote. `nil`
    /// when there is none.
    var supportEntitlement: String? {
        if hasCommercialLicence { return "Commercial licence" }
        if championCount > 0 { return "Champion ×\(championCount)" }
        return nil
    }

    /// Set after a purchase completes, for a transient thank-you.
    var lastThanks: String?
    /// Set when a purchase or restore fails in a way worth showing.
    var lastError: String?

    // MARK: - Storage

    private let defaults: UserDefaults
    private let cloud: NSUbiquitousKeyValueStore?
    private static let countKey = "championContributions"

    private var updatesTask: Task<Void, Never>?

    /// - Parameters:
    ///   - defaults: injectable so tests do not touch the user's real count.
    ///   - cloud: `nil` disables the iCloud mirror (tests, and any build
    ///     without the KV-store entitlement).
    init(defaults: UserDefaults = .standard,
         cloud: NSUbiquitousKeyValueStore? = .default) {
        self.defaults = defaults
        self.cloud = cloud
        championCount = mergedCount(local: defaults.integer(forKey: Self.countKey),
                                    remote: cloudCount())
        observeCloud()
        // Start listening *before* the first product load: a transaction
        // approved while the app was closed (Ask to Buy, an interrupted
        // purchase, a renewal) is delivered on `Transaction.updates` at launch,
        // and a listener installed later misses it.
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.apply(update)
            }
        }
    }

    deinit { updatesTask?.cancel() }

    // MARK: - Loading

    /// Fetch product metadata again, from the beginning.
    ///
    /// Distinct from `load()`, which is a no-op once it has run: a product
    /// created minutes ago is genuinely absent from the App Store's response
    /// and genuinely present a few minutes later, so "try again" has to be able
    /// to ask a second time.
    func reload() async {
        guard loadState != .loading else { return }
        loadState = .idle
        await load()
    }

    /// Fetch product metadata. Safe to call repeatedly; the App Store caches.
    func load() async {
        guard loadState != .loading else { return }
        loadState = .loading
        do {
            let products = try await Product.products(for: ProductID.all)
            for product in products {
                switch product.id {
                case ProductID.champion:   champion = product
                case ProductID.commercial: commercial = product
                default: break
                }
            }
            // An empty result is a *failure* to show, not an empty shelf: it is
            // what a missing paid-applications agreement, an unapproved
            // product, or a sandbox account mismatch all look like. Reporting
            // it as "loaded" would draw a Support screen with no prices and no
            // explanation.
            loadState = products.isEmpty
                ? .failed("The App Store returned no products. Check back shortly.")
                : .loaded
        } catch {
            loadState = .failed(error.localizedDescription)
        }
        await refreshEntitlements()
    }

    /// Re-read what the customer currently holds, and reconcile the Champion
    /// count against the App Store's own history.
    func refreshEntitlements() async {
        var licensed = false
        var renewal: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.productID == ProductID.commercial {
                licensed = true
                renewal = transaction.expirationDate
            }
        }
        hasCommercialLicence = licensed
        commercialRenewal = renewal

        // `Transaction.all` is the App Store's record rather than this device's,
        // so on a fresh install it can know about contributions UserDefaults
        // has never seen. It may also legitimately know about none — finished
        // consumables are not guaranteed to persist here — which is exactly why
        // this is merged as a maximum and never assigned.
        var seen = 0
        for await result in Transaction.all {
            guard case .verified(let transaction) = result,
                  transaction.productID == ProductID.champion else { continue }
            seen += 1
        }
        setCount(max(championCount, seen))
    }

    // MARK: - Buying

    /// Buy `product`. Returns silently on cancellation — a person changing
    /// their mind is not an error and must not raise an alert.
    func purchase(_ product: Product) async {
        guard purchasing == nil else { return }
        purchasing = product.id
        defer { purchasing = nil }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                await apply(verification)
            case .userCancelled:
                break
            case .pending:
                // Ask to Buy, or an SCA challenge. It will arrive later on
                // `Transaction.updates`, which is already being listened to.
                lastThanks = "Your purchase is pending approval."
            @unknown default:
                break
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Ask the App Store to re-deliver this customer's purchases.
    ///
    /// Required by guideline 3.1.1 for the subscription. It cannot bring back a
    /// consumable — nothing can — so the Champion count is recovered by the
    /// three-way merge instead, and the UI says so rather than implying a
    /// restore will do it.
    func restore() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            lastThanks = "Purchases restored."
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Transactions

    private func apply(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else {
            // An unverified transaction is not trusted and not finished: left
            // alone, the App Store will offer it again.
            lastError = "That purchase could not be verified."
            return
        }
        if transaction.revocationDate == nil {
            switch transaction.productID {
            case ProductID.champion:
                setCount(championCount + 1)
                lastThanks = championCount > 1
                    ? "Thank you — that makes you a \(championCount)× champion."
                    : "Thank you for backing HelloNotes."
            case ProductID.commercial:
                hasCommercialLicence = true
                commercialRenewal = transaction.expirationDate
                lastThanks = "Your commercial licence is active."
            default:
                break
            }
        }
        // Always finish. An unfinished consumable is re-delivered on every
        // launch, which would count one contribution over and over.
        await transaction.finish()
        await refreshEntitlements()
    }

    // MARK: - The count

    private func setCount(_ value: Int) {
        guard value != championCount else { return }
        championCount = value
        defaults.set(value, forKey: Self.countKey)
        if let cloud, cloud.longLong(forKey: Self.countKey) < Int64(value) {
            cloud.set(Int64(value), forKey: Self.countKey)
            cloud.synchronize()
        }
    }

    private func cloudCount() -> Int { Int(cloud?.longLong(forKey: Self.countKey) ?? 0) }

    /// Merge two observations of a count that only ever rises.
    ///
    /// Internal and static so the rule can be tested directly: a device that
    /// has been offline holds a *stale* number, not an older one, so the merge
    /// is a maximum and never an assignment. Getting this wrong is silent —
    /// the count simply goes down one day.
    static func mergedCount(local: Int, remote: Int) -> Int { max(local, remote) }

    private func mergedCount(local: Int, remote: Int) -> Int {
        Self.mergedCount(local: local, remote: remote)
    }

    private func observeCloud() {
        guard let cloud else { return }
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud, queue: nil
        ) { [weak self] _ in
            // Documented to arrive on a system-chosen queue, so hop first.
            Task { @MainActor [weak self] in
                guard let self else { return }
                setCount(mergedCount(local: championCount, remote: cloudCount()))
            }
        }
    }
}
