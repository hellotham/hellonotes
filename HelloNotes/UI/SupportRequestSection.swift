//
//  SupportRequestSection.swift
//  HelloNotes
//
//  The one thing backing the app actually buys: a support request, from inside
//  the app, to the person who makes it.
//
//  ## What it is not
//
//  It is not *priority* support. The App Store listing said "priority support
//  requests" and nothing in the app had ever ranked one request above another —
//  a promise about a queue that does not exist. What can honestly be offered is
//  a channel: Champion supporters and commercial licence holders can open a
//  request here, and everyone else is told plainly that this is what backing the
//  app is for.
//
//  ## Why it is a `mailto:` and not a form
//
//  The app sends nothing. It composes the message and hands it to the user's own
//  mail client, where they can read every word — including the diagnostics —
//  and decide whether to send it. That keeps "Data Not Collected" literally
//  true: there is no endpoint, no account, and nothing leaves the device that
//  the person did not press send on themselves.
//
//  The diagnostics are deliberately dull: versions and platform. No paths, no
//  collection names, no note titles. A support request is not a reason to learn
//  what someone keeps in their vault.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct SupportRequestSection: View {
    var store: StoreService

    /// The published address, the same one the website's support page uses.
    static let supportAddress = "info@hellotham.com"

    @State private var summary = ""

    var body: some View {
        Section {
            if store.canRequestSupport {
                entitled
            } else {
                locked
            }
        } header: {
            Text("Support Request")
        } footer: {
            Text(store.canRequestSupport
                 ? "Opens your mail app with the message ready to send. HelloNotes sends nothing itself, and includes no information about your notes — only the versions below."
                 : "Support requests are part of backing HelloNotes. Everything the app does is included for everyone; this is a way to reach the person who makes it.")
        }
    }

    // MARK: - Entitled

    @ViewBuilder
    private var entitled: some View {
        LabeledField(label: "What's happening?", text: $summary,
                     prompt: "e.g. Notes in a shared folder stop syncing")
        Button {
            open(Self.composeURL(summary: summary, entitlement: store.supportEntitlement))
        } label: {
            Label("Compose Support Request", systemImage: "envelope")
        }
        .disabled(summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        if let entitlement = store.supportEntitlement {
            LabeledContent("Sending as") { Text(entitlement).foregroundStyle(.secondary) }
        }
    }

    // MARK: - Not entitled

    @ViewBuilder
    private var locked: some View {
        // **Say why, not just no.** A disabled control with no explanation is
        // the shape of a bug; the requirement is that the screen states the
        // condition and that the way to meet it is directly below.
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("Become a Champion or hold a commercial licence to send a support request.")
                // Not "below": they are *above* this section, and saying so
                // was wrong the moment it was written. Phrased without a
                // direction at all, so reordering the screen cannot make the
                // sentence false again.
                Text("Either one is on this screen. Nothing else in HelloNotes is affected either way.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "lock")
        }
        .accessibilityIdentifier("support.request.locked")
    }

    // MARK: - Composing

    /// A `mailto:` carrying the summary and a short, dull diagnostic block.
    ///
    /// Built as `URLComponents` rather than by string-joining, so a subject with
    /// an `&` in it cannot truncate the body — the shape of bug that makes a
    /// support request arrive empty and blames the person who sent it.
    static func composeURL(summary: String, entitlement: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportAddress
        components.queryItems = [
            URLQueryItem(name: "subject", value: "HelloNotes support — \(summary)"),
            URLQueryItem(name: "body", value: body(summary: summary, entitlement: entitlement)),
        ]
        return components.url
    }

    static func body(summary: String, entitlement: String?) -> String {
        """
        \(summary)



        ——— sent from HelloNotes ———
        \(diagnostics(entitlement: entitlement))
        """
    }

    /// Versions and platform. Nothing about the user's notes.
    static func diagnostics(entitlement: String?) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        #if os(macOS)
        let platform = "macOS"
        #else
        let platform = UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #endif
        return """
        HelloNotes \(version) (\(build))
        \(platform) — \(os)
        Support: \(entitlement ?? "none")
        """
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}
