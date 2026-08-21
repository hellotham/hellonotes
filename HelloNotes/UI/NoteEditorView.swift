//
//  NoteEditorView.swift
//  HelloNotes
//
//  Cross-platform. It was `#if os(macOS)` end to end, and by the time the pane
//  was extracted the only AppKit left in it was three members nothing called:
//  `blockRenderAdapter`, `pasteImage` and `smartPaste`, all of which moved into
//  `EditorHost` when the hosts merged. What remains is a note's chrome — the
//  find bar, the bottom bar, the mode sheets — which is chrome both platforms
//  want and only one of them had.
//
//  Created by Chris Tham on 11/7/2026.
//

import SwiftUI
import GFMRender
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

    /// Rename the open note from the inline title. The host owns this because
    /// renaming is a *collection* operation — it moves the file and rewrites
    /// every `[[wiki-link]]` pointing at it.
    var onRenameNote: (String) -> Void = { _ in }
    var onShowMindMap: () -> Void = { }

    /// The window's AI commands, so the bottom bar can offer them where a
    /// writer's eyes already are. `nil` when there is no working provider.
    var ai: AIActions? = nil

    /// What the collection can do with a selected phrase — the floating bar.
    var selectionActions: SelectionActions? = nil

    @Environment(\.openWindow) private var openWindow
    @Environment(LLMSettings.self) private var llmSettings
    @Environment(AppearanceSettings.self) private var appearance
    /// The pane this editor was given — the width rules resolve against it.
    @Environment(\.shell) private var shell
    /// Published so a surface in another scene — the mind map — can show what
    /// is being typed rather than what was last saved. Here rather than in each
    /// shell because this view is the one both platforms put in the editor
    /// column, so there is exactly one place the buffer is known.
    @Environment(LiveBuffer.self) private var liveBuffer

    /// Folder (relative to the note) where pasted images are saved; empty means
    /// the same folder as the note. Configured in Settings.
    @AppStorage("attachmentFolder") private var attachmentFolder = "assets"

    /// How the editor presents the note. Persisted across launches; macOS
    /// defaults to the live WYSIWYG editor.
    @AppStorage(EditorMode.storageKey) private var storedMode = EditorMode.edit.rawValue

    private var mode: EditorMode { EditorMode.mode(storedMode) }
    private var modeBinding: Binding<EditorMode> { EditorMode.binding($storedMode) }

    /// The intelligence service for the user's chosen provider.
    private var intelligence: IntelligenceService { IntelligenceService(settings: llmSettings) }

    @State private var showMermaid = false
    @State private var showSlides = false
    @State private var showOutline = false
    @State private var showHistory = false
    /// The whole-note rewrite sheet (Note ▸ Rewrite or Expand Note…). Raised by
    /// a notification, like Find, because the command lives in the menu bar but
    /// the text and the replace path live here.
    @State private var showRewriteNote = false

    // Editable front-matter properties, seeded per note.
    @State private var properties: [Property] = []
    @State private var showProperties = false

    // Find & replace bar state. The engine owns the search/replace; this view
    // just posts queries and reflects the match count it posts back.
    @State private var showReferences = false

    /// Bumped when the caret leaves the top of the note, to pull focus into
    /// the title. A counter, so arrowing up twice in a row still works.
    @State private var titleFocusRequest = CaretHandoff()

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
    @State private var didInitialStats = false


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

    /// The collection's side of `[[link]]` / `#tag` autocomplete. The ranking
    /// is shared with the iPad host — see `WikiCompletions.swift`.
    private var completionSource: WikiCompletionSource {
        WikiCompletionSource(titles: linkCandidates,
                             tags: tagCandidates,
                             headings: headingProvider,
                             currentText: { editor.text })
    }

    var body: some View {
        Group {
            if let note = editor.note {
                // Split out because the modifier chain below defeated the type
                // checker once the pane became a single call — the same reason
                // `iOSContentView` splits its own body in two.
                noteBody(note)

            } else {
                ContentUnavailableView(
                    "No Note Selected",
                    systemImage: "doc.text",
                    description: Text("Select a note from the list, or create a new one.")
                )
            }
        }
    }

    /// The open note: the shared pane, this window's chrome around it, and the
    /// commands and sheets that act on it.
    @ViewBuilder
    private func noteBody(_ note: Note) -> some View {
                VStack(spacing: 0) {
                    // Above the pane rather than inside Edit mode's measure:
                    // the pane is shared now, and a find bar is chrome like the
                    // bottom bar — full width reads better than a column's.
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
                    // Banners, inline title and the four modes are
                    // `NoteEditorPane`, shared with the iPad. They were the
                    // same shape written twice — and had drifted: the Mac's
                    // Markdown mode was corrupting source with typographic
                    // substitution, and the iPad had no downloading banner.
                    NoteEditorPane(
                        editor: editor,
                        note: note,
                        // This view is handed its vocabulary rather than a
                        // collection — it is used by the note *window* too,
                        // which has no shell around it.
                        collection: nil,
                        appearance: appearance,
                        llmSettings: llmSettings,
                        mode: mode,
                        onOpenWikiLink: onOpenWikiLink,
                        selectionActions: selectionActions,
                        onRename: onRenameNote,
                        linkTargets: linkCandidates,
                        embedProvider: embedProvider,
                        completionSource: completionSource)

                    Divider()
                    bottomBar
                }
                // S3: content expands, chrome stays fixed. The mode content
                // (editor, GFM preview, split) is a viewport; the banners and
                // bottom bar are definite-height chrome. Without this clamp the
                // VStack adopts the largest child's ideal height and pushes the
                // whole column past its window.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onReceive(NotificationCenter.default.publisher(for: .hnEditorCaretEscapedTop)) { note in
                    // The caret left the top of the note — catch it in the
                    // title, in the column it left from (absent for ← / ⌃B,
                    // which have no column and mean "the far end").
                    guard appearance.showInlineTitle else { return }
                    titleFocusRequest = titleFocusRequest.next(x: note.userInfo?["x"] as? CGFloat)
                }
                .navigationTitle(editor.note?.title ?? "")
                .task(id: editor.note?.fileURL) {
                    properties = FrontMatter.properties(in: editor.text)
                    showProperties = false
                }
                // The buffer another scene reads. `LiveBuffer` coalesces, so
                // this is not a write per keystroke.
                .onChange(of: editor.text, initial: true) { _, text in
                    liveBuffer.publish(url: editor.note?.fileURL, text: text)
                }
                .task(id: editor.text) {
                    // Debounce so key-repeat typing doesn't queue a full-text
                    // scan per keystroke; compute off-main so even a megabyte
                    // note never blocks the caret. Gate on whether we've computed
                    // once (not on the stats value) so typing into an empty note
                    // — whose stats stay at the default — still debounces.
                    if didInitialStats {
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !Task.isCancelled else { return }
                    }
                    let text = editor.text
                    docStats = await Task.detached { Self.computeStats(for: text) }.value
                    didInitialStats = true
                }
                .onChange(of: editor.note?.fileURL) { _, _ in
                    if showFindBar { closeFindBar() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .hnEditorToggleFind)) { _ in
                    // Edit ▸ Find (⌘F): Find works in the live editor, so switch
                    // to Edit mode first if needed, then toggle the bar.
                    guard editor.note != nil else { return }
                    if mode != .edit { storedMode = EditorMode.edit.rawValue }
                    toggleFindBar()
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
                .modifier(NoteEditorSheets(
                    editor: editor,
                    git: git,
                    showMermaid: $showMermaid,
                    showSlides: $showSlides,
                    showRewriteNote: $showRewriteNote,
                    showHistory: $showHistory,
                    mermaidSources: mermaidSources,
                    intelligence: intelligence,
                    onReplaceBody: replaceBody))
    }

    // MARK: - Inline title


    // MARK: - Text width (decision 5)


    // MARK: - Editor modes


    /// Read-only rendering: the same editor with no caret, so the note reads as
    /// it will look, with `[[wiki-links]]` still clickable.
    @ViewBuilder


    // MARK: - Smart paste



    /// Replace the first occurrence of `target` in the note body — used to
    /// upgrade a just-pasted placeholder (image alt text, URL title).
    private func replaceFirst(_ target: String, with replacement: String) {
        guard target != replacement, let range = editor.text.range(of: target) else { return }
        editor.text.replaceSubrange(range, with: replacement)
    }

    // MARK: - Intelligence apply handlers
    //
    // Only the whole-note replace lives here now. Summaries, tags and links are
    // applied by the shell, because their *review* happens in the inspector —
    // and an apply handler that lives away from the thing offering it is how
    // the same operation ends up implemented twice, slightly differently.

    /// Replace the note body (keeping front matter) with a rewritten version.
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
        hnJumpToHeadingInEditor(titled: heading.title)
    }

    // MARK: - Conflict banner


    // MARK: - Downloading banner


    // MARK: - Save-error banner


    // MARK: - References (outgoing / backlinks / unlinked mentions)

    private var hasReferences: Bool {
        !outgoingLinks.isEmpty || !backlinks.isEmpty || !unlinkedMentions.isEmpty
    }

    /// The same content the inspector's References tab shows, for the shells
    /// and windows that have no inspector rail (below 1400pt, and the
    /// standalone note window). A route, not a second home.
    private var referencesPopover: some View {
        Group {
            if hasReferences {
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
            } else {
                // Same copy the inspector's References tab uses — a note with no
                // links is a state worth showing, not a reason to hide the
                // control. The button used to vanish entirely, which reads as a
                // missing feature rather than an empty one.
                ContentUnavailableView("No References", systemImage: "link",
                                       description: Text("Nothing links to this note yet, and it links nowhere."))
            }
        }
        .frame(width: 320)
        .frame(maxHeight: 360)
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
                .disabled(mode != .edit)
            barButton("Edit front-matter properties", "list.bullet.rectangle") {
                // Seed from the buffer as the popover opens, so this can never
                // show values the inspector has since changed.
                properties = FrontMatter.properties(in: editor.text)
                showProperties = true
            }
            .popover(isPresented: $showProperties, arrowEdge: .bottom) {
                PropertiesEditor(properties: $properties, onChange: applyProperties)
                    .padding(12)
                    .frame(width: 320)
            }
            barButton("Links to and from this note", "link") { showReferences = true }
                .popover(isPresented: $showReferences, arrowEdge: .bottom) {
                    referencesPopover
                }
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
            // The AI actions, as a menu rather than a panel. Every item names
            // where its answer will appear, so pressing one teaches the rail
            // instead of replacing it — which is what the old Intelligence
            // sheet did, and why nobody found their way back to it.
            if let ai {
                Menu {
                    Button("Summarise Note", systemImage: "text.append", action: ai.summarize)
                    Button("Suggest Tags", systemImage: "number", action: ai.suggestTags)
                    Button("Suggest Links", systemImage: "link.badge.plus", action: ai.suggestLinks)
                    Divider()
                    Button("Rewrite or Expand Note…", systemImage: "wand.and.stars", action: ai.rewriteNote)
                    Divider()
                    Text("via \(ai.providerName)")
                } label: {
                    Image(systemName: "sparkles")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Summarise, suggest and rewrite with \(ai.providerName)")
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
            ForEach(EditorMode.platformCases) { m in
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

/// The sheets and commands that act on the open note.
///
/// A `ViewModifier` because the chain in `noteBody` defeated the type checker
/// once the pane became a single call — the same reason `iOSContentView` keeps
/// its parity sheets in one. Splitting a long chain in two is two smaller
/// problems for the compiler.
private struct NoteEditorSheets: ViewModifier {
    @Bindable var editor: EditorModel
    var git: GitService
    @Binding var showMermaid: Bool
    @Binding var showSlides: Bool
    @Binding var showRewriteNote: Bool
    @Binding var showHistory: Bool
    var mermaidSources: [String]
    var intelligence: IntelligenceService
    /// Replace the note's body, keeping its front matter — the rewrite sheet's
    /// only way back into the document.
    var onReplaceBody: (String) -> Void

    func body(content: Content) -> some View {
        content
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
        .onReceive(NotificationCenter.default.publisher(for: .hnShowSlides)) { _ in
            showSlides = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .hnShowMermaid)) { _ in
            showMermaid = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .hnRewriteNote)) { _ in
            showRewriteNote = true
        }
        .sheet(isPresented: $showRewriteNote) {
            RewriteSelectionView(
                intelligence: intelligence,
                // The body, not the file: rewriting a note should not
                // hand the model its own front matter to reword.
                original: FrontMatter.body(of: editor.text),
                onReplace: onReplaceBody,
                onInsertBelow: { editor.text = editor.text.trimmingTrailingNewlines() + "\n\n\($0)\n" },
                subject: .wholeNote
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
