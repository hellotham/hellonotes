//
//  SupportSettingsView.swift
//  HelloNotes
//
//  The purchase screen — and the only place in the app that mentions money.
//
//  ## Why this screen is shaped the way it is
//
//  App Review rejected build 14 under guideline 3.1.2(c): an app that sells an
//  auto-renewable subscription must show, **in the binary and on the screen
//  where the purchase happens**, the subscription's title, its length, its
//  price per period, and working links to the Terms of Use (EULA) and the
//  privacy policy. Those five things are not decoration here; each one is a
//  labelled element below, and `SupportSettingsContractTests` asserts every one
//  of them still renders. A disclosure that quietly disappears in a refactor is
//  the same rejection again, six weeks later.
//
//  The auto-renewal sentence is in the same category: someone buying a
//  recurring charge is told, before they buy, that it recurs and where to stop
//  it.
//
//  ## Nothing here is a paywall
//
//  Both products are voluntary and neither gates anything, so this view never
//  asks the store what the user owns in order to decide what to draw. The
//  Champion count and the licence badge are acknowledgements — the app behaves
//  identically at zero.
//

import SwiftUI
import StoreKit

struct SupportSettingsView: View {
    var store: StoreService

    /// Apple's Licensed Application End User License Agreement — the licence
    /// that actually governs an App Store app absent a custom one, and the
    /// link 3.1.2(c) calls "Terms of Use (EULA)".
    static let eulaURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    /// **No trailing slash.** The site is an Astro project page and
    /// `…/privacy/` 404s while `…/privacy` is 200 — a dead policy link on the
    /// one screen a reviewer is required to check.
    static let privacyURL = URL(string: "https://hellotham.com/hellonotes/privacy")!

    @Environment(\.openURL) private var openURL

    var body: some View {
        ChromeForm {
            ChromeSection {
                // **This used to say "nothing on this screen unlocks a
                // feature", and that is no longer true.** One thing does: a
                // support request. Everything the app *does* is still included
                // for everyone, which is the claim worth keeping precise —
                // overstating it is how a listing promises "priority support"
                // that no queue anywhere implements.
                Text("HelloNotes is free, and every feature is included for everyone. Backing the app adds one thing: you can send a support request from inside it.")
                    .font(Chrome.Style.callout)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
            }

            championSection
            commercialSection
            SupportRequestSection(store: store)

            ChromeSection {
                policyLink("Terms of Use (EULA)", systemImage: "doc.text", destination: Self.eulaURL)
                policyLink("Privacy Policy", systemImage: "hand.raised", destination: Self.privacyURL)
            } header: {
                Text("Terms")
            } footer: {
                Text("HelloNotes collects nothing. Purchases are handled entirely by the App Store — the app never sees a payment detail.")
            }

            ChromeSection {
                Button {
                    Task { await store.restore() }
                } label: {
                    Label("Restore Purchases", systemImage: "arrow.clockwise")
                }
            } footer: {
                Text("Restores a commercial licence bought with this Apple Account. Contributions are one-off payments and are not restorable — the champion count follows your iCloud account instead.")
            }

            if case .failed(let message) = store.loadState {
                ChromeSection {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Chrome.Colour.secondaryLabel)
                }
            }
        }
        .task { await store.load() }
        .alert("Thank you", isPresented: thanksBinding) {
            Button("OK") { store.lastThanks = nil }
        } message: {
            Text(store.lastThanks ?? "")
        }
        .alert("Purchase Failed", isPresented: errorBinding) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    // MARK: - Champion

    @ViewBuilder private var championSection: some View {
        ChromeSection {
            if let product = store.champion {
                productRow(
                    title: product.displayName,
                    detail: product.description,
                    price: product.displayPrice,
                    cadence: "one-off",
                    action: "Contribute",
                    product: product)
            } else {
                unavailableRow(named: "Champion")
            }

            if store.championCount > 0 {
                LabeledContent("Contributions") {
                    Text(store.championCount == 1
                         ? "Champion"
                         : "\(store.championCount)× Champion")
                        .fontWeight(.semibold)
                }
            }
        } header: {
            Text("Champion")
        } footer: {
            Text("A one-off contribution from people who want HelloNotes to keep being made. You can give more than once, and the app remembers how many times.")
        }
    }

    // MARK: - Commercial

    @ViewBuilder private var commercialSection: some View {
        ChromeSection {
            if let product = store.commercial {
                productRow(
                    title: product.displayName,
                    detail: product.description,
                    price: product.displayPrice,
                    // 3.1.2(c): the *length* of the subscription, stated where
                    // it is bought. Taken from the product rather than written
                    // here, so it cannot drift from App Store Connect.
                    cadence: Self.periodDescription(product) ?? "per year",
                    action: store.hasCommercialLicence ? "Renew" : "Subscribe",
                    product: product)

                if store.hasCommercialLicence {
                    LabeledContent("Licence") {
                        Text(renewalText).fontWeight(.semibold)
                    }
                }
            } else {
                unavailableRow(named: "Commercial")
            }
        } header: {
            Text("Commercial")
        } footer: {
            // The auto-renewal disclosure. Required in the binary for an
            // auto-renewable subscription, and separate from the price line
            // above it.
            Text("An annual licence for using HelloNotes at work — the same app, with the same features. Payment is charged to your Apple Account on confirmation. The subscription renews automatically each year unless it is turned off at least 24 hours before the period ends. Manage or cancel it in Settings ▸ your name ▸ Subscriptions.")
        }
    }

    private var renewalText: String {
        guard let date = store.commercialRenewal else { return "Active" }
        return "Renews \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    /// "per year" / "per month" from the product itself.
    static func periodDescription(_ product: Product) -> String? {
        guard let period = product.subscription?.subscriptionPeriod else { return nil }
        let unit: String
        switch period.unit {
        case .day:   unit = "day"
        case .week:  unit = "week"
        case .month: unit = "month"
        case .year:  unit = "year"
        @unknown default: return nil
        }
        return period.value == 1 ? "per \(unit)" : "per \(period.value) \(unit)s"
    }

    // MARK: - Rows

    @ViewBuilder
    private func productRow(title: String, detail: String, price: String,
                            cadence: String, action: String,
                            product: Product) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Chrome.Style.headline)
                Spacer(minLength: 12)
                // Price and period together, so neither can be read without
                // the other.
                Text("\(price) \(cadence)")
                    .font(Chrome.Style.callout)
                    .monospacedDigit()
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
            }
            if !detail.isEmpty {
                Text(detail).font(Chrome.Style.callout).foregroundStyle(Chrome.Colour.secondaryLabel)
            }
            Button {
                Task { await store.purchase(product) }
            } label: {
                if store.purchasing == product.id {
                    ProgressView().controlSize(.small)
                } else {
                    Text(action)
                }
            }
            .buttonStyle(ChromePushStyle(prominent: true))
            .disabled(store.purchasing != nil)
        }
        .padding(.vertical, 2)
    }

    /// What a missing product looks like — and it must never be a spinner that
    /// never stops.
    ///
    /// `load()` finishing does not mean every product arrived: a newly created
    /// one takes a while to reach the App Store's product endpoint, and one
    /// removed from sale never will. Drawing "Contacting the App Store…" in
    /// that case is a lie that lasts forever, which is exactly what the
    /// Champion row did the first time this screen was run against the live
    /// store. So the spinner belongs to the *load*, and the absence of a
    /// product after the load belongs to the product.
    @ViewBuilder
    private func unavailableRow(named name: String) -> some View {
        switch store.loadState {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Contacting the App Store…").foregroundStyle(Chrome.Colour.secondaryLabel)
            }
        case .loaded, .failed:
            VStack(alignment: .leading, spacing: 6) {
                Text("\(name) is unavailable right now.")
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                Button("Try Again") {
                    Task { await store.reload() }
                }
                .buttonStyle(ChromePushStyle())
            }
            .padding(.vertical, 2)
        }
    }

    /// One of the two policy links 3.1.2(c) requires on this screen: its glyph
    /// and title in the accent, as `ChromeLink` draws a link. A `Link` is the
    /// Mac's link blue there and the tint on iOS.
    private func policyLink(_ title: String, systemImage: String, destination: URL) -> some View {
        Button { openURL(destination) } label: {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(ChromeLinkStyle())
        .accessibilityAddTraits(.isLink)
    }

    // MARK: - Alerts

    private var thanksBinding: Binding<Bool> {
        Binding(get: { store.lastThanks != nil },
                set: { if !$0 { store.lastThanks = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { store.lastError != nil },
                set: { if !$0 { store.lastError = nil } })
    }
}
