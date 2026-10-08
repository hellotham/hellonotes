//
//  SettingsView.swift
//  HelloNotes
//
//  The app's settings — one container, the same on both platforms.
//
//  There were two: a tabbed Preferences window on the Mac and a pushed `Form`
//  sheet on iOS, each gated to its platform. The *controls* in them were
//  already shared — `AppearanceSettingsSections` and `FolderConventionSections`
//  — but the arrangement was not, and the arrangement was drawn by each OS: a
//  system toolbar of tabs on one, a system navigation bar and 44pt rows on the
//  other. An arrangement that differs is where a setting gets added to one
//  and forgotten in the other, which is how Reading width, Editor width and
//  Wrap guide came to be Mac-only in the first place; and a drawing that
//  differs is two apps.
//
//  Acknowledgements are opened from About, on both.
//

import SwiftUI

/// A page of Settings, so a route can open Settings *at* one.
///
/// AI settings are a page of Settings, not a screen of their own. There was a
/// second one — a sheet titled "AI Settings" holding the same form — because
/// neither a `Settings` window nor a settings sheet can be opened at a page, and
/// the Assistant needed to send people to its model choice. So a menu offered
/// "AI Settings…" beside "Settings…", two doors that read as two places. Every
/// route to AI settings now opens Settings, at AI.
enum SettingsPage: String {
    case general, appearance, git, ai, support

    /// The Mac's tab, stored: `openSettings` takes no argument, so a route
    /// sets this and then opens the window.
    static let storageKey = "settingsPage"
}

/// The app's settings: **one container, drawn by the app, on both platforms.**
///
/// There were two. The Mac had a `TabView` — a Preferences window with a
/// toolbar of five tabs — and iOS a `NavigationStack` sheet: one long `Form`
/// with AI, Git and Support pushed from rows inside it. The pages were shared;
/// the arrangement was not, so the same setting sat behind a tab on one
/// platform and three rows down a list on the other, in a system tab bar or a
/// system navigation bar, at each platform's own sizes.
///
/// Now it is the Mac's arrangement, drawn: a strip of five tabs above the
/// page, the chosen tab stored (`SettingsPage.storageKey`) so any route can
/// open Settings *at* a page, a Done button at the strip's end, and a fixed
/// 560×640 — the Mac's Settings window and the iPad's sheet are the same size
/// with the same pixels in them. Only the frame around them is the OS's: a
/// window with traffic lights on the Mac, a sheet on iOS.
struct AppSettingsView: View {
    var intelligenceSettings: IntelligenceSettings
    var appearance: AppearanceSettings
    /// The focused collection's Git service, if any. Settings is not opened
    /// "inside" a collection, so without one it gets a bare service — which is
    /// enough for **Accounts**, the part that has to be reachable before any
    /// repository exists (the credentials needed to *clone* one).
    var git: GitService?
    var accounts: GitAccountsStore?
    /// The two voluntary purchases.
    var store: StoreService
    /// A page to open at, for a route that has one in hand. The Mac's `Settings`
    /// window cannot be handed one (`openSettings` takes no argument), so its
    /// routes store the page instead; this is the same store.
    var page: SettingsPage? = nil

    @AppStorage(SettingsPage.storageKey) private var selection = SettingsPage.general
    @State private var bareGit = GitService()
    @State private var bareAccounts = GitAccountsStore()
    @Environment(\.dismiss) private var dismiss

    static let size = CGSize(width: 560, height: 640)

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabStrip(selection: $selection) { dismiss() }
            pageView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .chromeSheetFrame(width: Self.size.width, height: Self.size.height)
        .onAppear { if let page { selection = page } }
    }

    @ViewBuilder
    private var pageView: some View {
        switch selection {
        case .general:
            // Attachments, daily notes and templates (`FolderConventionSections`).
            ChromeForm { FolderConventionSections() }
        case .appearance:
            AppearanceSettingsView(settings: appearance)
        case .git:
            GitSettingsView(store: accounts ?? bareAccounts, git: git ?? bareGit)
        case .ai:
            // Already a form — never wrap it in another (the build-11 stub).
            IntelligenceSettingsForm(settings: intelligenceSettings)
        case .support:
            // Carries the App Store disclosures, so it must be reachable here
            // on both platforms — a review requirement, not a nicety.
            SupportSettingsView(store: store)
        }
    }
}

extension SettingsPage: CaseIterable {
    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .git: return "Git"
        case .ai: return "AI"
        case .support: return "Support"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .git: return "arrow.trianglehead.branch"
        case .ai: return "sparkles"
        case .support: return "heart"
        }
    }
}

/// The five pages as a strip of tabs — a glyph over its name, the chosen one
/// in the accent on a rounded wash, as the Mac's Preferences toolbar draws
/// them — with Done at the end. Centred, so the Mac's traffic lights at the
/// top-left never reach a tab.
private struct SettingsTabStrip: View {
    @Binding var selection: SettingsPage
    let done: () -> Void

    /// Room for Done, kept on *both* sides, so the tabs sit exactly in the
    /// middle and Done can never overlap the last of them.
    private static let doneWidth: CGFloat = 60

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.doneWidth)
                Spacer(minLength: 8)
                tabs(width: 72)
                Spacer(minLength: 8)
                doneButton.frame(width: Self.doneWidth, alignment: .trailing)
            }
            // A phone: the tabs share what Done leaves them.
            HStack(spacing: 4) {
                tabs(width: nil)
                doneButton
            }
        }
        .padding(.horizontal, Chrome.Metric.barPadding)
        .frame(height: 58)
        .background(Chrome.Colour.chrome.windowDraggable())
        .overlay(alignment: .bottom) { ChromeDivider() }
    }

    private var doneButton: some View {
        Button("Done", action: done)
            .keyboardShortcut(.cancelAction)
            .fixedSize()
    }

    /// The five tabs: 72pt each where there is room, sharing the width where
    /// there is not.
    private func tabs(width: CGFloat?) -> some View {
        HStack(spacing: 2) {
            ForEach(SettingsPage.allCases, id: \.self) { page in
                tab(page, width: width)
            }
        }
    }

    private func tab(_ page: SettingsPage, width: CGFloat?) -> some View {
        let isOn = page == selection
        return Button { selection = page } label: {
            VStack(spacing: 3) {
                Image(systemName: page.symbol)
                    .font(.system(size: 17))
                    .frame(height: 20)
                ChromeLine(page.title, size: 11, colour: isOn ? Chrome.Colour.label : Chrome.Colour.secondaryLabel)
            }
            .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(Chrome.Colour.secondaryLabel))
            .frame(width: width, height: 46)
            .frame(minWidth: 44, maxWidth: width == nil ? .infinity : width)
            .background(RoundedRectangle(cornerRadius: 8).fill(isOn ? Chrome.Colour.controlFill : .clear))
            .contentShape(.rect)
        }
        .buttonStyle(ChromePlainStyle())
        .accessibilityLabel(page.title)
        .accessibilityIdentifier("settings.tab.\(page.rawValue)")
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
    }
}
