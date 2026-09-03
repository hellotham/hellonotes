//
//  SupportContractTests.swift
//  HelloNotesTests
//
//  The App Store rejection, as a test.
//
//  Build 14 was rejected under guideline 3.1.2(c): an app selling an
//  auto-renewable subscription must show, in the binary and on the screen where
//  the purchase happens, the subscription's title, its length, its price per
//  period, and working links to the Terms of Use (EULA) and privacy policy.
//  Every one of those is a specific element of `SupportSettingsView`, and every
//  one of them is the kind of thing a tidying refactor deletes without noticing.
//
//  This file cannot prove the screen *renders* — `ImageRenderer` draws a
//  collapsed `Form` identically to a healthy one, which is why the app has UI
//  tests at all. What it can prove is that the required text and the two URLs
//  are still there, that the product identifiers still match App Store Connect,
//  and that the champion count still merges the only way a monotonic count can.
//

import Foundation
import Testing
@testable import HelloNotes

struct SupportContractTests {

    // MARK: - Identifiers

    /// These are not arbitrary strings: they are the two products configured in
    /// App Store Connect. A typo here is not a compile error and not a crash —
    /// it is a Support screen with no products on it, which is what the
    /// reviewer sees.
    ///
    /// `champion` is deliberately `…​.champion.contribution` and not
    /// `…​.champion`. The latter exists in App Store Connect as a
    /// **non-consumable**, created before the requirement that a supporter can
    /// give more than once; a non-consumable refuses the second purchase, and
    /// App Store Connect will not change a product's type after creation.
    @Test func productIdentifiersMatchAppStoreConnect() {
        #expect(StoreService.ProductID.champion == "com.hellotham.HelloNotes.champion.contribution")
        #expect(StoreService.ProductID.commercial == "com.hellotham.HelloNotes.commercial")
        #expect(StoreService.ProductID.all.count == 2)
    }

    // MARK: - The 3.1.2(c) links

    /// The site is an Astro project page served from a sub-path, and it does
    /// **not** redirect a trailing slash: `…/privacy` is 200 and `…/privacy/`
    /// is 404. A dead policy link on the one screen App Review is required to
    /// open is the same rejection again.
    @Test func privacyLinkHasNoTrailingSlash() {
        let url = SupportSettingsView.privacyURL.absoluteString
        #expect(url == "https://hellotham.com/hellonotes/privacy")
        #expect(!url.hasSuffix("/"))
    }

    @Test func termsLinkIsTheStandardEULA() {
        #expect(SupportSettingsView.eulaURL.absoluteString
                == "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")
    }

    /// The disclosures themselves. Read from the source the way a reviewer
    /// reads the screen — see the file header on what this can and cannot show.
    @Test func thePurchaseScreenStillCarriesEveryRequiredDisclosure() throws {
        let source = try Self.source("UI/SupportSettingsView.swift")
        // Title and price/period are rendered from the `Product`, so the check
        // is that the row still shows both together rather than a bare price.
        #expect(source.contains("Text(\"\\(price) \\(cadence)\")"),
                "the price row must state the period beside the price")
        #expect(source.contains("Self.periodDescription(product)"),
                "subscription length must come from the product, not a literal")
        // Auto-renewal, and how to stop it.
        #expect(source.contains("renews automatically"))
        #expect(source.contains("Subscriptions"))
        #expect(source.contains("charged to your Apple Account"))
        // Both policy links, as links.
        #expect(source.contains("Terms of Use (EULA)"))
        #expect(source.contains("Privacy Policy"))
        // Guideline 3.1.1.
        #expect(source.contains("Restore Purchases"))
    }

    /// Reachable on **both** shells. The AI settings screen shipped in build 11
    /// having never drawn on iOS because it existed only in the Mac's tab bar;
    /// this screen carries review-required disclosures, so "reachable on macOS"
    /// is not enough.
    @Test func supportIsReachableFromBothSettingsShells() throws {
        let source = try Self.source("UI/SettingsView.swift")
        let macTab = source.contains("SupportSettingsView(store: store)")
            && source.contains("Label(\"Support\", systemImage: \"heart\")")
        let iosRow = source.contains("Label(\"Support HelloNotes\", systemImage: \"heart\")")
        #expect(macTab, "macOS Preferences must carry a Support tab")
        #expect(iosRow, "iOS Settings must carry a Support row")
    }

    // MARK: - The champion count

    /// A count that only ever rises cannot be merged by overwriting. A device
    /// that has been offline holds a stale number, not an older one — so an
    /// iCloud value of 2 must never replace a local 3.
    @Test func theChampionCountMergesAsAMaximum() {
        #expect(StoreService.mergedCount(local: 3, remote: 2) == 3)
        #expect(StoreService.mergedCount(local: 2, remote: 5) == 5)
        #expect(StoreService.mergedCount(local: 0, remote: 0) == 0)
    }

    /// A fresh install reads whatever this device already knew.
    @Test @MainActor func theCountIsRestoredFromLocalStorage() throws {
        let suite = "SupportContractTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaults.set(4, forKey: "championContributions")

        // `cloud: nil` keeps the test off the real iCloud key-value store —
        // which is shared with the developer's own account.
        let store = StoreService(defaults: defaults, cloud: nil)
        #expect(store.championCount == 4)
        #expect(store.hasCommercialLicence == false, "nothing is entitled before a purchase")
    }

    /// Nothing is gated. If a feature ever starts consulting a purchase, this
    /// is where it gets caught.
    /// **Exactly one thing is gated, and it is not a feature of the app.**
    ///
    /// Backing HelloNotes buys a support request — a channel to the person who
    /// makes it. Everything the app *does* stays included for everyone, and
    /// this fails the build the moment anything else starts asking whether a
    /// purchase was made.
    ///
    /// The allow-list is three files and is meant to stay three. Adding a
    /// fourth is the decision this test exists to make deliberate.
    @Test func onlyTheSupportRequestConsultsAPurchase() throws {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "HelloNotes")
        let allowed: Set<String> = [
            "StoreService.swift",           // owns the entitlement
            "SupportSettingsView.swift",    // the purchase screen itself
            "SupportRequestSection.swift",  // the one gated affordance
        ]
        let readers = try FileManager.default
            .enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .filter { !allowed.contains($0.lastPathComponent) }
            .filter { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
                return text.contains("hasCommercialLicence")
                    || text.contains("championCount")
                    || text.contains("canRequestSupport")
            } ?? []
        #expect(readers.isEmpty,
                "a purchase must not decide what the app does: \(readers.map(\.lastPathComponent))")
    }

    /// …and the gate is actually there.
    ///
    /// The negative half of the test above: an allow-list that permits a file
    /// to consult a purchase proves nothing about whether it does. If the gate
    /// is ever removed, the allow-list would go on passing quietly.
    @Test func theSupportRequestIsGatedAndSaysSo() throws {
        let section = try Self.source("UI/SupportRequestSection.swift")
        #expect(section.contains("store.canRequestSupport"),
                "the support request must consult the entitlement")
        // The requirement is that it *explains* the condition rather than
        // simply refusing — a disabled control with no reason is the shape of a
        // bug, not of a paid channel.
        #expect(section.contains("Champion") && section.contains("commercial licence"),
                "an unentitled user has to be told which of the two unlocks this")
        // Caught by looking at the screen: it said the two options were
        // "below" and they are above. A sentence that names a direction is a
        // sentence that goes stale when the layout moves.
        for direction in ["are below", "are above", "shown below", "shown above"] {
            #expect(!section.contains(direction),
                    "the copy points somewhere — it will be wrong when the screen is reordered")
        }

        let store = try Self.source("State/StoreService.swift")
        #expect(store.contains("championCount > 0 || hasCommercialLicence"),
                "either kind of backing earns it")
    }

    /// The purchase screen must not claim nothing is gated, because something
    /// is now.
    ///
    /// It said "Nothing on this screen unlocks a feature" for as long as that
    /// was true, and a stale reassurance is worse than none: it is the same
    /// class of error as the listing promising "priority support requests" that
    /// no queue implements.
    @Test func thePurchaseScreenDoesNotOverstateWhatIsIncluded() throws {
        let screen = try Self.source("UI/SupportSettingsView.swift")
        #expect(!screen.contains("Nothing on this screen unlocks a feature"),
                "a support request does unlock — the copy has to say so")
        #expect(screen.contains("every feature is included for everyone"),
                "and the claim that survives is about features, which is still true")
    }

    /// Nothing about anyone's notes goes into a support request.
    ///
    /// The app's privacy answer is "Data Not Collected", and a diagnostic block
    /// is exactly where that quietly stops being true.
    @Test func aSupportRequestCarriesVersionsAndNothingElse() {
        let body = SupportRequestSection.body(summary: "Sync stopped",
                                              entitlement: "Champion ×2")
        #expect(body.contains("Sync stopped"))
        #expect(body.contains("Champion ×2"))
        for leak in ["/Users/", "/Volumes/", ".md", "Collection", "vault"] {
            #expect(!body.contains(leak), "a support request must not carry \(leak)")
        }
    }

    /// The address is the published one, and the message survives punctuation.
    ///
    /// Built with `URLComponents` rather than string-joining: a summary
    /// containing `&` would otherwise truncate the body, and the request would
    /// arrive empty with the sender blamed for it.
    @Test func theComposedMailIsAddressedAndIntact() throws {
        let url = try #require(SupportRequestSection.composeURL(
            summary: "Tags & links stop resolving", entitlement: nil))
        #expect(url.scheme == "mailto")
        #expect(url.absoluteString.contains("info@hellotham.com"))
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let body = try #require(query.first { $0.name == "body" }?.value)
        #expect(body.contains("Tags & links stop resolving"),
                "the ampersand truncated the body")
    }

    // MARK: -

    private static func source(_ name: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()   // …/HelloNotesTests
            .deletingLastPathComponent()   // …/<repo root>
            .appending(path: "HelloNotes")
            .appending(path: name)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
