//
//  NoteEditorView.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(macOS)
import SwiftUI
import MarkdownEngine
import MarkdownEngineCodeBlocks
import MarkdownEngineLatex

/// The editor column: hosts MarkdownEngine's live TextKit 2 text view for the
/// open note (with code highlighting and LaTeX), routes wiki-link clicks, and
/// shows a backlinks panel beneath the editor.
struct NoteEditorView: View {
    @Bindable var editor: EditorModel

    /// Notes that link to the open note.
    var backlinks: [Note] = []

    /// Notes the open note links out to.
    var outgoingLinks: [Note] = []

    /// Notes that mention the open note by name but don't link it.
    var unlinkedMentions: [Note] = []

    /// Resolves which `[[wiki-link]]` targets exist (drives link clickability).
    var wikiResolver: VaultWikiLinkResolver

    /// Renders `![[Note]]` transclusions to inline images.
    var embedProvider: VaultEmbedProvider

    /// Git state for the vault — drives the version-history button.
    var git: GitService

    /// Candidate note titles/aliases offered by `[[wiki-link]]` autocomplete.
    var linkCandidates: [String] = []

    /// Existing vault tags (without `#`) offered by `#tag` autocomplete.
    var tagCandidates: [String] = []

    /// Headings of the note with the given name, for `[[Note#heading]]` completion.
    var headingProvider: (String) -> [String] = { _ in [] }

    /// Called when a `[[wiki-link]]` (or plain link) is clicked, with its target.
    var onOpenWikiLink: (String) -> Void = { _ in }

    /// Called to open a note from the references panel.
    var onOpenNote: (Note) -> Void = { _ in }

    /// Called to turn an unlinked mention into a `[[link]]` in that note.
    var onLinkMention: (Note) -> Void = { _ in }

    @Environment(\.openWindow) private var openWindow

    @State private var showMermaid = false
    @State private var showOutline = false
    @State private var showHistory = false

    // Editable front-matter properties, seeded per note.
    @State private var properties: [Property] = []
    @State private var showProperties = false

    // Wiki-link autocomplete state, driven by the engine's inline-selection bus.
    @State private var inlineSelection: InlineSelectionState?
    @State private var caretRect: CGRect = .zero
    @State private var pendingReplacement: InlineReplacementRequest?

    // Find & replace bar state. The engine owns the search/replace; this view
    // just posts queries and reflects the match count it posts back.
    @State private var showFindBar = false
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var findMatchCount = 0
    @State private var findCurrentIndex = 0

    /// Splice the edited properties back into the note's front matter.
    private func applyProperties() {
        editor.text = FrontMatter.applying(properties, to: editor.text)
    }

    private var mermaidSources: [String] {
        MarkdownParsing.mermaidBlocks(in: editor.text)
    }

    /// Suggestions for the active `[[wiki-link]]` the caret is in. Before a `#`
    /// these are note titles/aliases; after a `#` they are headings of the named
    /// note (or this note, for `[[#heading]]`). Empty when not in a wiki-link.
    private var wikiMatches: [WikiCompletion] {
        guard inlineSelection?.kind == .wikiLink,
              let raw = inlineSelection?.selection.placeholder else { return [] }
        // The engine's placeholder spans the whole token, brackets included
        // (e.g. "[[Id]]"); match against just the inner text.
        var inner = raw
        if inner.hasPrefix("[[") { inner.removeFirst(2) }
        if inner.hasSuffix("]]") { inner.removeLast(2) }

        if let hash = inner.firstIndex(of: "#") {
            return headingCompletions(notePart: String(inner[..<hash]),
                                      query: String(inner[inner.index(after: hash)...]))
        }
        return noteCompletions(query: inner.trimmingCharacters(in: .whitespaces))
    }

    private func noteCompletions(query: String) -> [WikiCompletion] {
        let ranked: [String]
        if query.isEmpty {
            ranked = Array(linkCandidates.prefix(8))
        } else {
            ranked = linkCandidates
                .compactMap { title in FuzzyMatch.score(query: query, candidate: title).map { (title, $0) } }
                .sorted { $0.1 > $1.1 }
                .prefix(8)
                .map(\.0)
        }
        // Nothing to offer if the only match is exactly what's already typed.
        if ranked.count == 1, ranked[0].localizedCaseInsensitiveCompare(query) == .orderedSame {
            return []
        }
        return ranked.map { WikiCompletion(label: $0, insert: $0, isHeading: false) }
    }

    private func headingCompletions(notePart: String, query: String) -> [WikiCompletion] {
        let noteName = notePart.trimmingCharacters(in: .whitespaces)
        // Empty note part → headings of the note being edited (`[[#heading]]`).
        let headings = noteName.isEmpty
            ? MarkdownParsing.headings(in: editor.text).map(\.title)
            : headingProvider(noteName)
        let q = query.trimmingCharacters(in: .whitespaces)

        let ranked: [String]
        if q.isEmpty {
            ranked = Array(headings.prefix(8))
        } else {
            ranked = headings
                .compactMap { h in FuzzyMatch.score(query: q, candidate: h).map { (h, $0) } }
                .sorted { $0.1 > $1.1 }
                .prefix(8)
                .map(\.0)
        }
        return ranked.map { heading in
            WikiCompletion(label: heading, insert: "\(noteName)#\(heading)", isHeading: true)
        }
    }

    /// Completions for whichever inline token the caret is in — `[[wiki-links]]`
    /// or `#tags`. Drives the shared completion popup.
    private var activeCompletions: [WikiCompletion] {
        switch inlineSelection?.kind {
        case .wikiLink: return wikiMatches
        case .tag: return tagMatches
        default: return []
        }
    }

    /// Existing-tag suggestions for the `#tag` the caret is typing.
    private var tagMatches: [WikiCompletion] {
        guard inlineSelection?.kind == .tag,
              let raw = inlineSelection?.selection.placeholder else { return [] }
        // The engine's placeholder includes the leading `#`; match on the rest.
        let partial = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw

        let ranked: [String]
        if partial.isEmpty {
            ranked = Array(tagCandidates.prefix(8))
        } else {
            ranked = tagCandidates
                .compactMap { tag in FuzzyMatch.score(query: partial, candidate: tag).map { (tag, $0) } }
                .sorted { $0.1 > $1.1 }
                .prefix(8)
                .map(\.0)
        }
        // Nothing to offer if the only match is exactly what's already typed.
        if ranked.count == 1, ranked[0].localizedCaseInsensitiveCompare(partial) == .orderedSame {
            return []
        }
        return ranked.map { WikiCompletion(label: "#\($0)", insert: $0, isHeading: false) }
    }

    /// Commit whichever completion kind is active.
    private func acceptCompletion(_ completion: WikiCompletion) {
        if inlineSelection?.kind == .tag {
            acceptTagCompletion(completion)
        } else {
            acceptWikiCompletion(completion)
        }
    }

    /// Commit a wiki-link autocomplete choice through the engine's inline
    /// replacement bus, which rewrites the `[[…]]` token and restores the caret.
    private func acceptWikiCompletion(_ completion: WikiCompletion) {
        guard let selection = inlineSelection?.selection,
              let documentId = editor.note?.fileURL.path else { return }
        pendingReplacement = InlineReplacementRequest(
            documentId: documentId,
            selection: selection,
            storageFragment: "[[\(completion.insert)]]",
            isImageEmbedMode: false
        )
        inlineSelection = nil
    }

    /// Commit a `#tag` completion: replace the partial tag with the full tag and
    /// a trailing space (literal mode — no `[[…]]` wrapping).
    private func acceptTagCompletion(_ completion: WikiCompletion) {
        guard let selection = inlineSelection?.selection,
              let documentId = editor.note?.fileURL.path else { return }
        pendingReplacement = InlineReplacementRequest(
            documentId: documentId,
            selection: selection,
            storageFragment: "#\(completion.insert) ",
            isImageEmbedMode: false,
            isLiteralMode: true
        )
        inlineSelection = nil
    }

    var body: some View {
        Group {
            if editor.note == nil {
                ContentUnavailableView(
                    "No Note Selected",
                    systemImage: "doc.text",
                    description: Text("Select a note from the list, or create a new one.")
                )
            } else {
                VStack(spacing: 0) {
                    if editor.hasConflict {
                        conflictBanner
                    }

                    if showFindBar {
                        FindReplaceBar(
                            findText: $findText,
                            replaceText: $replaceText,
                            currentIndex: $findCurrentIndex,
                            matchCount: findMatchCount,
                            onFindChanged: postFindQuery,
                            onNext: { stepMatch(by: 1) },
                            onPrevious: { stepMatch(by: -1) },
                            onReplace: replaceCurrentMatch,
                            onReplaceAll: replaceAllMatches,
                            onClose: closeFindBar
                        )
                    }

                    if !properties.isEmpty || showProperties {
                        PropertiesEditor(properties: $properties, onChange: applyProperties)
                        Divider()
                    }

                    NativeTextViewWrapper(
                        text: $editor.text,
                        pendingInlineReplacement: $pendingReplacement,
                        configuration: configuration,
                        documentId: editor.note?.fileURL.path ?? "default",
                        onPasteImage: pasteImage,
                        onLinkClick: onOpenWikiLink,
                        onCaretRectChange: { caretRect = $0 },
                        onInlineSelectionChange: { inlineSelection = $0 }
                    )
                    .overlay(alignment: .topLeading) {
                        let matches = activeCompletions
                        if !matches.isEmpty {
                            WikiLinkCompletionList(matches: matches, onSelect: acceptCompletion)
                                .offset(
                                    x: max(4, caretRect.minX),
                                    y: caretRect.maxY + 2
                                )
                        }
                    }

                    if hasReferences {
                        Divider()
                        referencesPanel
                    }
                }
                .navigationTitle(editor.note?.title ?? "")
                .task(id: editor.note?.fileURL) {
                    properties = FrontMatter.properties(in: editor.text)
                    showProperties = false
                }
                .onChange(of: editor.note?.fileURL) { _, _ in
                    if showFindBar { closeFindBar() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .hnEditorFindResults)) { note in
                    let count = note.userInfo?["count"] as? Int ?? 0
                    findMatchCount = count
                    if count == 0 {
                        findCurrentIndex = 0
                    } else {
                        findCurrentIndex = min(findCurrentIndex, count - 1)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            toggleFindBar()
                        } label: {
                            Label("Find & Replace", systemImage: "magnifyingglass")
                        }
                        .help("Find & replace (⌘F)")
                        .keyboardShortcut("f", modifiers: .command)
                        .disabled(editor.note == nil)
                    }
                    ToolbarItem(placement: .automatic) {
                        Button {
                            showProperties = true
                        } label: {
                            Label("Properties", systemImage: "list.bullet.rectangle")
                        }
                        .help("Edit front-matter properties")
                        .disabled(editor.note == nil)
                    }
                    ToolbarItem(placement: .automatic) {
                        Button {
                            showOutline = true
                        } label: {
                            Label("Outline & Statistics", systemImage: "list.bullet.indent")
                        }
                        .help("Outline & statistics")
                        .popover(isPresented: $showOutline, arrowEdge: .top) {
                            OutlineView(text: editor.text, onSelectHeading: jumpToHeading)
                        }
                    }
                    ToolbarItem(placement: .automatic) {
                        Menu {
                            Button("Export as HTML…") {
                                if let note = editor.note {
                                    EditorExport.exportHTML(markdown: editor.text, title: note.title)
                                }
                            }
                            Button("Export as PDF…") {
                                if let note = editor.note {
                                    EditorExport.exportPDF(markdown: editor.text, title: note.title)
                                }
                            }
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                    }
                    ToolbarItem(placement: .automatic) {
                        Button {
                            showHistory = true
                        } label: {
                            Label("Version History", systemImage: "clock.arrow.circlepath")
                        }
                        .help("Version history (Git)")
                        .disabled(!git.status.isRepository || editor.note == nil)
                    }
                    ToolbarItem(placement: .automatic) {
                        Button {
                            if let url = editor.note?.fileURL { openWindow(value: url) }
                        } label: {
                            Label("Open in New Window", systemImage: "macwindow.badge.plus")
                        }
                        .help("Open this note in a new window")
                        .disabled(editor.note == nil)
                    }
                    ToolbarItem(placement: .automatic) {
                        Button {
                            showMermaid = true
                        } label: {
                            Label("Diagrams", systemImage: "chart.xyaxis.line")
                        }
                        .help("Preview Mermaid diagrams")
                        .disabled(mermaidSources.isEmpty)
                    }
                    ToolbarItem(placement: .automatic) {
                        saveStatus
                    }
                }
                .sheet(isPresented: $showMermaid) {
                    MermaidPreviewView(sources: mermaidSources)
                }
                .sheet(isPresented: $showHistory) {
                    if let url = editor.note?.fileURL {
                        NoteHistoryView(fileURL: url, git: git) { restored in
                            editor.text = restored
                        }
                    }
                }
            }
        }
    }

    // MARK: - Image paste

    /// Persist a pasted image beside the note and return the Markdown to insert.
    private func pasteImage(_ pasteboard: NSPasteboard) -> String? {
        guard let noteURL = editor.note?.fileURL else { return nil }
        return ImagePaste.saveImage(from: pasteboard, nextTo: noteURL, timestamp: .now)
    }

    // MARK: - Find & replace

    private func toggleFindBar() {
        if showFindBar {
            closeFindBar()
        } else {
            showFindBar = true
            if !findText.isEmpty { postFindQuery() }
        }
    }

    private func closeFindBar() {
        showFindBar = false
        findMatchCount = 0
        findCurrentIndex = 0
        NotificationCenter.default.post(name: .hnEditorClearHighlights, object: nil)
    }

    /// Re-run the search from the top whenever the query changes.
    private func postFindQuery() {
        findCurrentIndex = 0
        guard !findText.isEmpty else {
            findMatchCount = 0
            NotificationCenter.default.post(name: .hnEditorClearHighlights, object: nil)
            return
        }
        NotificationCenter.default.post(
            name: .hnEditorFindQuery,
            object: nil,
            userInfo: ["query": findText, "currentIndex": 0]
        )
    }

    /// Move focus to the next/previous match, wrapping around.
    private func stepMatch(by delta: Int) {
        guard findMatchCount > 0 else { return }
        findCurrentIndex = ((findCurrentIndex + delta) % findMatchCount + findMatchCount) % findMatchCount
        NotificationCenter.default.post(
            name: .hnEditorFindQuery,
            object: nil,
            userInfo: ["query": findText, "currentIndex": findCurrentIndex]
        )
    }

    private func replaceCurrentMatch() {
        guard findMatchCount > 0 else { return }
        NotificationCenter.default.post(
            name: .hnEditorReplaceCurrent,
            object: nil,
            userInfo: ["query": findText, "replacement": replaceText, "currentIndex": findCurrentIndex]
        )
    }

    private func replaceAllMatches() {
        guard findMatchCount > 0 else { return }
        NotificationCenter.default.post(
            name: .hnEditorReplaceAll,
            object: nil,
            userInfo: ["query": findText, "replacement": replaceText]
        )
    }

    // MARK: - Outline navigation

    /// Scroll the editor to a heading by asking the engine to find its title in
    /// the displayed text, then clear the transient highlight shortly after.
    private func jumpToHeading(_ heading: DocumentHeading) {
        showOutline = false
        NotificationCenter.default.post(
            name: .hnEditorFindQuery,
            object: nil,
            userInfo: ["query": heading.title]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            NotificationCenter.default.post(name: .hnEditorClearHighlights, object: nil)
        }
    }

    // MARK: - Conflict banner

    private var conflictBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("This note changed on disk while you were editing.")
                .font(.callout)
            Spacer()
            Button("Reload") { editor.resolveConflictReloading() }
            Button("Keep Mine") { Task { await editor.resolveConflictKeepingMine() } }
                .keyboardShortcut(.defaultAction)
        }
        .padding(8)
        .background(.orange.opacity(0.15))
    }

    // MARK: - References (outgoing / backlinks / unlinked mentions)

    private var hasReferences: Bool {
        !outgoingLinks.isEmpty || !backlinks.isEmpty || !unlinkedMentions.isEmpty
    }

    private var referencesPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !outgoingLinks.isEmpty {
                    referenceSection("Outgoing Links", systemImage: "arrow.up.forward", notes: outgoingLinks)
                }
                if !backlinks.isEmpty {
                    referenceSection("Linked Mentions", systemImage: "link", notes: backlinks)
                }
                if !unlinkedMentions.isEmpty {
                    unlinkedSection
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 200)
        .background(.quaternary.opacity(0.4))
    }

    private func referenceSection(_ title: String, systemImage: String, notes: [Note]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title.uppercased()) · \(notes.count)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(notes) { note in
                Button {
                    onOpenNote(note)
                } label: {
                    Label(note.title, systemImage: systemImage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 1)
            }
        }
    }

    private var unlinkedSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("UNLINKED MENTIONS · \(unlinkedMentions.count)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(unlinkedMentions) { note in
                HStack {
                    Button {
                        onOpenNote(note)
                    } label: {
                        Label(note.title, systemImage: "text.magnifyingglass")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Button("Link") { onLinkMention(note) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                .padding(.vertical, 1)
            }
        }
    }

    // MARK: - Save status

    @ViewBuilder
    private var saveStatus: some View {
        if let error = editor.saveError {
            Label("Save failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help(error)
        } else if editor.isDirty {
            Label("Saving…", systemImage: "pencil.circle")
                .foregroundStyle(.secondary)
        } else {
            Label("Saved", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    // Bridges are stateless and expensive-ish to build, so share one instance.
    private static let syntaxHighlighter = HighlighterSwiftBridge()
    private static let latexRenderer = SwiftMathBridge()
    // Shared so its source→image cache is reused across notes.
    private static let diagramRenderer = MermaidDiagramRenderer()

    /// Editor configuration wiring in the HighlighterSwift (code) and SwiftMath
    /// (LaTeX) bridges plus the vault wiki-link resolver, so fenced code blocks
    /// are syntax-highlighted, `$…$` / `$$…$$` math renders natively, and
    /// `[[wiki-links]]` to existing notes are clickable.
    private var configuration: MarkdownEditorConfiguration {
        var config = MarkdownEditorConfiguration.default
        config.services.syntaxHighlighter = Self.syntaxHighlighter
        config.services.latex = Self.latexRenderer
        config.services.diagrams = Self.diagramRenderer
        config.services.wikiLinks = wikiResolver
        config.services.images = embedProvider
        config.services.bus.findQuery = .hnEditorFindQuery
        config.services.bus.findClearHighlights = .hnEditorClearHighlights
        config.services.bus.findResults = .hnEditorFindResults
        config.services.bus.replaceCurrent = .hnEditorReplaceCurrent
        config.services.bus.replaceAll = .hnEditorReplaceAll
        return config
    }
}
#endif
