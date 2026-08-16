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
import TipKit

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

/// A menu command asking the rail to run one of its model-backed suggestions.
///
/// The command lives in the menu bar and the palette, where it can be found;
/// its answer lands in the tab that owns that kind of information. Something has
/// to carry the request across that gap, and this is it.
///
/// `token` is a counter rather than a `Bool` because running Summarise twice in
/// a row is a perfectly ordinary thing to want, and a flag can only be raised
/// once. The host bumps it; the rail watches the whole value for a change.
struct InspectorRequest: Equatable {
    enum Kind { case summarize, suggestTags, suggestLinks }
    var kind: Kind
    var token: Int

    /// The tab that shows this request's answer, so the host can reveal it.
    var tab: InspectorTab {
        switch kind {
        case .summarize: .outline
        case .suggestTags: .tags
        case .suggestLinks: .references
        }
    }
}

struct NoteInspector: View {
    // Outline
    let noteText: String
    var onSelectHeading: (DocumentHeading) -> Void
    /// Summarise the note. `nil` hides the affordance — no provider, nothing to
    /// offer, and an always-visible button that always fails is worse than none.
    var summarize: ((String) async throws -> String)? = nil
    /// Write the summary into the note as a callout. `nil` leaves it read-only.
    var onInsertSummary: ((String) -> Void)? = nil

    // Tags — selecting one filters the note list in the *other* rail.
    /// Every tag in the collection. Never listed wholesale; searched.
    let allTags: [String]
    /// How many notes carry a tag, shown beside a search result so you can see
    /// whether following it leads anywhere.
    var noteCount: (String) -> Int = { _ in 0 }
    @Binding var selectedTag: String?
    /// Ask the configured model for tags this note's *content* suggests.
    /// `nil` hides the button — no provider configured, nothing to offer.
    var suggestTags: ((String, [String]) async throws -> [String])? = nil
    /// Write a suggested tag into the note. `nil` makes suggestions read-only.
    var onInsertTag: ((String) -> Void)? = nil

    // References
    let backlinks: [Note]
    let outgoingLinks: [Note]
    let unlinkedMentions: [Note]
    var onOpenNote: (Note) -> Void
    var onLinkMention: (Note) -> Void
    /// Every note title the collection can be linked to — the pool a suggestion
    /// is drawn from.
    var linkCandidates: [String] = []
    /// Ask the model which of those this note should link to. `nil` hides it.
    var suggestLinks: ((String, [String]) async throws -> [String])? = nil
    /// Write an accepted suggestion into the note as a `[[link]]`.
    var onInsertLink: ((String) -> Void)? = nil

    // Properties (front matter)
    @Binding var properties: [Property]
    var onPropertiesChanged: () -> Void

    // History
    let fileURL: URL?
    let git: GitService
    var onRestoreRevision: (String) -> Void

    /// Which tab is showing. Owned by the shell, because the *toolbar* is this
    /// panel's tab strip (`shell-chrome.md` D6): the five icon toggles in the
    /// band select the tab and, pressing the active one, close the panel —
    /// Pages' `Format`/`Document` behaviour. The panel therefore draws no strip
    /// of its own, which is what removed the spurious row inside it.
    let tab: InspectorTab

    /// A pending menu-command request. See `InspectorRequest`.
    var request: InspectorRequest? = nil

    @Environment(AppearanceSettings.self) private var appearance
    /// The tag search. Not persisted — reopening the rail to a mysteriously
    /// narrowed result would be worse than retyping three letters.
    @State private var tagQuery = ""

    /// Suggestion state. `.idle` and `.none` are different answers — "not asked"
    /// versus "asked, and this note already carries everything worth carrying".
    enum SuggestionState: Equatable {
        case idle
        case loading
        case ready([String])
        case none
        case failed(String)
    }
    @State private var suggestion: SuggestionState = .idle
    /// Suggested links, in the same three-answer shape as tags.
    @State private var linkSuggestion: SuggestionState = .idle

    /// The summary. Its own type because "here it is" carries a string, which
    /// `SuggestionState`'s `[String]` would only pretend to hold.
    enum SummaryState: Equatable {
        case idle
        case loading
        case ready(String)
        case failed(String)
    }
    @State private var summary: SummaryState = .idle

    var body: some View {
        VStack(spacing: 0) {
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
        // Both of these live on the root rather than inside a tab, and that is
        // not a style choice. `content` is a `switch`: the References tab does
        // not exist as a view until it is selected, and a subview that appears
        // *already holding* the new value never fires `onChange` for it. A menu
        // command that switches the tab and asks for a suggestion in the same
        // update would therefore be silently dropped by a per-tab observer.
        .onChange(of: request) { _, new in
            guard let new else { return }
            switch new.kind {
            case .summarize: runSummarize()
            case .suggestTags: runSuggestTags(existing: MarkdownParsing.tags(in: noteText))
            case .suggestLinks: runSuggestLinks()
            }
        }
        // Suggestions belong to the note they were derived from. Keyed on the
        // file rather than on how much the text changed: the old heuristic
        // ("the length moved by more than 40 characters") could not tell a
        // switched note from a pasted paragraph, so it both cleared suggestions
        // mid-edit and kept them across a selection change.
        .onChange(of: fileURL) { _, _ in
            suggestion = .idle
            linkSuggestion = .idle
            summary = .idle
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .outline:
            outlineTab
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

    // MARK: - Outline
    //
    // A summary is an outline at another resolution: the headings say how the
    // note is shaped, the summary says what it says. Putting them in one tab is
    // why there is no longer an "Intelligence" panel — the answer belongs with
    // the question it answers, not with the machinery that produced it.

    private var outlineTab: some View {
        VStack(spacing: 0) {
            if summarize != nil {
                summarySection
                Divider()
            }
            OutlineView(text: noteText, onSelectHeading: onSelectHeading)
        }
    }

    /// The summary strip. Its header row is always there when a provider is —
    /// that permanently visible "Summarise" is the discoverability, and it is
    /// cheap because nothing runs until it is pressed.
    @ViewBuilder
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("SUMMARY")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button(action: runSummarize) {
                    if summary == .loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(summaryIsReady ? "Again" : "Summarise", systemImage: "sparkles")
                            .font(.caption2)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(summary == .loading || noteText.isEmpty)
                .help("Summarise this note")
            }

            switch summary {
            case .idle:
                Text("Summarise this note to see what it says, not just how it is shaped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .loading:
                EmptyView()
            case .failed(let message):
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .help(message)
            case .ready(let text):
                Text(text)
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                if onInsertSummary != nil {
                    Button {
                        onInsertSummary?(text)
                        // It is in the note now; offering to add it again would
                        // quietly produce two summary callouts.
                        summary = .idle
                    } label: {
                        Label("Insert as Callout", systemImage: "plus")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("Add the summary to the top of the note as a > [!summary] callout")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

    private var summaryIsReady: Bool {
        if case .ready = summary { return true }
        return false
    }

    private func runSummarize() {
        guard let summarize, !noteText.isEmpty else { return }
        summary = .loading
        Task {
            do {
                let text = try await summarize(noteText)
                summary = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? .failed("The model returned nothing.")
                    : .ready(text)
            } catch {
                summary = .failed(error.localizedDescription)
            }
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
            HStack(spacing: 4) {
                Text("THIS NOTE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if suggestTags != nil { suggestButton(existing: mine) }
            }
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
            suggestions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

    // MARK: - Suggested tags

    /// Deliberately a button, not something that runs on open. Suggesting costs
    /// a model call per note, and a rail you glance at should not be spending
    /// tokens (or, on a local model, seconds) every time the selection changes.
    private func suggestButton(existing: [String]) -> some View {
        Button {
            runSuggestTags(existing: existing)
        } label: {
            if case .loading = suggestion {
                ProgressView().controlSize(.small)
            } else {
                Label("Suggest", systemImage: "sparkles").font(.caption2)
            }
        }
        .buttonStyle(.borderless)
        .disabled(suggestion == .loading || noteText.isEmpty)
        .help("Suggest tags from this note's content")
    }

    /// Shared by the button and by the **Note ▸ Suggest Tags** command, so the
    /// two routes cannot drift into behaving differently.
    private func runSuggestTags(existing: [String]) {
        guard let suggestTags, !noteText.isEmpty else { return }
        suggestion = .loading
        Task {
            do {
                let tags = try await suggestTags(noteText, existing)
                // Anything the note already carries is not a suggestion.
                let fresh = tags.filter { tag in
                    !existing.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
                }
                suggestion = fresh.isEmpty ? .none : .ready(fresh)
            } catch {
                suggestion = .failed(error.localizedDescription)
            }
        }
    }

    @ViewBuilder
    private var suggestions: some View {
        switch suggestion {
        case .idle, .loading:
            EmptyView()
        case .none:
            Text("No new tags suggested.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(3)
                .help(message)
        case .ready(let tags):
            VStack(alignment: .leading, spacing: 4) {
                Text("SUGGESTED")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                WrapLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Button {
                            onInsertTag?(tag)
                            // It is in the note now, so it is no longer a
                            // suggestion — the list must not offer it twice.
                            if case .ready(let current) = suggestion {
                                let left = current.filter { $0 != tag }
                                suggestion = left.isEmpty ? .idle : .ready(left)
                            }
                        } label: {
                            Label("#\(tag)", systemImage: "plus")
                                .font(.caption)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(.quaternary))
                        }
                        .buttonStyle(.plain)
                        .disabled(onInsertTag == nil)
                        .help("Add #\(tag) to this note")
                    }
                }
            }
            .padding(.top, 2)
        }
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

    private var referencesTab: some View {
        // Deliberately not an early return to an empty state when there are no
        // references. A note with nothing linking to it is exactly the note
        // most worth suggesting links for, and the old empty state replaced the
        // whole tab — hiding the one action that could fix the emptiness it was
        // reporting.
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if suggestLinks != nil { suggestedLinksSection }

                if !outgoingLinks.isEmpty {
                    section("Outgoing Links", systemImage: "arrow.up.forward", notes: outgoingLinks)
                }
                if !backlinks.isEmpty {
                    section("Linked Mentions", systemImage: "link", notes: backlinks)
                }
                if !unlinkedMentions.isEmpty {
                    unlinkedSection
                }
                if !hasReferences {
                    Text("Nothing links to this note yet, and it links nowhere.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Suggested links
    //
    // These are references you don't have yet, so they sit above the ones you
    // do — same tab, same rhythm, same vocabulary. Accepting one turns it into
    // an outgoing link a few rows below, which is the clearest possible account
    // of what the button did.

    @ViewBuilder
    private var suggestedLinksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("SUGGESTED")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button(action: runSuggestLinks) {
                    if linkSuggestion == .loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Suggest", systemImage: "sparkles").font(.caption2)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(linkSuggestion == .loading || noteText.isEmpty || linkCandidates.isEmpty)
                .help("Find notes in this collection worth linking to")
                // Only once there is somewhere to link to — a tip about
                // linking, shown to someone with a single note, teaches nothing
                // and spends the one time TipKit will interrupt them.
                .popoverTip(linkCandidates.count > 3 ? SuggestLinksTip() : nil)
            }

            switch linkSuggestion {
            case .idle:
                EmptyView()
            case .loading:
                EmptyView()
            case .none:
                Text("No links suggested.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .help(message)
            case .ready(let titles):
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(titles, id: \.self) { title in
                        Button {
                            onInsertLink?(title)
                            // Accepted, so it is a real link now — leaving it in
                            // the list would invite adding it twice.
                            if case .ready(let current) = linkSuggestion {
                                let left = current.filter { $0 != title }
                                linkSuggestion = left.isEmpty ? .none : .ready(left)
                            }
                        } label: {
                            Label("[[\(title)]]", systemImage: "plus")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .disabled(onInsertLink == nil)
                        .help("Link this note to “\(title)”")
                    }
                }
            }
        }
    }

    /// Shared by the button and the **Note ▸ Suggest Links** command.
    private func runSuggestLinks() {
        guard let suggestLinks, !noteText.isEmpty, !linkCandidates.isEmpty else { return }
        linkSuggestion = .loading
        Task {
            do {
                let titles = try await suggestLinks(noteText, linkCandidates)
                // A note the text already links to is not a suggestion — and
                // neither is this note, which a model handed its own title
                // among the candidates will cheerfully propose.
                var taken = Set(MarkdownParsing.wikiLinkTargets(in: noteText).map { $0.lowercased() })
                if let own = fileURL?.deletingPathExtension().lastPathComponent {
                    taken.insert(own.lowercased())
                }
                let fresh = titles.filter { !taken.contains($0.lowercased()) }
                linkSuggestion = fresh.isEmpty ? .none : .ready(fresh)
            } catch {
                linkSuggestion = .failed(error.localizedDescription)
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
