//
//  WelcomeView.swift
//  HelloNotes
//
//  Created by Chris Tham on 20/7/2026.
//
//  First-run onboarding. Shown once (gated by @AppStorage("hasSeenWelcome"))
//  the first time the app opens with no library to restore, so a new user
//  meets the app — what it is, what it can do — and lands directly on the
//  "open a folder of Markdown" action instead of a blank pane. Dismissible;
//  the same open actions remain reachable afterwards from the launcher.
//
//  Shared verbatim by macOS and iOS: the body is pure SwiftUI, and each host
//  passes in the platform's own open-collection / open-vault closures.
//

import SwiftUI

struct WelcomeView: View {
    /// Every way to add a collection — the same value the toolbar and the menu
    /// bar render. This screen is a modal view *of* that set, so it takes the
    /// set rather than a hand-picked pair of closures.
    var add: AddCollectionActions
    /// Dismiss without opening anything (the user will explore first).
    var onDismiss: () -> Void

    /// The app-icon gradient, reused from the launch splash for a consistent
    /// identity across the first-run surfaces.
    private static let brandGradient = LinearGradient(
        colors: [
            Color(.sRGB, red: 0.48, green: 0.24, blue: 0.93),
            Color(.sRGB, red: 0.78, green: 0.25, blue: 0.75),
            Color(.sRGB, red: 0.93, green: 0.30, blue: 0.51),
            Color(.sRGB, red: 0.98, green: 0.62, blue: 0.24),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    private struct Highlight: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let detail: String
    }

    private let highlights: [Highlight] = [
        Highlight(symbol: "folder",
                  title: "Your files, your folders",
                  detail: "Plain Markdown on disk — local or a cloud folder (iCloud, Dropbox, Google Drive, OneDrive, Box). No database, no lock-in."),
        Highlight(symbol: "eye",
                  title: "GitHub-identical preview",
                  detail: "Tables, task lists, math, and Mermaid render exactly as they do on GitHub."),
        Highlight(symbol: "link",
                  title: "Links that connect ideas",
                  detail: "[[Wiki-links]], backlinks, tags, and a graph tie your notes together."),
        Highlight(symbol: "sparkles",
                  title: "On-device intelligence",
                  detail: "Summarize, rewrite, and ask your library — with Apple Intelligence or your own model."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(highlights) { highlight in
                        row(highlight)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
            Divider()
            actions
        }
        // A firm min height so the macOS sheet is tall enough to show all four
        // highlights without scrolling (a bare idealHeight collapses to the
        // ScrollView's minimal ideal). iOS sheets ignore this and use detents.
        .frame(minWidth: 440, idealWidth: 460, minHeight: 600, idealHeight: 620)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "note.text")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .background(Self.brandGradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .accessibilityHidden(true)
            Text("Welcome to HelloNotes")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text("Where every idea says hello.")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
        .padding(.bottom, 8)
        .padding(.horizontal, 24)
    }

    private func row(_ highlight: Highlight) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: highlight.symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(highlight.title).font(.headline)
                Text(highlight.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Actions

    /// Every way in, not a chosen two.
    ///
    /// This offered "Open a Collection" and "Open an Obsidian Vault" — which
    /// were the *same* command with the same default location, so the first
    /// screen of the app spent its two choices saying one thing, and said
    /// nothing about iCloud Drive, mounted cloud folders, cloud accounts, or
    /// Git. Showing the whole set is both the honest description and the
    /// better advertisement: the breadth *is* the feature.
    ///
    /// It renders `AddCollectionActions.options`, the same value the toolbar
    /// and menu bar render, so this screen cannot fall behind them.
    private var actions: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                ForEach(add.options) { option in
                    Button { option.run() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: option.symbol)
                                .font(.title3)
                                .frame(width: 24)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title).fontWeight(.medium)
                                Text(option.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }

            Button("Explore first") { onDismiss() }
                .buttonStyle(.borderless)
                .controlSize(.large)
        }
        .padding(20)
    }
}
