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
    /// Every tag in the collection. Never listed wholesale; searched.
    let allTags: [String]
    /// How many notes carry a tag, shown beside a search result so you can see
    /// whether following it leads anywhere.
    var noteCount: (String) -> Int = { _ in 0 }
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
    /// The tag search. Not persisted — reopening the rail to a mysteriously
    /// narrowed result would be worse than retyping three letters.
    @State private var tagQuery = ""

    private var tab: InspectorTab { InspectorTab(rawValue: storedTab) ?? .outline }

    var body: some View {
        VStack(spacing: 0) {
            picker
            Divider()
            content
                // S3 — the inspector's content is a viewport; it expands and
                // scrolls, and never sizes the rail by what it holds.
                //
                // `alignment: .top` is load-bearing, not decoration. A tab
                // whose content has no flexible child — a short outline, a
                // handful of properties — is *centred* by a bare
                // `maxHeight: .infinity`, which reads as a large empty gap
                // under the picker with the content stranded down the pane.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    // MARK: - Tags
    //
    // Note-first, then search — never a directory (docs/layout-architecture.md
    // decision 1, refined after measuring a real vault: of 2,027 notes only 81
    // carry a tag, 223 tags exist and just 40 appear in more than one note).
    //
    // A ranked or alphabetical list of 223 names is 223 rows of noise to answer
    // a question the user didn't ask. The question they *did* ask, by opening
    // the inspector, is "what is this note?" — so that goes first, and the
    // other 222 tags are reached by typing. Nothing is enumerated by default,
    // which is also why this doesn't get worse as a vault grows.
    //
    // Following a tag is navigation, and navigation results belong in the note
    // list, which already has rows, snippets, sorting and selection. Selecting
    // here sets the list's filter rather than reproducing it in a 280pt rail.

    // `@ViewBuilder` rather than a `Group`: `Group` also has a
    // `TableColumnContent` overload, and when the body is a `List` the compiler
    // picks it and then fails to infer its generics.
    @ViewBuilder
    private var tagsTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            thisNotesTags

            Divider()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Find a tag", text: $tagQuery)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !tagQuery.isEmpty {
                    Button { tagQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            // Results disclose only once you have typed. An empty field shows
            // nothing rather than everything: with 223 tags, "everything" is
            // the state this design exists to avoid.
            if !tagQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                Divider()
                searchResults
            }

            Spacer(minLength: 0)
        }
    }

    /// What this note is tagged — the question the inspector is open to answer.
    /// Each is a button, because the reason to look at a note's tag is usually
    /// to see what else shares it.
    @ViewBuilder
    private var thisNotesTags: some View {
        let mine = MarkdownParsing.tags(in: noteText)
        VStack(alignment: .leading, spacing: 6) {
            Text("THIS NOTE")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if mine.isEmpty {
                Text("No tags. Write #tag anywhere in the note to add one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                WrapLayout(spacing: 6) {
                    ForEach(mine, id: \.self) { tag in
                        tagChip(tag, isSelected: selectedTag == tag, count: nil)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

    /// Tags matching the query, with how many notes carry each — a count of 1
    /// means following it leads only back here, which is worth knowing before
    /// the click rather than after.
    private var searchResults: some View {
        let query = tagQuery.trimmingCharacters(in: .whitespaces)
        let matches = allTags
            .filter { $0.localizedCaseInsensitiveContains(query) }
            .sorted { (noteCount($0), $1.lowercased()) > (noteCount($1), $0.lowercased()) }
        return Group {
            if matches.isEmpty {
                Text("No tag matches “\(query)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(matches.prefix(40), id: \.self) { tag in
                            Button { selectedTag = tag } label: {
                                HStack(spacing: 6) {
                                    Text("#\(tag)")
                                        .lineLimit(1)
                                        .foregroundStyle(selectedTag == tag
                                                         ? appearance.accentTextColor : .primary)
                                    Spacer(minLength: 6)
                                    Text("\(noteCount(tag))")
                                        .font(.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                        if matches.count > 40 {
                            Text("+\(matches.count - 40) more — keep typing")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    /// A tag as a chip. Nesting is shown as the full path on one chip rather
    /// than a disclosure tree: 8 of 223 tags are nested here, which does not
    /// pay for indentation, triangles and expansion state.
    private func tagChip(_ tag: String, isSelected: Bool, count: Int?) -> some View {
        Button { selectedTag = isSelected ? nil : tag } label: {
            Text("#\(tag)")
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isSelected ? appearance.accentTextColor.opacity(0.22)
                                       : Color.secondary.opacity(0.12),
                            in: Capsule())
                .foregroundStyle(isSelected ? appearance.accentTextColor : .primary)
        }
        .buttonStyle(.plain)
        .help(isSelected ? "Stop filtering by #\(tag)" : "Show every note tagged #\(tag)")
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

    /// An empty state sits near the top of the rail rather than floating in
    /// the middle of a tall column, where it reads as a layout fault.
    private func emptyState(_ title: String, _ symbol: String, _ message: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.top, 28)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}
