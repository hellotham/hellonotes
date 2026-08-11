//
//  NoteInspector.swift
//  HelloNotes
//
//  The right rail: "what is this, and what touches it?"
//
//  It consolidates four surfaces that were scattered across the app — the
//  references panel wedged under the editor, the outline in a popover, tags in
//  the left sidebar, and note history in a sheet — into one place with a
//  consistent rhythm (decisions 1, 8 and 10 of docs/layout-architecture.md).
//
//  The left rail answers "where is it?"; this one answers "what is this?".
//  They cooperate across the shell: selecting a tag here filters the note list
//  over there.
//

import SwiftUI

/// The inspector's tabs, in the order they appear. Persisted so the rail
/// reopens where the user left it (decision 10) — least surprise for a tool
/// used in a rhythm.
enum InspectorTab: String, CaseIterable, Identifiable {
    case outline, tags, references, properties, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .outline: "Outline"
        case .tags: "Tags"
        case .references: "References"
        case .properties: "Properties"
        case .history: "History"
        }
    }

    var systemImage: String {
        switch self {
        case .outline: "list.bullet.indent"
        case .tags: "number"
        case .references: "link"
        case .properties: "tag"
        case .history: "clock.arrow.circlepath"
        }
    }
}

struct NoteInspector: View {
    // Outline
    let noteText: String
    var onSelectHeading: (DocumentHeading) -> Void

    // Tags — selecting one filters the note list in the *other* rail.
    let tagTree: [TagNode]
    @Binding var selectedTag: String?

    // References
    let backlinks: [Note]
    let outgoingLinks: [Note]
    let unlinkedMentions: [Note]
    var onOpenNote: (Note) -> Void
    var onLinkMention: (Note) -> Void

    // Properties (front matter)
    @Binding var properties: [Property]
    var onPropertiesChanged: () -> Void

    // History
    let fileURL: URL?
    let git: GitService
    var onRestoreRevision: (String) -> Void

    @Environment(AppearanceSettings.self) private var appearance
    @AppStorage("inspectorTab") private var storedTab = InspectorTab.outline.rawValue

    private var tab: InspectorTab { InspectorTab(rawValue: storedTab) ?? .outline }

    var body: some View {
        VStack(spacing: 0) {
            picker
            Divider()
            content
                // S3 — the inspector's content is a viewport; it expands and
                // scrolls, and never sizes the rail by what it holds.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var picker: some View {
        Picker("Inspector", selection: Binding(get: { tab }, set: { storedTab = $0.rawValue })) {
            ForEach(InspectorTab.allCases) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .labelStyle(.iconOnly)
                    .help(tab.title)
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(6)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .outline:
            OutlineView(text: noteText, onSelectHeading: onSelectHeading)
        case .tags:
            tagsTab
        case .references:
            referencesTab
        case .properties:
            propertiesTab
        case .history:
            historyTab
        }
    }

    // MARK: - Tags (decision 1 — they live here now, not in the left rail)

    // `@ViewBuilder` rather than a `Group`: `Group` also has a
    // `TableColumnContent` overload, and when the body is a `List` the compiler
    // picks it and then fails to infer its generics.
    @ViewBuilder
    private var tagsTab: some View {
        if tagTree.isEmpty {
            emptyState("No Tags", "number",
                       "Tags you write as #tag in a note appear here.")
        } else {
            List {
                Button { selectedTag = nil } label: {
                    Label("All Notes", systemImage: "tray.full")
                        .fontWeight(selectedTag == nil ? .semibold : .regular)
                }
                .buttonStyle(.plain)

                ForEach(tagTree) { node in
                    TagTreeRow(node: node, selectedTag: selectedTag,
                               selectedColor: appearance.accentTextColor) { tag in
                        selectedTag = tag
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    // MARK: - References

    private var hasReferences: Bool {
        !outgoingLinks.isEmpty || !backlinks.isEmpty || !unlinkedMentions.isEmpty
    }

    @ViewBuilder
    private var referencesTab: some View {
        if !hasReferences {
            emptyState("No References", "link",
                       "Nothing links to this note yet, and it links nowhere.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !outgoingLinks.isEmpty {
                        section("Outgoing Links", systemImage: "arrow.up.forward", notes: outgoingLinks)
                    }
                    if !backlinks.isEmpty {
                        section("Linked Mentions", systemImage: "link", notes: backlinks)
                    }
                    if !unlinkedMentions.isEmpty {
                        unlinkedSection
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func section(_ title: String, systemImage: String, notes: [Note]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(title.uppercased()) · \(notes.count)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(notes) { note in
                Button { onOpenNote(note) } label: {
                    Label(note.title, systemImage: systemImage)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 1)
            }
        }
    }

    private var unlinkedSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("UNLINKED MENTIONS · \(unlinkedMentions.count)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(unlinkedMentions) { note in
                HStack {
                    Button { onOpenNote(note) } label: {
                        Label(note.title, systemImage: "text.magnifyingglass")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Button("Link") { onLinkMention(note) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Turn this mention into a [[link]] in that note")
                }
                .padding(.vertical, 1)
            }
        }
    }

    // MARK: - Properties

    private var propertiesTab: some View {
        ScrollView {
            PropertiesEditor(properties: $properties, onChange: onPropertiesChanged)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - History (decision 8)

    @ViewBuilder
    private var historyTab: some View {
        if let fileURL {
            NoteHistoryView(fileURL: fileURL, git: git, onRestore: onRestoreRevision,
                            presentation: .rail)
                // A new note must reload the history, not keep the last note's.
                .id(fileURL)
        } else {
            emptyState("No Note", "clock.arrow.circlepath",
                       "Select a note to see how it has changed.")
        }
    }

    // MARK: -

    private func emptyState(_ title: String, _ symbol: String, _ message: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
