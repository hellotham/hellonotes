//
//  EditorHost.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  The one host for the shared TextKit 2 editor (Packages/NotesEditor).
//
//  There were two — `NewEditorHost` on macOS and `iOSLiveEditor` on iOS — doing
//  the same job: build an `EditorDocument` from the note buffer, feed the model
//  back at *save* cadence (a debounce, not a keystroke, because the bridge is a
//  whole-document snapshot), rebuild when the note / font / appearance changes,
//  and patch the live document in place when the open note is reloaded from
//  disk. Same shape, same comments in places, and not the same code — so they
//  drifted, and this file is the iPad's implementation because on all three
//  differences it was the correct one:
//
//  * `onEdit` captured `built` **strongly** on the Mac — the document retaining
//    itself inside its own callback, which no eviction from the store could
//    ever free. iOS took it `[weak built]` and said why.
//  * `onDisappear` *cancelled* the sync debounce on the Mac and landed it on
//    iOS. Cancelling drops up to half a second of typing on a note switch,
//    which is the one moment it is most likely to be holding something.
//  * Nothing cancelled the inline-completion task on the Mac when the host went
//    away or the note changed.
//
//  What the Mac's had that this needed: `isEditable` (Preview mode has no
//  caret, so syntax stays rendered) and the `.hnEditorFocusStart` handover that
//  brings the caret back down from the inline title.
//
//  Three things genuinely differ per platform and none of them are here: which
//  API opens a URL (`ExternalURL`), whether an undo stack survives a wholesale
//  replacement (`EditorProxy.resetUndo`, a no-op on AppKit), and the
//  representable underneath `MarkdownEditorView`, which is the platform
//  boundary itself.
//

import SwiftUI
import MarkdownEditor

struct EditorHost: View {
    @Bindable var editor: EditorModel
    let note: Note
    /// Every title the vault can be linked to, **aliases included**.
    ///
    /// `search.linkTargets()`, not `notes.map(\.title)`: the two differ on
    /// exactly the aliases, and the completion list already offers them — so
    /// with titles alone the editor suggested an alias, you accepted it, and
    /// the finished `[[Alias]]` was painted as a broken link.
    var linkTargets: [String] = []
    let fontSize: CGFloat
    /// The editor's accent — selection, links, the wrap guide.
    ///
    /// `EditorTheme` has taken this since it was written and iOS was passing
    /// `nil`, so the accent the user picked coloured the Mac's editor and left
    /// the iPad's on the system tint. Contrast-corrected on both platforms now;
    /// see `AccentContrast.swift`.
    var accent: PlatformColor? = nil
    /// Columns for the wrap guide, 0 for none.
    var wrapGuide: Int = 0
    /// Preview mode is this host with no caret — syntax then stays fully
    /// rendered, because nothing is revealing the line the caret is on.
    var isEditable: Bool = true
    /// Renders `![[Note]]` transclusion cards. Supplied rather than taken from
    /// the collection so a host with no collection still draws the rest.
    var embedProvider: CollectionEmbedProvider? = nil
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
                    .editable(isEditable)
                    // Reading mode has no ruler: the measure is the guide there.
                    .wrapGuide(isEditable ? wrapGuide : 0)
                    .onLinkTap { tap in
                        switch tap {
                        case .wiki(let target): onOpenWikiLink(target)
                        case .url(let url): ExternalURL.open(url)
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
                    // **No `.ignoresSafeArea(.container, edges: .bottom)`.**
                    //
                    // That told the text view to extend past the bottom safe
                    // area — which, since the status row moved into a
                    // `safeAreaInset`, means extending *underneath it*. The
                    // caret could then sit behind the word count where it could
                    // not be seen, and scrolling could not rescue it: the view
                    // believed its viewport reached the bottom of the window, so
                    // there was nothing left to scroll. The end of a note was
                    // unreachable from the bottom.
                    //
                    // Chrome and content must not occupy the same points. The
                    // inset reserves the space; respecting it is what makes the
                    // reservation mean anything.
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
                    // No `hnEditorFindQuery` observer here. The editor's own
                    // coordinator already listens on both platforms and answers
                    // with `showMatch(of:index:)`, which honours the
                    // `currentIndex` the find bar sends and *selects* the match.
                    // A second listener stood here that ignored the index, took
                    // `range(of:)` — always the first match — and set a
                    // zero-length selection: two observers on one channel, in
                    // undefined order, so Find Next appeared to advance the
                    // counter while the caret snapped back to match 1, nothing
                    // was highlighted, and Replace (which requires a non-empty
                    // selection) became a no-op.
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // S3: the editor fills whatever the detail column offers. The user's
        // measure is applied by `NoteEditorPane`, around the mode switch, so
        // that every mode gets the same column — measuring here as well would
        // put the decision in two places, and two places is how Preview came to
        // be measured differently from Edit.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: taskKey) {
            // Whatever the previous note's debounce was still holding lands
            // now, into the model it was held for. Cancelling it instead — the
            // obvious reading of "restart the sync" — would swallow the last
            // half-second of typing whenever you switch between two open tabs.
            cancelAndLandPendingSync()

            let key = EditorDocumentStore.Key(path: note.fileURL.path,
                                              fontSize: fontSize,
                                              isDark: colorScheme == .dark,
                                              accent: accentToken)
            let built: EditorDocument
            /// Whether a cached document had its text replaced wholesale on the
            /// way in — see the `resetUndo()` after `document = built`.
            var replacedCachedText = false
            if let existing = documents.document(for: key) {
                built = existing
                // Whatever happened while this note was off screen wins. No
                // caret to restore around this one, unlike the reload below:
                // the document is only now being handed to a view, so there is
                // no live text view holding a selection to put back.
                if built.text != editor.text {
                    built.replaceText(editor.text)
                    replacedCachedText = true
                }
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
                // **The whole of what a keystroke costs outside the text view.**
                //
                // It used to start a 500ms debounce here, which then wrote the
                // model, whose `didSet` started a *second* 600ms debounce to
                // save. Both fire in the middle of ordinary typing — a person
                // pausing to think crosses half a second constantly — so the
                // "debounced" work was landing between keystrokes, and on a
                // File Provider volume the save could block the main thread for
                // as long as the provider wanted.
                //
                // Now: mark the burst, and ask to be told when it ends. One
                // clock, and the sync is the only thing hung off it.
                TypingGate.shared.keystroke()
                TypingGate.shared.onIdle("editor-sync") { [weak built] in
                    guard let built else { return }
                    landSync(from: built, to: editor)
                }
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

            // The same rule the reload below applies, and this path was missing
            // it: `replaceText` clears the *document's* UndoManager, which is
            // where undo lives on AppKit — but UIKit resolves `undoManager` up
            // the responder chain, so the window's stack survives the text
            // view and still describes the text that was just replaced.
            // Undoing into it applies a patch at offsets that no longer mean
            // anything, silently corrupting the note.
            //
            // After `document = built`, not beside the `replaceText` above:
            // the proxy reaches a text view only once the representable has
            // been built from this document, so calling it there would be a
            // no-op — which is what makes this the harder half of the pair.
            if replacedCachedText {
                await Task.yield()
                proxy.resetUndo()
            }
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
        .onReceive(NotificationCenter.default.publisher(for: .hnEditorFocusStart)) { note in
            // The title is handing the caret down into the body, in the column
            // it left from (absent for Return/Tab, which commit rather than
            // navigate and so land at the start). The other half of
            // `onCaretEscapeTop`; iOS had neither until this session.
            proxy.focusFirstLine(atX: note.userInfo?["x"] as? CGFloat ?? 0)
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
    /// Write the document's text through to the model.
    ///
    /// No debounce of its own any more: `TypingGate` decides when this may run,
    /// and it is the only thing that does. A second timer here is precisely how
    /// work ended up landing between two keystrokes.
    private func landSync(from document: EditorDocument, to model: EditorModel) {
        pendingSync = (document, model)
        landPendingSync()
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

    /// End the typing burst early *without* losing what it was about to write.
    ///
    /// Every path that takes the host away from a document goes through here —
    /// a flush, a tab switch, a teardown — and each of them is exactly "the
    /// user has stopped typing", so they end the burst rather than working
    /// around it. `becameIdle` runs the pending sync along with everything else
    /// that was waiting, which is why leaving a note can never strand the last
    /// character typed.
    private func cancelAndLandPendingSync() {
        syncTask?.cancel()
        syncTask = nil
        TypingGate.shared.becameIdle()
        landPendingSync()
    }

    /// Suggestions for whatever the caret is inside right now, or none.
    private var activeCompletions: [WikiCompletion] {
        guard isEditable, let context = inlineContext else { return [] }
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
            // the undo stack, exactly as typing would. `near:` is the caret —
            // the placeholder was just inserted there, and a document-wide
            // search would rewrite an identical earlier embed instead.
            document.replaceFirst(markdown, with: "![\(alt)](\(rel))",
                                  near: proxy.selection().location)
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
                document.replaceFirst(markdown, with: "[\(title)](\(url.absoluteString))",
                                      near: proxy.selection().location)
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
        // already-built document — which is why `ContentView` drops every
        // cached document (`documents.forgetAll()`) from its
        // `onChange(of: library.allNotes)`. One shell, one call; this used to
        // name `MacContentView` and say the iOS shell "still needs the same
        // call", and both of those files are gone.
        let titles = Set(linkTargets.map { $0.lowercased() })
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
            renderHTML: { source, maxWidth, isDark, keepsTrailingMargin in
                // Through the package's own renderer, which builds the page
                // with `GFMRenderer.page` — the same call Preview makes, with
                // the same palette — so the block is drawn as the fragment
                // Preview would have drawn there.
                let theme = EditorTheme(fontSize: fontSize)
                return await HTMLBlockImageRenderer.image(
                    source: source, maxWidth: maxWidth,
                    fontScale: Double(fontSize / 16),
                    palette: theme.pagePalette(isDark: isDark), isDark: isDark,
                    keepsTrailingMargin: keepsTrailingMargin,
                    // The note's own folder, which is what `NoteEditorPane`
                    // hands Preview. Without it a `<div><img src="pic.png">`
                    // drew the picture in Preview and a broken-image box in
                    // Edit — the same markup, the same page builder, two base
                    // URLs.
                    baseURL: noteDir)
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
        "\(note.fileURL.path)|\(Int(fontSize))|\(colorScheme == .dark ? "d" : "l")|\(accentToken)"
    }

    /// The accent, as a value a cache key can name.
    ///
    /// The key used to be path + font size + appearance only, while the theme
    /// it builds takes the accent too — so changing the accent, or toggling
    /// Increase Contrast, re-ran nothing and returned the document built with
    /// the old one. Link, wiki-link, tag, footnote, list-marker and highlight
    /// colours all stayed on the previous accent until the note fell out of the
    /// 8-entry cache. "A cache key must name everything the cached value
    /// depends on" (CLAUDE.md) — this is the part it did not name.
    private var accentToken: String {
        guard let accent else { return "-" }
        #if canImport(AppKit)
        let rgb = accent.usingColorSpace(.sRGB) ?? accent
        return String(format: "%.3f,%.3f,%.3f",
                      rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        accent.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%.3f,%.3f,%.3f", r, g, b)
        #endif
    }
}
