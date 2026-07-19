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
    /// Open a folder of Markdown files as a collection.
    var onOpenCollection: () -> Void
    /// Open an Obsidian vault (a collection with `.obsidian` conventions).
    var onOpenObsidian: () -> Void
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
                  detail: "Plain Markdown on disk is the source of truth — no database, no lock-in."),
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
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(highlights) { highlight in
                        row(highlight)
                    }
                }
                .padding(24)
            }
            Divider()
            actions
        }
        .frame(idealWidth: 460, idealHeight: 560)
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
        .padding(.top, 32)
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

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                onOpenCollection()
            } label: {
                Text("Open a Collection")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            Button("Open an Obsidian Vault") { onOpenObsidian() }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)

            Button("Explore first") { onDismiss() }
                .buttonStyle(.borderless)
                .controlSize(.large)
        }
        .padding(20)
    }
}
