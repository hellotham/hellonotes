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

    /// Git state for the vault — drives the version-history button.
    var git: GitService

    /// Candidate note titles/aliases offered by `[[wiki-link]]` autocomplete.
    var linkCandidates: [String] = []

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
                        if !wikiMatches.isEmpty {
                            WikiLinkCompletionList(matches: wikiMatches, onSelect: acceptWikiCompletion)
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
                .toolbar {
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
                            OutlineView(text: editor.text)
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

    /// Editor configuration wiring in the HighlighterSwift (code) and SwiftMath
    /// (LaTeX) bridges plus the vault wiki-link resolver, so fenced code blocks
    /// are syntax-highlighted, `$…$` / `$$…$$` math renders natively, and
    /// `[[wiki-links]]` to existing notes are clickable.
    private var configuration: MarkdownEditorConfiguration {
        var config = MarkdownEditorConfiguration.default
        config.services.syntaxHighlighter = Self.syntaxHighlighter
        config.services.latex = Self.latexRenderer
        config.services.wikiLinks = wikiResolver
        return config
    }
}
#endif
