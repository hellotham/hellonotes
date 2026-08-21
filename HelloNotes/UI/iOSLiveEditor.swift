//
//  iOSLiveEditor.swift
//  HelloNotes
//
//  Hosts the shared TextKit 2 live editor (Packages/NotesEditor) on iOS,
//  mirroring the macOS NewEditorHost: it builds an EditorDocument from the
//  note buffer, feeds the model back at *save* cadence (a debounce, not a
//  keystroke — the bridge is a whole-document snapshot), rebuilds when the
//  note / font / appearance changes, and patches the live document in place
//  when the open note is reloaded from disk. Code-syntax colours are wired
//  via the cross-platform CodeHighlighterAdapter. The block-embed renderer is wired
//  too, but EditorDocument only *consumes* it on macOS for now (the collapse +
//  RenderedBlockFragment image path is `#if canImport(AppKit)`); on iOS block
//  embeds still show their Markdown source until that path is ported to the
//  overlay renderer. See docs/unimplemented.md §6.
//

#if os(iOS)
import SwiftUI
import MarkdownEditor

struct iOSLiveEditor: View {
    @Bindable var editor: EditorModel
    let note: Note
    let collection: Collection?
    let fontSize: CGFloat
    /// The editor's accent — selection, links, the wrap guide.
    ///
    /// `EditorTheme` has taken this since it was written and iOS was passing
    /// `nil`, so the accent the user picked coloured the Mac's editor and left
    /// the iPad's on the system tint. Contrast-corrected on both platforms now;
    /// see `AccentContrast.swift`.
    var accent: PlatformColor? = nil
    /// Prose measure, from Settings. `nil` means "fill the pane", which is what
    /// iOS did unconditionally while the Mac honoured the setting.
    var textWidth: (reading: ReadingWidth, editing: EditorWidth)? = nil
    /// Columns for the wrap guide, 0 for none.
    var wrapGuide: Int = 0
    var onOpenWikiLink: (String) -> Void
    /// What the collection can do with a selected phrase. Surfaced in the
    /// system edit menu — see `SelectionActionBar.swift` for why there rather
    /// than in a bar of our own.
    var selectionActions: SelectionActions? = nil
    /// What `[[` and `#` can complete to. Ranking is shared with the Mac —
    /// see `WikiCompletions.swift`.
    var completionSource = WikiCompletionSource()
    /// The provider-backed intelligence service, for ghost text. Nil disables it.
    var intelligence: IntelligenceService? = nil

    @AppStorage("attachmentFolder") private var attachmentFolder = "assets"
    @Environment(\.colorScheme) private var colorScheme
    /// Documents outlive this view. On iPad this matters most: rotating between
    /// the tall and wide shells re-creates the editor, and without the store
    /// every rotation would re-parse the note and drop the caret.
    @Environment(EditorDocumentStore.self) private var documents
    @State private var document: EditorDocument?
    /// The handle programmatic edits go through: accepting a completion,
    /// offering ghost text, and the outline's scroll-to-heading.
    @State private var proxy = EditorProxy()
    /// Ghost text. Owned per host, so switching notes cancels whatever was in
    /// flight for the note you left.
    @State private var inlineCompletions = InlineCompletionModel()

    /// The debounce that carries the document's text back to the model, and
    /// the exact pair it is going to carry it between.
    ///
    /// The pair is held separately from this view's own `document` / `editor`
    /// because by the time the host is asked to let the debounce go — a tab
    /// switch re-running `.task` — it is already holding the *next* note's
    /// pair, and writing note A's text into note B's model is how a note gets
    /// overwritten with another one's contents.
    @State private var syncTask: Task<Void, Never>?
    @State private var pendingSync: (document: EditorDocument, model: EditorModel)?

    /// The note the current `document` was built for, and the `loadRevision`
    /// already reflected in it — the Mac's pair, for the same reason. An
    /// external reload of that *same* note is applied in place (keeping caret
    /// and scroll) instead of rebuilding, so a co-editing app saving
    /// repeatedly no longer tears the editor down on every write.
    @State private var builtNotePath: String?
    @State private var appliedLoadRevision = 0

    // Autocomplete popup state, reported by the editor on every caret move.
    @State private var inlineContext: EditorDocument.InlineContext?
    @State private var caretRect: CGRect = .zero

    /// The selection "Rewrite with AI…" was asked for, if any.
    ///
    /// A range rather than a string: `RewriteSelectionView` offers both Replace
    /// and Insert Below, and the second needs to know where the selection
    /// *ended*.
    @State private var rewriteRange: NSRange?

    /// The vault-aware items added to the system edit menu for `selected`.
    ///
    /// Built per selection rather than once, so **Link** appears only when a
    /// note actually matches — an item that cannot apply is worse than a
    /// missing one, because you have to tap it to find out.

    var body: some View {
        Group {
            if let document {
                MarkdownEditorView(document: document)
                    .commandBus(documentId: note.fileURL.path)
                    .editable(true)
                    .wrapGuide(wrapGuide)
                    .onLinkTap { tap in
                        switch tap {
                        case .wiki(let target): onOpenWikiLink(target)
                        case .url(let url): UIApplication.shared.open(url)
                        }
                    }
                    .onPasteImage { pasteImage(into: document) }
                    .onPasteMarkdown { smartPaste(into: document) }
                    .selectionMenuItems { selectionActions?.menuItems(for: $0) ?? [] }
                    .proxy(proxy)
                    // ↑ from the first line (or ← from character zero) lands
                    // in the inline title, as it does on the Mac. Posted on the
                    // same bus the Mac's `NewEditorHost` uses, so the pane above
                    // does not have to know which editor it is hosting.
                    .onCaretEscapeTop { escape in
                        var userInfo: [AnyHashable: Any] = [:]
                        if case .vertical(let x) = escape { userInfo["x"] = x }
                        NotificationCenter.default.post(
                            name: .hnEditorCaretEscapedTop, object: nil, userInfo: userInfo)
                    }
                    // The fourth vault action, and the only one that could not
                    // be an `EditorMenuItem`: it opens a sheet rather than
                    // returning a replacement string.
                    .onRewriteSelection { range in
                        if intelligence != nil { rewriteRange = range }
                    }
                    .onInlineContext { context, rect in
                        if inlineContext != context { inlineContext = context }
                        caretRect = rect
                    }
                    // Ghost text. The editor asks whenever the caret settles
                    // somewhere a completion could be drawn; the debounce, the
                    // provider check and the cancellation all live host-side.
                    .onInlineCompletionRequest { context in
                        inlineCompletions.request(context, intelligence: intelligence, proxy: proxy)
                    }
                    .ignoresSafeArea(.container, edges: .bottom)
                    .overlay(alignment: .topLeading) {
                        let matches = activeCompletions
                        if !matches.isEmpty {
                            WikiLinkCompletionList(matches: matches, onSelect: accept)
                                // Clamped so a caret near the right edge — or
                                // near the bottom, where the keyboard is —
                                // still draws the list on screen.
                                .offset(x: max(4, caretRect.minX), y: caretRect.maxY + 2)
                        }
                    }
                    // Outline → editor. The Mac jumps to a heading by posting
                    // its title on the find bus; iOS had the poster (the
                    // inspector's outline) and no listener, because there was
                    // no handle to scroll the text view with. There is now.
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
                    // A selection belongs to the note it was made in. This view
                    // is reused across notes, so without this the sheet could
                    // open onto a range that means something else entirely.
                    .onChange(of: note.fileURL) { _, _ in rewriteRange = nil }
                    .onReceive(NotificationCenter.default.publisher(for: .hnEditorFindQuery)) { notification in
                        guard let query = notification.userInfo?["query"] as? String,
                              !query.isEmpty else { return }
                        let found = (document.text as NSString).range(of: query)
                        guard found.location != NSNotFound else { return }
                        // Caret at the heading, not a selection over it: a
                        // selection would pop the edit menu on arrival.
                        proxy.setSelection(NSRange(location: found.location, length: 0))
                        proxy.scroll(to: found)
                    }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // S3: the editor fills whatever the detail column offers — then the
        // user's Editor width narrows it, exactly as on the Mac. `textWidth`
        // being optional keeps that a host decision: a caller with no settings
        // to consult (a preview, a test) still gets the full pane.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(OptionalMeasure(intent: .editing, fontSize: fontSize, width: textWidth))
        .task(id: taskKey) {
            // Whatever the previous note's debounce was still holding lands
            // now, into the model it was held for. Cancelling it instead — the
            // obvious reading of "restart the sync" — would swallow the last
            // half-second of typing whenever you switch between two open tabs.
            cancelAndLandPendingSync()

            let key = EditorDocumentStore.Key(path: note.fileURL.path,
                                              fontSize: fontSize,
                                              isDark: colorScheme == .dark)
            let built: EditorDocument
            if let existing = documents.document(for: key) {
                built = existing
                // Whatever happened while this note was off screen wins. No
                // caret to restore around this one, unlike the reload below:
                // the document is only now being handed to a view, so there is
                // no live text view holding a selection to put back.
                if built.text != editor.text { built.replaceText(editor.text) }
            } else {
                let made = await EditorDocument.make(
                    text: editor.text,
                    theme: EditorTheme(fontSize: fontSize, accent: accent),
                    services: makeServices()
                )
                guard !Task.isCancelled else { return }
                documents.insert(made, for: key)
                built = made
            }
            // Push edits back to the model at *save* cadence, never per
            // keystroke. `onEdit` fires once per character and `built.text` is
            // a whole-document snapshot, so doing this inline cost two O(n)
            // copies and two O(n) compares per keypress — and, because the
            // model is `@Observable`, invalidated every SwiftUI view reading
            // its text on every character typed. The Mac has debounced this
            // since `NewEditorHost` was written.
            //
            // `[weak built]`, like the `willFlush` below: `onEdit` is the
            // document's *own* callback, so capturing it strongly makes the
            // document retain itself and no eviction from the store can ever
            // free it. It is alive by definition whenever this fires.
            built.onEdit = { [weak built] _ in
                guard let built else { return }
                scheduleSync(from: built, to: editor)
            }
            // A flush (note switch, resign, background) must persist the
            // document's *current* text, not a snapshot trailing the debounce.
            editor.willFlush = { [weak built] in
                guard let built else { return }
                if built.text != editor.text { editor.text = built.text }
            }
            document = built
            builtNotePath = note.fileURL.path
            appliedLoadRevision = editor.loadRevision
        }
        // An external reload (a co-editing app, iCloud, a resolved conflict) of
        // the note that is open: patch the live document in place. `taskKey`
        // deliberately no longer names `loadRevision` — a rebuild drops the
        // caret and the scroll position and re-renders every block embed, which
        // turned every remote save into a visible stall. Same split as the Mac.
        .onChange(of: editor.loadRevision) { _, revision in
            guard revision != appliedLoadRevision else { return }
            appliedLoadRevision = revision
            // A note switch bumps `loadRevision` too, and `taskKey` (the path)
            // is what answers that. Without the identity check a reload landing
            // mid-switch would call `replaceText` on note A's document with
            // note B's text — and note A would then be saved as note B.
            guard let document,
                  editor.note?.fileURL.path == builtNotePath,
                  document.text != editor.text
            else { return }
            let caret = document.selectedRange
            document.replaceText(editor.text)
            // `replaceText` clears the *document's* UndoManager, which is where
            // undo lives on AppKit. UIKit resolves `undoManager` up the
            // responder chain, so its stack still describes the text that was
            // just replaced; undoing into it would apply a patch at offsets
            // that no longer mean anything.
            proxy.resetUndo()
            proxy.setSelection(caret)
        }
        .onDisappear {
            // The debounce must not outlive the host that owns it: land what it
            // was holding rather than dropping it, then make sure the model has
            // the document's current text before `willFlush` is unhooked and
            // nothing is left to ask for it.
            cancelAndLandPendingSync()
            if let document, document.text != editor.text {
                editor.text = document.text
            }
            editor.willFlush = nil
            inlineCompletions.cancel()
        }
        // A completion belongs to the note it was typed in.
        .onChange(of: note.fileURL) { _, _ in
            inlineContext = nil
            inlineCompletions.cancel()
        }
    }

    // MARK: - Document → model sync

    /// Restart the idle timer that carries `document`'s text into `model`.
    ///
    /// Called once per keystroke, so everything expensive has to be on the far
    /// side of the sleep: the snapshot, the compare, and the observation
    /// invalidation that the model's `text` assignment fans out to every view
    /// reading it. `EditorModel.text.didSet` then runs its own debounce and
    /// atomic write, so this is the editor's save cadence, not its edit cadence.
    private func scheduleSync(from document: EditorDocument, to model: EditorModel) {
        syncTask?.cancel()
        pendingSync = (document, model)
        syncTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            landPendingSync()
        }
    }

    /// Write the pending snapshot through, if there is one. One O(n) snapshot,
    /// at save cadence.
    private func landPendingSync() {
        guard let pending = pendingSync else { return }
        pendingSync = nil
        // Snapshotted once: `EditorDocument.text` is `storage.string`, so every
        // read of it copies the whole note.
        let snapshot = pending.document.text
        if pending.model.text != snapshot { pending.model.text = snapshot }
    }

    /// Stop the debounce *without* losing what it was about to write. Every
    /// path that takes the host away from a document goes through here, which
    /// is what keeps the debounce honest: a flush, a tab switch or a teardown
    /// can always read the model and see the last character typed.
    private func cancelAndLandPendingSync() {
        syncTask?.cancel()
        syncTask = nil
        landPendingSync()
    }

    /// Suggestions for whatever the caret is inside right now, or none.
    private var activeCompletions: [WikiCompletion] {
        guard let context = inlineContext else { return [] }
        switch context.kind {
        case .wikiLink: return completionSource.matches(.wikiLink, query: context.query)
        case .tag: return completionSource.matches(.tag, query: context.query)
        }
    }

    /// Replace the whole half-typed construct — markers included, which is what
    /// `InlineContext.range` covers — so accepting `[[No` gives `[[Note]]` and
    /// not `[[No[[Note]]`.
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

    /// Save a pasted image beside the note and return the Markdown to insert,
    /// with the alt text filled in afterwards from on-device vision — the same
    /// two-step the Mac does, so a pasted screenshot is described rather than
    /// left as `![]()`.
    ///
    /// The note stays plain text pointing at a real file; nothing is embedded.
    private func pasteImage(into document: EditorDocument) -> String? {
        guard let markdown = ImagePaste.saveImage(pngData: ImagePaste.pasteboardPNG(),
                                                  nextTo: note.fileURL,
                                                  subfolder: attachmentFolder,
                                                  timestamp: .now) else { return nil }
        guard let rel = markdown.range(of: "](").map({ String(markdown[$0.upperBound...].dropLast()) })
        else { return markdown }

        let assetURL = note.fileURL.deletingLastPathComponent().appendingPathComponent(rel)
        Task { @MainActor in
            guard let alt = await VisionAlt.describe(assetURL) else { return }
            // Rewrite through the document so the edit reaches the parser and
            // the undo stack, exactly as typing would.
            document.replaceFirst(markdown, with: "![\(alt)](\(rel))")
        }
        return markdown
    }

    /// A pasted bare URL becomes a Markdown link whose text is upgraded to the
    /// page title once fetched; pasted rich text becomes Markdown. Returns nil
    /// to let the plain-text paste stand, which is the right answer for
    /// anything without meaningful formatting.
    private func smartPaste(into document: EditorDocument) -> String? {
        if let (markdown, url) = SmartPaste.urlLink(fromString: SmartPaste.pasteboardString()) {
            Task { @MainActor in
                guard let title = await SmartPaste.fetchTitle(url) else { return }
                document.replaceFirst(markdown, with: "[\(title)](\(url.absoluteString))")
            }
            return markdown
        }
        return SmartPaste.markdownFromHTML(html: SmartPaste.pasteboardHTML())
    }

    /// Build the editor's wiki-link / code-colour / block-embed services, using
    /// the same cross-platform adapters as the macOS host.
    private func makeServices() -> EditorServices {
        // `search.linkTargets()` — "all note titles plus their aliases" — and
        // not `collection.notes.map(\.title)`. The two differ on exactly the
        // aliases, and the completion list drawn over this editor already
        // offers them (`iOSContentView` builds its `WikiCompletionSource` from
        // `linkTargets()`), so the editor suggested an alias, you accepted it,
        // and the finished `[[Alias]]` was painted as a broken link. The Mac
        // has always resolved through `linkTargets()`.
        //
        // A snapshot, again as on the Mac: `wikiLinkExists` is `@Sendable` and
        // the styling pass may run from any context that owns the document, so
        // it captures a value rather than reaching back into a `@MainActor`
        // index. The cost is that adding or deleting a note is invisible to an
        // already-built document — which is why `MacContentView` drops every
        // cached document (`documents.forgetAll()`) when the note set changes.
        // The iOS shell's `onChange(of: library.allNotes)` still needs the
        // same call.
        let titles = Set((collection?.search.linkTargets() ?? []).map { $0.lowercased() })
        return EditorServices(
            wikiLinkExists: { titles.contains($0.lowercased()) },
            codeHighlighter: CodeHighlighterAdapter(darkMode: colorScheme == .dark),
            blockRenderer: makeBlockRenderer()
        )
    }

    /// The block-embed renderer: resolves `![[file]]` image embeds relative to
    /// the note (sibling, then the attachments subfolder), and renders Mermaid /
    /// math / tables / `![[Note]]` transclusions via the app renderers.
    private func makeBlockRenderer() -> BlockRenderAdapter {
        let noteDir = note.fileURL.deletingLastPathComponent()
        let subfolder = attachmentFolder.trimmingCharacters(in: .whitespaces)
        let embed = collection?.embedProvider
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
                await MainActor.run { MermaidDiagramRenderer.standaloneImage(source: source, isDark: isDark) }
            },
            renderMath: { source, isDark in
                await MainActor.run { NoteTranscluder.blockLatexImage(source: source, isDark: isDark) }
            },
            renderTransclusion: { target, isDark in
                await embed?.image(forName: target, isDark: isDark)
            },
            renderTable: { source, maxWidth, isDark in
                await MainActor.run { TableImageRenderer.image(source: source, maxWidth: maxWidth, fontSize: fontSize, isDark: isDark) }
            },
            renderInlineMath: { latex, mathFontSize, isDark in
                await MainActor.run {
                    let color: PlatformColor = isDark ? PlatformColor(white: 0.9, alpha: 1) : PlatformColor(white: 0.1, alpha: 1)
                    return MathImageRenderer.image(latex: latex, fontSize: mathFontSize, color: color)
                }
            }
        )
    }

    /// Rebuild the whole document only when its *identity* changes — a
    /// different note opens, or the font/appearance changes (the highlight
    /// colours are appearance-specific). `loadRevision` is deliberately absent,
    /// as on the Mac: an external reload of the same note is applied in place
    /// by `.onChange(of: editor.loadRevision)`, because rebuilding drops the
    /// caret and the scroll position and re-renders every block embed.
    private var taskKey: String {
        "\(note.fileURL.path)|\(Int(fontSize))|\(colorScheme == .dark ? "d" : "l")"
    }
}

#endif
