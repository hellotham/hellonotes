//
//  SidePanel.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  The right panel, and everything it can show.
//
//  The window is three regions, each about one thing: **the collection on the
//  left, the note in the middle, and what the note is on the right.** So the
//  panel shows facts about the open note — its summary and outline, its
//  properties, its tags, its links, its history and its graph — and nothing
//  that is about the collection. The Mind Map, the Assistant and Ask Your
//  Library are the collection's; they open as tabs beside the notes, from the
//  sidebar that holds the collection (`CollectionTool`).
//
//  It was nine views for a while, the collection's three among the note's six
//  — one panel, one state, one width — and that is how a map of one note's
//  ideas came to be called the Mind Map while the collection's links were the
//  Graph: the panel did not say what it was about, so neither did its views.
//
//  An editor never blocks editing: the panel is a column beside the note
//  wherever one fits, and only a phone carries it over the note. A window is
//  only what someone asks for by name (New Window, Open in New Window), on both
//  platforms.
//

import SwiftUI
import MarkdownEditor

/// What the right panel is showing. Persisted, so the panel reopens where it
/// was left (`shell-chrome.md` decision 10) — and read leniently, so a choice
/// stored before the collection's views left the panel opens the outline.
///
/// Every case is a fact about the open note, in the order the header draws
/// them.
enum SidePanel: String, CaseIterable, Identifiable {
    case outline, tags, references, properties, history, graph

    var id: String { rawValue }

    var title: String {
        switch self {
        // The summary is an outline at another resolution, and shares its tab.
        case .outline: "Summary & Outline"
        case .tags: "Tags"
        case .references: "Links"
        case .properties: "Properties"
        case .history: "History"
        case .graph: "Graph"
        }
    }

    var systemImage: String {
        switch self {
        case .outline: "list.bullet.indent"
        case .tags: "number"
        case .references: "link"
        case .properties: "tag"
        case .history: "clock.arrow.circlepath"
        case .graph: "point.3.connected.trianglepath.dotted"
        }
    }
}

/// The panel's own header: every view it can show, the one it is showing, and
/// a way to close it.
///
/// A **strip of icons**, because a list of what you can see should be visible
/// rather than behind a tap — the same reason the app has no long-press-only
/// commands. Squeezed narrower than the strip needs — the panel's floor is
/// 220pt — it falls back to a pull-down naming the current view. `ViewThatFits`
/// chooses, so the fallback is the layout's own answer rather than a width
/// written twice.
struct SidePanelHeader: View {
    @Binding var panel: SidePanel
    /// Whether a note is open; every view here is about one.
    var hasNote: Bool
    var accent: Color = .accentColor
    let onClose: () -> Void

    @Environment(\.shell) private var shell

    /// Whether Escape closes the panel: only where it is carried over the
    /// note (a phone), never where it is a column beside it. As a column it
    /// took Escape from the find bar's Done and the Assistant's approval card,
    /// whose Deny it is — Escape during an approval could close the panel
    /// instead of denying the edit (secondary.md §9, item 8; implemented.md
    /// §51.36).
    private var escapeCloses: Bool {
        !ShellMetrics.hasPanelColumn(kind: shell.kind, width: shell.size.width)
    }

    var body: some View {
        // The bar's height and chrome, so the panel's header and the editor's
        // bar are one continuous row. It was 8pt of padding around 26pt icons
        // in `.headline`, which is 13pt on the Mac and 17pt on iOS.
        HStack(spacing: Chrome.Metric.barSpacing) {
            ViewThatFits(in: .horizontal) {
                strip
                pullDown
            }
            Spacer(minLength: 0)
            ChromeButton(title: "Close panel", systemImage: "xmark.circle.fill", accent: accent,
                         action: onClose)
                .keyboardShortcut(escapeCloses ? .cancelAction : nil)
        }
        .padding(.horizontal, Chrome.Metric.barPadding)
        .frame(height: Chrome.Metric.barHeight)
        .background(Chrome.Colour.chrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Chrome.Colour.separator).frame(height: 1)
        }
    }

    /// The bar's own buttons, so the chosen one is drawn exactly as the bar
    /// draws a button that is on.
    private var strip: some View {
        HStack(spacing: Chrome.Metric.barSpacing) {
            ForEach(SidePanel.allCases) { icon(for: $0) }
        }
        .fixedSize()
    }

    private func icon(for choice: SidePanel) -> some View {
        ChromeButton(title: choice.title, systemImage: choice.systemImage,
                     isOn: choice == panel, accent: accent) {
            panel = choice
        }
        .disabled(!hasNote)
        .accessibilityAddTraits(choice == panel ? [.isSelected] : [])
    }

    /// The fallback where the strip cannot fit: the same views, named.
    private var pullDown: some View {
        Menu {
            ForEach(SidePanel.allCases) { choice in
                Button {
                    panel = choice
                } label: {
                    Label(choice.title, systemImage: choice == panel ? "checkmark" : choice.systemImage)
                }
                .disabled(!hasNote)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: panel.systemImage)
                    .font(Chrome.Typeface.rowIcon)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                Text(panel.title)
                    .font(Chrome.Typeface.title)
                    .foregroundStyle(Chrome.Colour.label)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Chrome.Colour.tertiaryLabel)
            }
            .frame(height: Chrome.Metric.control)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(ChromePlainStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Showing \(panel.title). Choose what this panel shows")
    }
}

// MARK: - Graph

/// The open note's links in and out. `GraphPane` is the graph itself; this
/// supplies what a panel beside the notes needs — the note, and asking the
/// shell to open another.
struct NoteGraphPanel: View {
    let noteURL: URL

    @Environment(Library.self) private var library

    var body: some View {
        GraphPane(noteURL: noteURL, onOpen: { library.requestOpen($0) })
    }
}
