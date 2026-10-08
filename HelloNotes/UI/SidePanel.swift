//
//  SidePanel.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  The right panel, and everything it can show.
//
//  The shell is three regions: **collections on the left, the editor in the
//  middle, and anything else on the right.** One panel, one thing showing in
//  it at a time, one way to choose. Outline, Tags, References, Properties and
//  History are not a different *kind* of thing from Graph, Ask Library, the
//  Assistant and the Mind Map — they are all ancillary to the note in the
//  middle, and they all belong here.
//
//  They were two kinds for a while, and the app carried two of everything for
//  it: two enums, two pieces of state, two chromes (five icon toggles in the
//  band for one set, a title row inside the panel for the other) and two
//  widths. The second set had been windows on the Mac and sheets on iPad
//  before that — a scene the system places, or a modal over the note, when
//  what they always were is a panel beside it. *An editor never blocks
//  editing.*
//
//  A window is now only what someone asks for by name (New Window, Open in New
//  Window), on both platforms.
//

import SwiftUI
import MarkdownEditor

/// What the right panel is showing. Persisted, so the panel reopens where it
/// was left (`shell-chrome.md` decision 10).
///
/// Ordered as the picker lists them: what this *note* is, then what the
/// *collection* is.
enum SidePanel: String, CaseIterable, Identifiable {
    case outline, tags, references, properties, history, mindMap
    case graph, askLibrary, assistant

    var id: String { rawValue }

    var title: String {
        switch self {
        case .outline: "Outline"
        case .tags: "Tags"
        case .references: "References"
        case .properties: "Properties"
        case .history: "History"
        case .mindMap: "Mind Map"
        case .graph: "Graph"
        case .askLibrary: "Ask Library"
        case .assistant: "Assistant"
        }
    }

    var systemImage: String {
        switch self {
        case .outline: "list.bullet.indent"
        case .tags: "number"
        case .references: "link"
        case .properties: "tag"
        case .history: "clock.arrow.circlepath"
        case .mindMap: "point.topleft.down.curvedto.point.bottomright.up"
        case .graph: "point.3.connected.trianglepath.dotted"
        case .askLibrary: "sparkles.rectangle.stack"
        case .assistant: "sparkles"
        }
    }

    /// Whether this panel is about the open note or about the collection —
    /// the two groups the picker draws, and the only distinction between these
    /// nine that means anything.
    var isAboutTheNote: Bool {
        switch self {
        case .outline, .tags, .references, .properties, .history, .mindMap: true
        case .graph, .askLibrary, .assistant: false
        }
    }

    /// Panels that need a note open to say anything.
    var needsNote: Bool { isAboutTheNote }

    static var aboutTheNote: [SidePanel] { allCases.filter(\.isAboutTheNote) }
    static var aboutTheCollection: [SidePanel] { allCases.filter { !$0.isAboutTheNote } }
}

/// The panel's own header: every panel it can show, the one it is showing, and
/// a way to close it.
///
/// A **strip of icons**, because a list of what you can see should be visible
/// rather than behind a tap — the same reason the app has no long-press-only
/// commands. The Mac carried five of these in the band while the panel held
/// five things (`shell-chrome.md` D6); nine do not fit a band that also carries
/// search, and they do fit here, where both platforms draw the same strip.
///
/// Squeezed narrower than the strip needs — the panel's floor is 220pt — it
/// falls back to a pull-down naming the current panel. `ViewThatFits` chooses,
/// so the fallback is the layout's own answer rather than a width written twice.
struct SidePanelHeader: View {
    @Binding var panel: SidePanel
    /// Whether a note is open; the note's panels need one.
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

    /// Nine buttons, the note's six and the collection's three, with a rule
    /// between the groups — the bar's own buttons, so the chosen one is drawn
    /// exactly as the bar draws a button that is on.
    private var strip: some View {
        HStack(spacing: Chrome.Metric.barSpacing) {
            ForEach(SidePanel.aboutTheNote) { icon(for: $0) }
            Rectangle().fill(Chrome.Colour.separator).frame(width: 1, height: 16)
                .padding(.horizontal, 2)
            ForEach(SidePanel.aboutTheCollection) { icon(for: $0) }
        }
        .fixedSize()
    }

    private func icon(for choice: SidePanel) -> some View {
        ChromeButton(title: choice.title, systemImage: choice.systemImage,
                     isOn: choice == panel, accent: accent) {
            panel = choice
        }
        .disabled(choice.needsNote && !hasNote)
        .accessibilityAddTraits(choice == panel ? [.isSelected] : [])
    }

    /// The fallback where the strip cannot fit: the same nine, named.
    private var pullDown: some View {
        Menu {
            Section("This note") {
                ForEach(SidePanel.aboutTheNote) { choice in
                    button(for: choice).disabled(!hasNote)
                }
            }
            Section("This collection") {
                ForEach(SidePanel.aboutTheCollection) { choice in
                    button(for: choice)
                }
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

    private func button(for choice: SidePanel) -> some View {
        Button {
            panel = choice
        } label: {
            Label(choice.title, systemImage: choice == panel ? "checkmark" : choice.systemImage)
        }
    }
}

// MARK: - Graph

/// The link graph. `GraphPane` is the graph itself; this supplies what a panel
/// beside the notes needs — asking the shell to open a note.
struct GraphPanel: View {
    @Environment(Library.self) private var library

    var body: some View {
        GraphPane(onOpen: { library.requestOpen($0) })
    }
}

// MARK: - Mind map

/// The mind map of the open note.
struct MindMapPanel: View {
    let rootURL: URL
    /// The editor showing `rootURL` in this window — the one a section tap
    /// scrolls (`EditorBus`). The find it posts was addressed to no one, so a
    /// section tapped here selected that heading's text in every editor in
    /// every window that had it.
    let editorID: String

    @Environment(Library.self) private var library
    @Environment(LiveBuffer.self) private var liveBuffer
    @State private var fileText: String?

    /// What is being typed, when the editor is holding this note; what is on
    /// disk otherwise.
    ///
    /// This read the file unconditionally, so the Mac's mind map showed the
    /// note as of the last autosave while the iPad's — handed the live buffer —
    /// showed what you were typing. One surface, one answer: the live text.
    private var text: String? { liveBuffer.text(for: rootURL) ?? fileText }

    var body: some View {
        MindMapPane(rootURL: rootURL,
                    text: text,
                    onOpenNote: { library.requestOpen($0) },
                    onShowSection: showSection)
            .task(id: rootURL) {
                // Only when the editor is not holding it — reading a file we
                // already have in memory is a coordinated read for nothing.
                guard liveBuffer.text(for: rootURL) == nil else { return }
                fileText = await offMain { try? FileIO.readString(at: rootURL) }
            }
    }

    /// Open the root note and scroll to `heading`.
    private func showSection(_ heading: String?) {
        library.requestOpen(rootURL)
        guard let heading else { return }
        Task { @MainActor in
            // Give the shell a beat to switch notes before searching.
            try? await Task.sleep(for: .milliseconds(400))
            NotificationCenter.default.post(name: EditorBus.findQuery(editor: editorID), object: nil,
                                            userInfo: ["query": heading])
            try? await Task.sleep(for: .milliseconds(1200))
            NotificationCenter.default.post(name: EditorBus.clearHighlights(editor: editorID), object: nil)
        }
    }
}

// MARK: - Ask Library

/// Retrieval-augmented Q&A over every open collection.
struct LibraryChatPanel: View {
    @Environment(Library.self) private var library
    @Environment(IntelligenceSettings.self) private var intelligenceSettings

    /// Taken once, as the panel appears. Held in `@State` rather than read from
    /// the library in `body`, because taking it *is* a mutation — a body that
    /// re-evaluated would find it already gone.
    @State private var seed: String?

    var body: some View {
        LibraryChatView(intelligence: IntelligenceService(settings: intelligenceSettings),
                        notes: library.allNotes,
                        searches: library.collections.map(\.search),
                        onOpenNote: { library.requestOpen($0.id) },
                        initialQuestion: seed)
        .task { seed = library.takePendingLibraryQuestion() }
    }
}

// MARK: - Assistant

/// The agentic assistant. Everything it owns lives in `AssistantHost`.
struct AssistantPanel: View {
    var body: some View { AssistantHost() }
}
