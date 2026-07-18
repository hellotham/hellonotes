//
//  NoteEditorView.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(macOS)
import SwiftUI
import MarkdownEditor

/// The editor column: hosts HelloNotes' TextKit 2 editor (Packages/NotesEditor)
/// for the open note — live styling, code highlighting, math/diagram/image
/// embeds, autocomplete — routes wiki-link clicks, and shows a references
/// panel beneath the editor.
struct NoteEditorView: View {
    @Bindable var editor: EditorModel

    /// Notes that link to the open note.
    var backlinks: [Note] = []

    /// Notes the open note links out to.
    var outgoingLinks: [Note] = []

    /// Notes that mention the open note by name but don't link it.
    var unlinkedMentions: [Note] = []

    /// Renders `![[Note]]` transclusions to inline images.
    var embedProvider: CollectionEmbedProvider

    /// Git state for the collection — drives the version-history button.
    var git: GitService

    /// Candidate note titles/aliases offered by `[[wiki-link]]` autocomplete.
    var linkCandidates: [String] = []

    /// Existing collection tags (without `#`) offered by `#tag` autocomplete.
    var tagCandidates: [String] = []

    /// Headings of the note with the given name, for `[[Note#heading]]` completion.
    var headingProvider: (String) -> [String] = { _ in [] }

    /// Called when a `[[wiki-link]]` (or plain link) is clicked, with its target.
    var onOpenWikiLink: (String) -> Void = { _ in }

    /// Called to open a note from the references panel.
    var onOpenNote: (Note) -> Void = { _ in }

    /// Called to turn an unlinked mention into a `[[link]]` in that note.
    var onLinkMention: (Note) -> Void = { _ in }
    var onShowMindMap: () -> Void = { }

    @Environment(\.openWindow) private var openWindow
    @Environment(LLMSettings.self) private var llmSettings
    @Environment(AppearanceSettings.self) private var appearance

    /// Folder (relative to the note) where pasted images are saved; empty means
    /// the same folder as the note. Configured in Settings.
    @AppStorage("attachmentFolder") private var attachmentFolder = "assets"

    /// How the editor presents the note. Persisted across launches; macOS
    /// defaults to the live WYSIWYG editor.
    @AppStorage("editorViewMode") private var storedMode = EditorMode.edit.rawValue

    private var mode: EditorMode { EditorMode(rawValue: storedMode) ?? .edit }
    private var modeBinding: Binding<EditorMode> {
        Binding(get: { mode }, set: { storedMode = $0.rawValue })
    }

    /// The intelligence service for the user's chosen provider.
    private var intelligence: IntelligenceService { IntelligenceService(settings: llmSettings) }

    @State private var showMermaid = false
    @State private var showSlides = false
    @State private var showOutline = false
    @State private var showHistory = false
    @State private var showIntelligence = false

    // Editable front-matter properties, seeded per note.
    @State private var properties: [Property] = []
    @State private var showProperties = false

    // Find & replace bar state. The engine owns the search/replace; this view
    // just posts queries and reflects the match count it posts back.
    @State private var showFindBar = false
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var findMatchCount = 0
    @State private var findCurrentIndex = 0

    /// Whole-document derivations shown in the bottom bar. These are O(text)
    /// scans, so they are NOT computed properties: a computed property would
    /// re-scan the entire note on every body evaluation (several ms on large
    /// notes, once per keystroke). Instead they're recomputed off the main
    /// actor, debounced, whenever the text actually changes — see the
    /// `.task(id:)` in `body`.
    private struct DocStats: Equatable {
        var wordCount = 0
        var hasMermaid = false
        var isMarp = false
    }
    @State private var docStats = DocStats()

    /// The new editor's inline block-embed renderer. Resolves `![[file]]`
    /// image embeds relative to the note (sibling, then the attachments
    /// subfolder), and renders ```mermaid fences via the app's Mermaid
    /// renderer. Rebuilt per note; nil when no note is open.
    private var blockRenderAdapter: BlockRenderAdapter? {
        guard let noteDir = editor.note?.fileURL.deletingLastPathComponent() else { return nil }
        let subfolder = attachmentFolder.trimmingCharacters(in: .whitespaces)
        let embed = embedProvider
        return BlockRenderAdapter(
            resolve: { target in
                let name = target.split(separator: "#", maxSplits: 1).first.map(String.init) ?? target
                let candidates = [
                    noteDir.appendingPathComponent(name),
                    subfolder.isEmpty ? nil : noteDir.appendingPathComponent(subfolder).appendingPathComponent(name),
                ].compactMap { $0 }
                return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            },
            renderMermaid: { source, isDark in
                MermaidDiagramRenderer.standaloneImage(source: source, isDark: isDark)
            },
            renderMath: { source, isDark in
                await MainActor.run { NoteTranscluder.blockLatexImage(source: source, isDark: isDark) }
            },
            renderTransclusion: { target, isDark in
                // The app's embed provider renders `![[Note]]` to a titled
                // card (main-actor: it draws with the platform graphics context).
                await MainActor.run { embed.image(forName: target, isDark: isDark) }
            },
            renderTable: { [fontSize = appearance.editorFontSize] source, maxWidth, isDark in
                await MainActor.run { TableImageRenderer.image(source: source, maxWidth: maxWidth, fontSize: fontSize, isDark: isDark) }
            },
            renderInlineMath: { latex, fontSize, isDark in
                await MainActor.run {
                    let color: NSColor = isDark ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.1, alpha: 1)
                    return MathImageRenderer.image(latex: latex, fontSize: fontSize, color: color)
                }
            }
        )
    }

    private nonisolated static func computeStats(for text: String) -> DocStats {
        DocStats(
            wordCount: FrontMatter.body(of: text)
                .split { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }
                .count,
            hasMermaid: !MarkdownParsing.mermaidBlocks(in: text).isEmpty,
            isMarp: MarpSlides.isMarp(text)
        )
    }

    /// Splice the edited properties back into the note's front matter.
    private func applyProperties() {
        editor.text = FrontMatter.applying(properties, to: editor.text)
    }

    /// On-demand Mermaid extraction for the preview sheet (evaluated only when
    /// the sheet is presented, never during ordinary body evaluation).
    private var mermaidSources: [String] {
        MarkdownParsing.mermaidBlocks(in: editor.text)
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

    /// Rank existing tags against a partially-typed tag (for the editor's
    /// `#tag` autocomplete).
    private func tagCompletions(partial: String) -> [WikiCompletion] {
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

                    switch mode {
                    case .edit:     editModeContent
                    case .preview:  previewModeContent
                    case .markdown: sourceEditor
                    case .split:    splitModeContent
                    }

                    Divider()
                    bottomBar
                }
                .navigationTitle(editor.note?.title ?? "")
                .task(id: editor.note?.fileURL) {
                    properties = FrontMatter.properties(in: editor.text)
                    showProperties = false
                }
                .task(id: editor.text) {
                    // Debounce so key-repeat typing doesn't queue a full-text
                    // scan per keystroke; compute off-main so even a
                    // megabyte note never blocks the caret.
                    if docStats != DocStats() {
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !Task.isCancelled else { return }
                    }
                    let text = editor.text
                    docStats = await Task.detached { Self.computeStats(for: text) }.value
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
                .sheet(isPresented: $showMermaid) {
                    MermaidPreviewView(sources: mermaidSources)
                }
                .sheet(isPresented: $showSlides) {
                    SlidesView(
                        markdown: editor.text,
                        title: editor.note?.title ?? "Slides",
                        baseURL: editor.note?.fileURL.deletingLastPathComponent()
                    )
                }
                .sheet(isPresented: $showIntelligence) {
                    IntelligenceView(
                        intelligence: intelligence,
                        noteText: editor.text,
                        existingTags: tagCandidates,
                        linkCandidates: linkCandidates,
                        onInsertSummary: insertSummaryCallout,
                        onAddTags: addTags,
                        onAddLinks: addLinks,
                        onReplaceBody: replaceBody
                    )
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

    // MARK: - Editor modes

    /// The live, editable WYSIWYG editor plus its edit-only chrome: the
    /// find bar, front-matter properties, `[[wiki-link]]`/`#tag` completion
    /// popup, and the references panel.
    @ViewBuilder
    private var editModeContent: some View {
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

        editorHost(isEditable: true)

        if hasReferences {
            Divider()
            referencesPanel
        }
    }

    /// The HelloNotes TextKit 2 editor. `isEditable: false` gives the read-only
    /// Preview mode (no caret, so syntax stays fully rendered).
    private func editorHost(isEditable: Bool) -> some View {
        NewEditorHost(
            editor: editor,
            linkCandidates: linkCandidates,
            fontSize: appearance.editorFontSize,
            accent: appearance.editorAccentNSColor,
            isEditable: isEditable,
            onOpenWikiLink: onOpenWikiLink,
            completions: { kind, query in
                switch kind {
                case .wikiLink:
                    if let hash = query.firstIndex(of: "#") {
                        return headingCompletions(notePart: String(query[..<hash]),
                                                  query: String(query[query.index(after: hash)...]))
                    }
                    return noteCompletions(query: query.trimmingCharacters(in: .whitespaces))
                case .tag:
                    return tagCompletions(partial: query)
                }
            },
            pasteMarkdown: { pasteboard in
                pasteImage(pasteboard) ?? smartPaste(pasteboard)
            },
            intelligence: intelligence,
            blockRenderer: blockRenderAdapter
        )
    }

    /// Read-only rendering: the same editor with no caret, so the note reads as
    /// it will look, with `[[wiki-links]]` still clickable.
    @ViewBuilder
    private var previewModeContent: some View {
        githubPreview
        if hasReferences {
            Divider()
            referencesPanel
        }
    }

    /// GitHub-identical rendered preview: the note (front matter stripped, the
    /// app's wiki-links/embeds/callouts bridged to HTML) is rendered through
    /// cmark-gfm — GitHub's own engine — and shown with GitHub's stylesheet.
    private var githubPreview: some View {
        GFMPreview(
            markdown: GitHubMarkdown.prepare(editor.text),
            baseURL: editor.note?.fileURL.deletingLastPathComponent()
        )
    }

    /// The raw Markdown source in a plain monospaced editor, bound straight to
    /// the note buffer (so edits autosave like everywhere else).
    private var sourceEditor: some View {
        TextEditor(text: $editor.text)
            .font(.system(size: appearance.editorFontSize, design: .monospaced))
            .lineSpacing(2)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Source + preview together, with a draggable divider. Side by side in a
    /// landscape (wide) column and stacked in a portrait (tall) one.
    private var splitModeContent: some View {
        GeometryReader { geo in
            if geo.size.width >= geo.size.height {
                HSplitView {
                    sourceEditor.frame(minWidth: 180)
                    githubPreview.frame(minWidth: 180)
                }
            } else {
                VSplitView {
                    sourceEditor.frame(minHeight: 120)
                    githubPreview.frame(minHeight: 120)
                }
            }
        }
    }

    // MARK: - Smart paste

    /// Persist a pasted image beside the note and return the Markdown to insert.
    /// The alt text is filled in asynchronously from on-device vision.
    private func pasteImage(_ pasteboard: NSPasteboard) -> String? {
        guard let noteURL = editor.note?.fileURL else { return nil }
        guard let markdown = ImagePaste.saveImage(from: pasteboard, nextTo: noteURL,
                                                  subfolder: attachmentFolder, timestamp: .now) else { return nil }

        // markdown == "![](relative/path.png)" — resolve and describe it.
        if let rel = markdown.range(of: "](").map({ String(markdown[$0.upperBound...].dropLast()) }) {
            let assetURL = noteURL.deletingLastPathComponent().appendingPathComponent(rel)
            let placeholder = markdown
            Task { @MainActor in
                if let alt = await VisionAlt.describe(assetURL) {
                    replaceFirst(placeholder, with: "![\(alt)](\(rel))")
                }
            }
        }
        return markdown
    }

    /// Convert a URL to a Markdown link (title filled in asynchronously) or rich
    /// text to Markdown. Returns `nil` to fall through to the default paste.
    private func smartPaste(_ pasteboard: NSPasteboard) -> String? {
        if let (markdown, url) = SmartPaste.urlLink(from: pasteboard) {
            Task { @MainActor in
                if let title = await SmartPaste.fetchTitle(url) {
                    replaceFirst(markdown, with: "[\(title)](\(url.absoluteString))")
                }
            }
            return markdown
        }

        // Rich text → Markdown. The HTML importer is main-thread-only and O(size);
        // `markdownFromHTML` caps the size it will convert, so a huge clipboard
        // falls through to a plain-text paste instead of freezing the editor.
        return SmartPaste.markdownFromHTML(pasteboard)
    }

    /// Replace the first occurrence of `target` in the note body — used to
    /// upgrade a just-pasted placeholder (image alt text, URL title).
    private func replaceFirst(_ target: String, with replacement: String) {
        guard target != replacement, let range = editor.text.range(of: target) else { return }
        editor.text.replaceSubrange(range, with: replacement)
    }

    // MARK: - Intelligence apply handlers

    /// Insert an AI summary as a `> [!summary]` callout at the top of the body
    /// (after any front matter).
    private func insertSummaryCallout(_ text: String) {
        let quoted = text
            .components(separatedBy: "\n")
            .map { "> \($0)" }
            .joined(separator: "\n")
        let callout = "> [!summary] Summary\n\(quoted)\n\n"

        let full = editor.text
        let body = FrontMatter.body(of: full)
        if body.count < full.count {
            let frontMatter = String(full.dropLast(body.count))
            editor.text = frontMatter + callout + body
        } else {
            editor.text = callout + full
        }
    }

    /// Append suggested `#tags` not already present in the note.
    private func addTags(_ tags: [String]) {
        let present = Set(MarkdownParsing.tags(in: editor.text).map { $0.lowercased() })
        let fresh = tags.filter { !present.contains($0.lowercased()) }
        guard !fresh.isEmpty else { return }
        let line = fresh.map { "#\($0)" }.joined(separator: " ")
        editor.text = editor.text.trimmingTrailingNewlines() + "\n\n" + line + "\n"
    }

    /// Replace the note body (keeping front matter) with an expanded version.
    private func replaceBody(_ text: String) {
        let full = editor.text
        let body = FrontMatter.body(of: full)
        if body.count < full.count {
            let frontMatter = String(full.dropLast(body.count))
            editor.text = frontMatter + text
        } else {
            editor.text = text
        }
    }

    /// Append suggested `[[links]]` under a "Related" heading.
    private func addLinks(_ titles: [String]) {
        guard !titles.isEmpty else { return }
        let existing = Set(MarkdownParsing.wikiLinkTargets(in: editor.text).map { $0.lowercased() })
        let fresh = titles.filter { !existing.contains($0.lowercased()) }
        guard !fresh.isEmpty else { return }
        let links = fresh.map { "- [[\($0)]]" }.joined(separator: "\n")
        editor.text = editor.text.trimmingTrailingNewlines() + "\n\n## Related\n\(links)\n"
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

    // MARK: - Bottom bar

    /// Obsidian-style status/action bar pinned to the bottom of the editor, near
    /// the caret. Status sits on the left; actions on the right. The action set
    /// is context-dependent — buttons that don't apply to the current note are
    /// hidden, not just disabled.
    private var bottomBar: some View {
        HStack(spacing: 8) {
            // Status (left). Single-line and truncating, so a narrow window
            // shortens the text instead of wrapping it vertically.
            Text("\(docStats.wordCount) word\(docStats.wordCount == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Divider().frame(height: 11)
            saveStatus.labelStyle(.titleAndIcon).lineLimit(1)
            if git.status.isRepository, !git.status.isClean {
                Divider().frame(height: 11)
                Label("\(git.status.changeCount) changed", systemImage: "pencil.and.list.clipboard")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            modePicker

            Divider().frame(height: 11)

            // Actions (right) — dynamic per context
            barButton("Find & replace (⌘F)", "magnifyingglass", action: toggleFindBar)
                .keyboardShortcut("f", modifiers: .command)
                .disabled(mode != .edit)
            barButton("Edit front-matter properties", "list.bullet.rectangle") { showProperties = true }
            barButton("Outline & statistics", "list.bullet.indent") { showOutline = true }
                .popover(isPresented: $showOutline, arrowEdge: .bottom) {
                    OutlineView(text: editor.text, onSelectHeading: jumpToHeading)
                }
            barButton("Mind map of this note's ideas", "brain") { onShowMindMap() }
            if docStats.isMarp {
                barButton("Present as slides (Marp)", "rectangle.on.rectangle") { showSlides = true }
            }
            if docStats.hasMermaid {
                barButton("Preview Mermaid diagrams", "chart.xyaxis.line") { showMermaid = true }
            }
            if intelligence.isAvailable {
                barButton("Summarize & suggest (\(intelligence.providerName))", "sparkles") { showIntelligence = true }
            }
            if git.status.isRepository {
                barButton("Version history (Git)", "clock.arrow.circlepath") { showHistory = true }
            }
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
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Export")
            barButton("Open this note in a new window", "macwindow.badge.plus") {
                if let url = editor.note?.fileURL { openWindow(value: NoteRef(url)) }
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    /// Segmented Edit / Preview / Markdown / Split switcher.
    private var modePicker: some View {
        Picker("View mode", selection: modeBinding) {
            ForEach(EditorMode.macCases) { m in
                Image(systemName: m.symbol)
                    .help(m.label)
                    .accessibilityLabel(m.label)
                    .tag(m)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("View mode: Edit, Preview, Markdown source, or Split")
    }

    private func barButton(_ help: String, _ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).frame(width: 22, height: 18)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

private extension String {
    func trimmingTrailingNewlines() -> String {
        var s = self
        while let last = s.last, last == "\n" || last == "\r" { s.removeLast() }
        return s
    }
}
#endif
