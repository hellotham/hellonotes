//
//  NewEditorHost.swift
//  HelloNotes
//
//  Created by Chris Tham on 17/7/2026.
//
//  Hosts the new in-repo editor (Packages/NotesEditor) behind the
//  "New editor (beta)" toggle while it works toward parity with the old
//  engine — rollout plan in docs/editor-rewrite.md. Bridges the
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
    var onOpenWikiLink: (String) -> Void
    /// Completions for the `[[link` / `#tag` the caret is in (the host's
    /// ranking over the collection's titles, headings, and tags).
    var completions: (EditorCompletionKind, String) -> [WikiCompletion] = { _, _ in [] }
    /// Pasteboard → Markdown intents (image-to-attachment, HTML-to-md).
    var pasteMarkdown: (NSPasteboard) -> String? = { _ in nil }
    /// The provider-backed intelligence service ("Rewrite with AI…").
    var intelligence: IntelligenceService? = nil
    /// Renders block embeds (`![[image]]`, Mermaid) inline. nil disables it.
    var blockRenderer: BlockRenderAdapter? = nil

    @Environment(\.colorScheme) private var colorScheme

    @State private var document: EditorDocument?
    @State private var proxy = EditorProxy()
    @State private var syncTask: Task<Void, Never>?

    // Autocomplete popup state, reported by the editor per caret move.
    @State private var inlineContext: EditorDocument.InlineContext?
    @State private var caretRect: CGRect = .zero

    // "Rewrite with AI…" state: the selection captured when the context-menu
    // item fired (the range, not the text, so Replace targets exactly what
    // was selected even if the preview takes a while).
    @State private var rewriteRange: NSRange?

    var body: some View {
        Group {
            if let document {
                MarkdownEditorView(document: document)
                    .editable(isEditable)
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
                    .overlay(alignment: .topLeading) {
                        let matches = activeCompletions
                        if !matches.isEmpty {
                            WikiLinkCompletionList(matches: matches, onSelect: accept)
                                .offset(x: max(4, caretRect.minX), y: caretRect.maxY + 2)
                        }
                    }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: taskKey) {
            syncTask?.cancel()
            // Case-insensitive title set, matching CollectionWikiLinkResolver.
            let titles = Set(linkCandidates.map { $0.lowercased() })
            let services = EditorServices(
                wikiLinkExists: { title in titles.contains(title.lowercased()) },
                codeHighlighter: CodeHighlighterAdapter(darkMode: colorScheme == .dark),
                blockRenderer: blockRenderer
            )
            let built = await EditorDocument.make(
                text: editor.text,
                theme: EditorTheme(fontSize: fontSize, accent: accent),
                services: services
            )
            guard !Task.isCancelled else { return }
            built.onEdit = { _ in scheduleSync(from: built) }
            document = built
            // A flush (note switch, window resign, quit) must save the
            // document's *current* text, not a snapshot trailing by the
            // sync debounce.
            editor.willFlush = { [weak built] in
                guard let built else { return }
                if built.text != editor.text { editor.text = built.text }
            }
        }
        .onDisappear {
            syncTask?.cancel()
            if let document, document.text != editor.text {
                editor.text = document.text
            }
            editor.willFlush = nil
        }
    }

    /// Rebuild the document when the note or its loaded-from-disk state
    /// changes (open, external reload, conflict resolution — never our own
    /// saves), or when the theme/appearance changes (highlight colors are
    /// appearance-specific).
    private var taskKey: String {
        "\(editor.note?.fileURL.path ?? "")|\(editor.loadRevision)|\(Int(fontSize))|\(colorScheme == .dark ? "d" : "l")"
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
