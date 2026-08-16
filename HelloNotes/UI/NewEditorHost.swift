//
//  NewEditorHost.swift
//  HelloNotes
//
//  Created by Chris Tham on 17/7/2026.
//
//  Hosts the new in-repo editor (Packages/NotesEditor) behind the
//  "New editor (beta)" toggle while it works toward parity with the old
//  engine — rollout plan in docs/implemented.md. Bridges the
//  EditorDocument world (the editor owns the text) to EditorModel's
//  String world (autosave, conflicts) at save granularity: the document
//  syncs its text back after a short idle, never per keystroke.
//

#if os(macOS)
import SwiftUI
import MarkdownEditor

struct NewEditorHost: View {
    let editor: EditorModel
    /// Note titles + aliases, for wiki-link existence styling.
    let linkCandidates: [String]
    var fontSize: CGFloat
    var accent: NSColor
    var isEditable: Bool = true
    /// Vertical guide at N characters while editing; 0 for none (decision 5).
    var wrapGuide: Int = 0
    var onOpenWikiLink: (String) -> Void
    /// Completions for the `[[link` / `#tag` the caret is in (the host's
    /// ranking over the collection's titles, headings, and tags).
    var completions: (EditorCompletionKind, String) -> [WikiCompletion] = { _, _ in [] }
    /// Pasteboard → Markdown intents (image-to-attachment, HTML-to-md).
    var pasteMarkdown: (NSPasteboard) -> String? = { _ in nil }
    /// The provider-backed intelligence service ("Rewrite with AI…").
    var intelligence: IntelligenceService? = nil
    /// What the collection can do with a selected phrase. `nil` hides the
    /// floating bar entirely — see `SelectionActionBar`.
    var selectionActions: SelectionActions? = nil
    /// Renders block embeds (`![[image]]`, Mermaid) inline. nil disables it.
    var blockRenderer: BlockRenderAdapter? = nil

    @Environment(\.colorScheme) private var colorScheme
    /// Documents outlive this view, so tab switches and shell rearrangements
    /// don't re-parse the note or lose the caret.
    @Environment(EditorDocumentStore.self) private var documents

    @State private var document: EditorDocument?
    @State private var proxy = EditorProxy()
    @State private var syncTask: Task<Void, Never>?

    // The note the current `document` was built for, and the EditorModel
    // loadRevision already reflected in it. An external reload of that *same*
    // note is applied in place (preserving caret + scroll) instead of
    // rebuilding, so a co-editing app (Obsidian) saving repeatedly no longer
    // tears the whole editor down — and re-renders every block embed — on
    // every write.
    @State private var builtNotePath: String?
    @State private var appliedLoadRevision = 0

    // Autocomplete popup state, reported by the editor per caret move.
    @State private var inlineContext: EditorDocument.InlineContext?
    @State private var caretRect: CGRect = .zero

    // "Rewrite with AI…" state: the selection captured when the context-menu
    // item fired (the range, not the text, so Replace targets exactly what
    // was selected even if the preview takes a while).
    @State private var rewriteRange: NSRange?

    // The settled selection the floating bar is anchored to, and where to put
    // it. Cleared the moment the selection collapses, so the bar cannot outlive
    // the thing it acts on.
    @State private var selectedRange: NSRange?
    @State private var selectionRect: CGRect = .zero

    var body: some View {
        Group {
            if let document {
                MarkdownEditorView(document: document)
                    .editable(isEditable)
                    // Reading mode has no ruler: the measure is the guide there.
                    .wrapGuide(isEditable ? wrapGuide : 0)
                    // Arrowing up off the first line hands the caret to the
                    // inline title, so title and body read as one flow even
                    // though the title lives in the filename, not the file —
                    // carrying the column, so "up" keeps your place in it.
                    .onCaretEscapeTop { escape in
                        let userInfo: [String: CGFloat]?
                        switch escape {
                        case .vertical(let x): userInfo = ["x": x]
                        case .backward:        userInfo = nil
                        }
                        NotificationCenter.default.post(
                            name: .hnEditorCaretEscapedTop, object: nil, userInfo: userInfo)
                    }
                    .commandBus(documentId: editor.note?.fileURL.path ?? "default")
                    .proxy(proxy)
                    .onLinkTap { tap in
                        switch tap {
                        case .wiki(let target): onOpenWikiLink(target)
                        case .url(let url): NSWorkspace.shared.open(url)
                        }
                    }
                    .onPasteMarkdown { pasteboard in pasteMarkdown(pasteboard) }
                    .onInlineContext { context, rect in
                        if inlineContext != context { inlineContext = context }
                        caretRect = rect
                    }
                    .onRewriteSelection { range in
                        if intelligence != nil { rewriteRange = range }
                    }
                    // Stays in the builder chain (these return the
                    // representable, not `some View`) — a SwiftUI modifier
                    // above it puts the remaining builder calls out of reach.
                    .onSelectionChange { range, rect in
                        // A collapsed selection means the bar's subject is
                        // gone; anything else re-anchors it.
                        if range.length > 0 {
                            selectedRange = range
                            selectionRect = rect
                        } else {
                            selectedRange = nil
                        }
                    }
                    .sheet(isPresented: Binding(
                        get: { rewriteRange != nil },
                        set: { if !$0 { rewriteRange = nil } }
                    )) {
                        if let intelligence, let range = rewriteRange {
                            RewriteSelectionView(
                                intelligence: intelligence,
                                original: document.text(in: range),
                                onReplace: { proxy.replace(range: range, with: $0) },
                                onInsertBelow: { rewritten in
                                    let after = NSRange(location: range.location + range.length, length: 0)
                                    proxy.replace(range: after, with: "\n\n\(rewritten)")
                                }
                            )
                        }
                    }
                    // A selection belongs to the note it was made in. Switching
                    // notes reuses this view, so without this the bar survives
                    // into the next document pointing at a range that means
                    // something else entirely.
                    .onChange(of: editor.note?.fileURL) { _, _ in selectedRange = nil }
                    .overlay(alignment: .topLeading) {
                        let matches = activeCompletions
                        if !matches.isEmpty {
                            WikiLinkCompletionList(matches: matches, onSelect: accept)
                                .offset(x: max(4, caretRect.minX), y: caretRect.maxY + 2)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        // Below the completion list in the stack, because when
                        // both could show — you can select text inside a half
                        // typed `[[link` — the completion is what the keyboard
                        // is currently driving.
                        if let selectionActions, let range = selectedRange, isEditable {
                            SelectionActionBar(
                                text: document.text(in: range),
                                actions: selectionActions,
                                onLink: { target in
                                    proxy.replace(range: range,
                                                  with: NoteEdits.wikiLink(to: target,
                                                                          shownAs: document.text(in: range)))
                                    selectedRange = nil
                                }
                            )
                            .offset(x: max(4, selectionRect.minX), y: selectionRect.maxY + 4)
                        }
                    }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // S3 (docs/layout-architecture.md): the editor fills its container.
        // `MarkdownEditorView` now answers `sizeThatFits` itself, so this is
        // no longer load-bearing on its own — but it is what stops any future
        // child of this Group from sizing the column by its own ideal, which
        // is how the first lines of every note ended up rendered 251pt above
        // the window with no scroll offset able to reach them.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: taskKey) {
            syncTask?.cancel()
            guard let path = editor.note?.fileURL.path else { return }
            let key = EditorDocumentStore.Key(path: path, fontSize: fontSize,
                                              isDark: colorScheme == .dark)

            // Reuse the note's document if it is still around. Building one
            // parses and styles the whole note, so doing it again on every tab
            // switch — or every time the shell rearranges — is the difference
            // between switching notes instantly and waiting for a large one.
            // The cached document also still holds its caret and scroll.
            let built: EditorDocument
            if let existing = documents.document(for: key) {
                built = existing
                // Whatever happened while this note was off screen wins.
                if built.text != editor.text { built.replaceText(editor.text) }
            } else {
                // Case-insensitive title set, matching CollectionWikiLinkResolver.
                let titles = Set(linkCandidates.map { $0.lowercased() })
                let services = EditorServices(
                    wikiLinkExists: { title in titles.contains(title.lowercased()) },
                    codeHighlighter: CodeHighlighterAdapter(darkMode: colorScheme == .dark),
                    blockRenderer: blockRenderer
                )
                let made = await EditorDocument.make(
                    text: editor.text,
                    theme: EditorTheme(fontSize: fontSize, accent: accent),
                    services: services
                )
                guard !Task.isCancelled else { return }
                documents.insert(made, for: key)
                built = made
            }

            // Re-bound every time this host adopts the document, so a document
            // that outlived its previous host never reports edits to a stale
            // editor model.
            built.onEdit = { _ in scheduleSync(from: built) }
            document = built
            builtNotePath = path
            appliedLoadRevision = editor.loadRevision
            // A flush (note switch, window resign, quit) must save the
            // document's *current* text, not a snapshot trailing by the
            // sync debounce.
            editor.willFlush = { [weak built] in
                guard let built else { return }
                if built.text != editor.text { editor.text = built.text }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hnEditorFocusStart)) { note in
            // The title is handing the caret down into the body, in the column
            // it left from (absent for Return/Tab, which commit rather than
            // navigate and so land at the start).
            proxy.focusFirstLine(atX: note.userInfo?["x"] as? CGFloat ?? 0)
        }
        .onChange(of: editor.loadRevision) { _, revision in
            // External reload (Obsidian, git pull, iCloud) of the currently
            // open note: patch the live document in place. A note switch also
            // bumps loadRevision, but taskKey (path) rebuilds for that — the
            // path guard keeps us from patching the wrong document mid-switch.
            guard revision != appliedLoadRevision else { return }
            appliedLoadRevision = revision
            guard let document,
                  editor.note?.fileURL.path == builtNotePath,
                  document.text != editor.text
            else { return }
            let caret = document.selectedRange
            document.replaceText(editor.text)
            proxy.setSelection(caret)
        }
        .onDisappear {
            syncTask?.cancel()
            if let document, document.text != editor.text {
                editor.text = document.text
            }
            editor.willFlush = nil
        }
    }

    /// Rebuild the whole document only when its *identity* changes — a
    /// different note opens, or the theme/appearance changes (highlight colors
    /// are appearance-specific). `loadRevision` is deliberately absent: an
    /// external reload of the same note is applied in place by
    /// `.onChange(of: editor.loadRevision)`, because a full rebuild drops the
    /// caret and scroll position and re-renders every block embed — which,
    /// under live co-editing, turned every remote save into a visible stall.
    private var taskKey: String {
        "\(editor.note?.fileURL.path ?? "")|\(Int(fontSize))|\(colorScheme == .dark ? "d" : "l")"
    }

    private func scheduleSync(from document: EditorDocument) {
        syncTask?.cancel()
        syncTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            // One O(n) snapshot at save cadence — EditorModel's didSet then
            // runs its own debounce + atomic write.
            editor.text = document.text
        }
    }

    // MARK: - Autocomplete

    private var activeCompletions: [WikiCompletion] {
        guard isEditable, let context = inlineContext else { return [] }
        switch context.kind {
        case .wikiLink: return completions(.wikiLink, context.query)
        case .tag: return completions(.tag, context.query)
        }
    }

    private func accept(_ completion: WikiCompletion) {
        guard let context = inlineContext else { return }
        let replacement: String
        switch context.kind {
        case .wikiLink: replacement = "[[\(completion.insert)]]"
        case .tag: replacement = "#\(completion.insert) "
        }
        proxy.replace(range: context.range, with: replacement)
        inlineContext = nil
    }
}

/// The completion domains the host can be asked for.
enum EditorCompletionKind {
    case wikiLink
    case tag
}
#endif
