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
import PhotosUI
import UniformTypeIdentifiers
import MarkdownCore
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
    /// Renders `![[Note]]` transclusion cards and finds the pictures
    /// `![[photo.png]]` names. Supplied rather than taken from the collection
    /// so a host with no collection still draws the rest.
    var embedProvider: CollectionEmbedProvider? = nil
    var onOpenWikiLink: (String) -> Void
    /// What the collection can do with a selected phrase. Surfaced in the
    /// system edit menu — see `SelectionActions.swift` for why there rather
    /// than in a bar of our own.
    var selectionActions: SelectionActions? = nil
    /// What `[[` and `#` can complete to. Ranking is shared with the Mac —
    /// see `WikiCompletions.swift`.
    var completionSource = WikiCompletionSource()
    /// The provider-backed intelligence service, for ghost text. Nil disables it.
    var intelligence: IntelligenceService? = nil
    /// Where a rendered diagram's enlarge button sends its press — the zoom.
    var onDiagramZoom: (DiagramZoom) -> Void = { _ in }
    /// The note's collection — for Insert Image ▸ Choose from Collection…,
    /// which lists its pictures. Nil, and that list says there is none.
    var collection: Collection? = nil

    @AppStorage("attachmentFolder") private var attachmentFolder = "assets"
    @Environment(\.colorScheme) private var colorScheme
    /// Leaving the foreground is the last moment an iPhone promises: the place
    /// in the note is kept then (`keepReadingPosition`).
    @Environment(\.scenePhase) private var scenePhase
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

    /// The note the current `document` was built for, and the `loadRevision`
    /// already reflected in it — the Mac's pair, for the same reason. An
    /// external reload of that *same* note is applied in place (keeping caret
    /// and scroll) instead of rebuilding, so a co-editing app saving
    /// repeatedly no longer tears the editor down on every write.
    @State private var builtNotePath: String?
    @State private var appliedLoadRevision = 0
    /// Which of the model's loads `document`'s text reflects. Every push of
    /// the document back into the model goes through `EditorModel.adopt`,
    /// which refuses a document older than the model's last load — see there.
    @State private var documentLoad: DocumentLoad?

    // Autocomplete popup state, reported by the editor on every caret move.
    @State private var inlineContext: EditorDocument.InlineContext?
    /// The row the arrow keys have chosen in that list, and whether the keys
    /// are the list's at all (`CompletionChoice`).
    @State private var completionChoice = CompletionChoice()
    /// That list, ranked once for the words typed (`CompletionMemo`).
    @State private var completionMemo = CompletionMemo()
    @State private var caretRect: CGRect = .zero

    /// The selection "Rewrite with AI…" was asked for, if any.
    ///
    /// A range rather than a string: `RewriteSelectionView` offers both Replace
    /// and Insert Below, and the second needs to know where the selection
    /// *ended*.
    @State private var rewriteRange: NSRange?

    /// Insert Image: where the caret was when a picture was asked for — a
    /// picker takes the focus, and the link goes where the person was — and
    /// which picker is showing.
    @State private var pictureAsk: PictureAsk?
    @State private var choosingFromCollection = false
    @State private var choosingFromPhotos = false
    @State private var chosenPhoto: PhotosPickerItem?
    @State private var takingPhoto = false

    /// The vault-aware items added to the system edit menu for `selected`.
    ///
    /// Built per selection rather than once, so **Link** appears only when a
    /// note actually matches — an item that cannot apply is worse than a
    /// missing one, because you have to tap it to find out.

    var body: some View {
        Group {
            if let document {
                MarkdownEditorView(document: document)
                    // The editor's own address, not the note's path: two
                    // editors can show one note, and each answers only its
                    // own find bar and menus (`EditorModel.editorID`).
                    .commandBus(editorID: editor.editorID)
                    .editable(isEditable)
                    // Read-only, the editor has no ruler: the measure is the guide.
                    .wrapGuide(isEditable ? wrapGuide : 0)
                    .onLinkTap { tap in
                        switch tap {
                        case .wiki(let target): onOpenWikiLink(target)
                        case .url(let url): ExternalURL.open(url)
                        }
                    }
                    .onPasteImage { pasteImage(into: document) }
                    // Insert Image from the keyboard's bar on iPhone and iPad;
                    // the Format menu asks on the bus, below.
                    .onInsertImage { askForPicture($0) }
                    // A photo from an iPhone or iPad near a Mac — Continuity
                    // Camera, in the editor's context menu.
                    .onImportImage { data, type in importPicture(data, type: type, into: document) }
                    .onPasteMarkdown { smartPaste(into: document) }
                    .selectionMenuItems { selectionActions?.menuItems(for: $0) ?? [] }
                    .proxy(proxy)
                    // The save signal. Editing stopped, so the text has
                    // settled and is worth writing down — into the document's
                    // own buffer, by the load captured with it. `editor` can
                    // already be the next tab's model for the render after a
                    // tab is tapped, while `document` is still this one.
                    .onEndEditing { [documentLoad] in
                        if let documentLoad { landSync(from: document, load: documentLoad) }
                    }
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
                    // The enlarge button on each diagram (`makeServices`
                    // offers it). A click on the diagram itself still edits.
                    .onDiagramZoom { onDiagramZoom($0) }
                    .onInlineContext { context, rect in
                        if inlineContext != context { inlineContext = context }
                        caretRect = rect
                        completionChoice.report(context, revision: document.revision)
                        if context == nil { completionMemo.forget() }
                    }
                    // ↑ and ↓ choose in the list of suggestions, Return or Tab
                    // takes the chosen one, Escape sends the list away — each
                    // only while the list wants it, and otherwise the text's.
                    .completionKeys(CompletionKeyHandler(
                        wants: { completionChoice.wants($0, count: activeCompletions.count) },
                        perform: takeCompletionKey))
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
                            WikiLinkCompletionList(matches: matches, chosen: completionChoice.row,
                                                   onSelect: accept)
                                // Clamped so a caret near the right edge — or
                                // near the bottom, where the keyboard is —
                                // still draws the list on screen.
                                .offset(x: max(4, caretRect.minX), y: caretRect.maxY + 2)
                        }
                    }
                    // Outline → editor is not this host's: the outline posts a
                    // heading's ordinal on `EditorBus.jumpToHeading(editor:)`
                    // (`hnJumpToHeading`), and the editor answers it in the
                    // package, holding it until the surface is ready
                    // (`HeadingJump`). iOS once had the poster and nothing
                    // listening, for want of a handle to scroll the text view.
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
                    // The pictures folder is where a picture is looked for too
                    // (Settings ▸ General ▸ Attachments): the next one asked
                    // for is looked for in the folder set now.
                    .onChange(of: attachmentFolder) { _, folder in
                        (document.blockRenderer as? BlockRenderAdapter)?.place?
                            .update(note: note.fileURL, attachmentFolder: folder)
                    }
                    // **Insert Image.** The Format menu's sources, on this
                    // editor's own address; the keyboard's bar asks above.
                    .onReceive(NotificationCenter.default.publisher(
                        for: EditorBus.insertImage(editor: editor.editorID))) { asked in
                        guard let raw = asked.userInfo?["source"] as? String,
                              let source = EditorImageSource(rawValue: raw) else { return }
                        askForPicture(source)
                    }
                    .sheet(isPresented: $choosingFromCollection) {
                        CollectionPicturePicker(collection: collection, noteTitle: note.title) { file in
                            insertExisting(file, asked: takePictureAsk(), into: document)
                        }
                    }
                    // `.compatible`: the picker hands over a photo every reader
                    // can show, and `PictureFile.storable` makes sure.
                    .photosPicker(isPresented: $choosingFromPhotos, selection: $chosenPhoto,
                                  matching: .images, preferredItemEncoding: .compatible)
                    .onChange(of: chosenPhoto) { _, item in
                        guard let item else { return }
                        chosenPhoto = nil
                        let ask = takePictureAsk()
                        Task { @MainActor in
                            guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                            insertNew({ data }, asked: ask, into: document)
                        }
                    }
                    .takingPhoto(isPresented: $takingPhoto) { photo in
                        let ask = takePictureAsk()
                        if let photo { insertNew(photo, asked: ask, into: document) }
                    }
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
            // The note being left — or its document, for another text size or
            // theme — keeps its place beyond the app (`ReadingPositions`).
            keepReadingPosition()
            // **Leaving a note is a moment the text has settled** — and the one
            // nothing marked. On the Mac the tab bar takes no focus and the
            // text view is only rebound, on iPad the text view is removed
            // without saying so, so editing never ends: what was typed stayed
            // in the document, and coming back the buffer that had never seen
            // it replaced it. It is carried into its own buffer, and saved.
            if let document, let documentLoad, let leaving = documentLoad.settleOnLeaving(document) {
                Task { await leaving.save() }
            }

            let key = EditorDocumentStore.Key(path: note.fileURL.path,
                                              editor: editor.editorID,
                                              fontSize: fontSize,
                                              isDark: colorScheme == .dark,
                                              accent: accentToken)
            let built: EditorDocument
            let load: DocumentLoad
            /// Whether a cached document had its text replaced wholesale on the
            /// way in — see the `resetUndo()` after `document = built`.
            var replacedCachedText = false
            // Under the note's own name, or under the name it had: a note
            // renamed or moved keeps its document (`documentMoved`).
            let kept = documents.document(for: key)
            if let existing = kept ?? documents.documentMoved(to: key) {
                built = existing
                // Where the reader is now, kept just above — never where this
                // document was when its text size or appearance last showed:
                // back to a size or a theme, the view put that old place back
                // and the next keep wrote it over the newer one (§51.72). A
                // document that followed its note to a new name is the live
                // one, and its own place is the newest.
                if kept != nil { existing.readingPosition = ReadingPositions.position(of: note.fileURL) }
                // And the keep on the way in went under the old name, just
                // after the rename had moved the place to the new one: taken
                // back, and kept where the note is now (§51.72).
                else if existing === document, let old = builtNotePath, old != note.fileURL.path {
                    ReadingPositions.keep(nil, of: URL(filePath: old))
                    ReadingPositions.keep(existing.readingPosition, of: note.fileURL)
                }
                // Back to a note whose document the store kept: the two are
                // settled by `DocumentLoad`'s rule. No caret to restore around
                // a replacement here, unlike the reload below: the document is
                // only now being handed to a view, so there is no live text
                // view holding a selection to put back.
                load = documents.load(for: key) ?? DocumentLoad(revision: editor.loadRevision)
                replacedCachedText = load.settleOnReturn(existing, to: editor)
            } else {
                let generation = editor.textGeneration
                let made = await EditorDocument.make(
                    text: editor.text,
                    theme: EditorTheme(fontSize: fontSize, accent: accent),
                    services: makeServices()
                )
                guard !Task.isCancelled else { return }
                // Opened where it was left, last time the app ran — what the
                // view puts back once it has a size (`ReadingPosition.swift`).
                made.readingPosition = ReadingPositions.position(of: note.fileURL)
                // Brought up to date if the note finished loading meanwhile.
                load = DocumentLoad(built: made, at: generation, for: editor)
                documents.insert(made, for: key)
                built = made
            }
            // Built from — or just refreshed to — the buffer and the load the
            // model holds now.
            load.revision = editor.loadRevision
            load.matched(built, editor)
            documents.remember(load, for: key)
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
            // **`onEdit` is nil, and that is the design.**
            //
            // Nothing at all hangs off a keystroke. Not a debounce, not a
            // gate, not a flag — a key is captured, a character is drawn, and
            // the loop ends. Every version of this that kept *something* there
            // ended up running it between two keystrokes, because a timer
            // started by typing expires during typing however long it is set
            // to. And a save taken mid-sentence is stale by the next character,
            // so it was never buying anything to begin with.
            //
            // Saves are pulled instead, by the four events that mean the text
            // has settled: the editor stops being first responder (below), the
            // note is switched away, the app backgrounds, the app quits.
            built.onEdit = nil
            // A flush (note switch, resign, background) must persist the
            // document's *current* text, not a snapshot trailing the debounce.
            //
            // Weak both ways: the closure is kept by the model it names, so a
            // strong capture made each model keep itself alive after its tab
            // closed — holding its note open to anything that asks
            // (`EditorModel.openNoteURLs`).
            let keptAt = note.fileURL
            editor.willFlush = { [weak built, weak model = editor, weak proxy] in
                guard let built, let model else { return }
                load.carry(built, into: model)
                // And where the reader is, with the text: a flush is how ⌘Q
                // reaches a note, and on the Mac a quit changes no scene phase
                // and runs no `onDisappear`, so the place was kept only at the
                // last switch (§51.72).
                proxy?.recordReadingPosition()
                ReadingPositions.keep(built.readingPosition, of: keptAt)
            }
            // The diagrams and the caret, for the zoom that opens on "the one
            // you are in" — from the document's own parse, in its own
            // coordinates. Weak for the same reason: the model outlives this host.
            editor.liveDiagrams = { [weak built] in
                built.map { (diagrams: $0.mermaidDiagrams, caret: $0.selectedRange.location) }
            }
            // Where the note is now — a document kept across a rename or a
            // move found its pictures from the folder the note had left.
            (built.blockRenderer as? BlockRenderAdapter)?.place?
                .update(note: note.fileURL, attachmentFolder: attachmentFolder)
            document = built
            documentLoad = load
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
            settleWithBuffer()
        }
        // The buffer moved some other way while the note is on screen — a
        // write the app made (`EditorModel.applyEdit`).
        .onChange(of: editor.textVersion) { _, _ in settleWithBuffer() }
        .onReceive(NotificationCenter.default.publisher(for: .hnEditorFocusStart)) { note in
            // The title is handing the caret down into the body, in the column
            // it left from (absent for Return/Tab, which commit rather than
            // navigate and so land at the start). The other half of
            // `onCaretEscapeTop`; iOS had neither until this session.
            proxy.focusFirstLine(atX: note.userInfo?["x"] as? CGFloat ?? 0)
        }
        .onDisappear {
            keepReadingPosition()
            // Going away is a moment the text has settled, like leaving for
            // another note: what was typed goes into its own buffer before
            // `willFlush` is unhooked and nothing is left to ask for it — and
            // is saved. A switch of mode takes the host away, and on iPad the
            // text view goes without ending editing, so nothing else would.
            if let document, let documentLoad, let leaving = documentLoad.settleOnLeaving(document) {
                Task { await leaving.save() }
            }
            editor.willFlush = nil
            editor.liveDiagrams = nil
            inlineCompletions.cancel()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { keepReadingPosition() }
        }
        // A completion belongs to the note it was typed in.
        .onChange(of: note.fileURL) { _, _ in
            inlineContext = nil
            completionChoice.leave()
            completionMemo.forget()
            inlineCompletions.cancel()
        }
    }

    /// Keep where the reader is in the note the document was built for —
    /// asked of the view first, which keeps it only as scrolling stops — beyond
    /// the app (`ReadingPositions`).
    private func keepReadingPosition() {
        guard let document, let builtNotePath else { return }
        proxy.recordReadingPosition()
        ReadingPositions.keep(document.readingPosition, of: URL(filePath: builtNotePath))
    }

    // MARK: - Document ↔ model sync

    /// The buffer moved while this document was on screen: settle the two by
    /// `DocumentLoad`'s rule, keeping the caret where a replacement moves text
    /// under it — and putting none where there was none.
    private func settleWithBuffer() {
        // A note switch moves the buffer too, and `taskKey` (the path) is what
        // answers that. Without the identity check a reload landing mid-switch
        // would call `replaceText` on note A's document with note B's text —
        // and note A would then be saved as note B.
        guard let document, let documentLoad, editor.note?.fileURL.path == builtNotePath,
              let replaced = documentLoad.settleWithBuffer(document, editor) else { return }
        // `replaceText` clears the *document's* UndoManager, which is where
        // undo lives on AppKit. UIKit resolves `undoManager` up the responder
        // chain, so its stack still describes the text that was just replaced;
        // undoing into it would apply a patch at offsets that no longer mean
        // anything.
        proxy.resetUndo()
        // Only a caret the document had (`EditorDocument.caret`). One built
        // while its note was still loading — a new tab's — or not clicked into
        // since has none, and the `{0, 0}` put back in its place was a caret
        // arriving: in the front matter, which unfolded, or, moved with the
        // body, on the blank line under it, a line's gap above the heading.
        if let caret = replaced.caret { proxy.setSelection(caret) }
    }

    /// Write the document's text through to its own buffer, and save it.
    ///
    /// No debounce, and no timer of any kind. This is called when editing ends
    /// — a moment the text has settled — never by a keystroke. The buffer is
    /// the one `load` matched the document with, never the host's `editor` of
    /// the moment: the two differ for the render after a tab is tapped. One
    /// O(n) snapshot, at save cadence — and only if the document has been
    /// edited since it last matched the buffer, so a settle with nothing typed
    /// copies nothing and compares nothing; refused if it predates the model's
    /// last load, when there is nothing of the person's to write.
    private func landSync(from document: EditorDocument, load: DocumentLoad) {
        guard let model = load.model, load.carry(document, into: model) else { return }
        // **And write it.** Explicitly, here.
        //
        // `EditorModel.scheduleSave` is a no-op now — a text change must not
        // schedule anything — so setting `model.text` no longer causes a save
        // on its own. Every path into this function is one of the four moments
        // a save is worth taking, so taking it here is the point rather than a
        // side effect. Leaving it implicit is what silently lost the text the
        // first time this was wired.
        Task { await model.save() }
    }

    /// Suggestions for whatever the caret is inside right now, or none — and
    /// none once the list has been sent away with Escape. Ranked once for the
    /// words typed and kept (`CompletionMemo`): this is read each time the
    /// host draws and each time the editor asks whether a key is the list's.
    private var activeCompletions: [WikiCompletion] {
        guard isEditable, !completionChoice.isDismissed, let context = inlineContext else { return [] }
        return completionMemo.matches(for: context) {
            switch context.kind {
            case .wikiLink: completionSource.matches(.wikiLink, query: context.query)
            case .tag: completionSource.matches(.tag, query: context.query)
            }
        }
    }

    /// A key the editor gave the list (`CompletionKeyHandler`): move the
    /// choice, or take the row it is on.
    private func takeCompletionKey(_ key: CompletionKey) {
        let matches = activeCompletions
        guard let row = completionChoice.take(key, count: matches.count), matches.indices.contains(row)
        else { return }
        accept(matches[row])
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
        guard let png = ImagePaste.pasteboardPNG() else { return nil }
        // The name now, for the Markdown the paste returns; the picture
        // written off the main actor (`ImagePaste.write`).
        let placement = ImagePaste.place(nextTo: note.fileURL, subfolder: attachmentFolder, timestamp: .now)
        editor.onFileMaking?(placement.url)
        Task { @MainActor in await finishPlacing(png, as: placement, in: document) }
        return placement.markdown
    }

    /// What follows a new picture's link going in — a pasted one, or one from
    /// the photo library, the camera, or an iPhone near a Mac: the picture
    /// written where its placement says, off the main actor; the link put
    /// right when that name was taken on disk, which the placing did not look
    /// for (`ImagePaste.place`); taken out again when nothing was written —
    /// never a note that shows a picture it does not have; and its
    /// description filled in by on-device Vision. Each rewrite goes through
    /// the document, so it reaches the parser and the undo stack as typing
    /// does, and near the caret: a document-wide search would rewrite an
    /// identical earlier link instead. And the caret is kept where it was in
    /// the text (`EditorProxy.replaceFirst`) — an alt text filled in before it
    /// left it inside the alt text on iOS.
    ///
    /// `inserted` is the text as it went in, when that was more than the link
    /// — a paragraph of its own (`asParagraph`) — so a picture never written
    /// is taken back with its blank lines.
    private func finishPlacing(_ bytes: Data, as placement: ImagePaste.Placement,
                               in document: EditorDocument, inserted: String? = nil) async {
        guard let written = await ImagePaste.write(bytes, to: placement) else {
            takeBack(inserted, or: placement.markdown, in: document)
            return
        }
        if written != placement {
            proxy.replaceFirst(placement.markdown, with: written.markdown, in: document)
        }
        editor.onFileMade?(written.url)
        guard let alt = await VisionAlt.describe(written.url) else { return }
        proxy.replaceFirst(written.markdown, with: "![\(alt)](\(written.linkPath))", in: document)
    }

    /// A picture's link out again — with the blank lines it went in with, when
    /// they are still round it — so the note is as it was.
    private func takeBack(_ inserted: String?, or markdown: String, in document: EditorDocument) {
        if let inserted, inserted != markdown, proxy.replaceFirst(inserted, with: "", in: document) { return }
        proxy.replaceFirst(markdown, with: "", in: document)
    }

    // MARK: - Insert Image

    /// Where a picture was asked for: the caret, in the document on screen
    /// then, as its text stood (`EditorDocument.revision`) — or no caret at
    /// all, for a note only opened (`EditorDocument.caret`).
    private struct PictureAsk {
        let caret: NSRange?
        let document: ObjectIdentifier
        let revision: Int
    }

    /// Insert Image, from the keyboard's bar or the Format menu: the caret
    /// kept — a picker takes the focus, and the link goes where the person
    /// was — and the picker for `source` shown.
    private func askForPicture(_ source: EditorImageSource) {
        guard isEditable, let document else { return }
        pictureAsk = PictureAsk(caret: document.caret, document: ObjectIdentifier(document),
                                revision: document.revision)
        switch source {
        case .collection: choosingFromCollection = true
        case .photoLibrary: choosingFromPhotos = true
        case .camera: takingPhoto = CameraCapture.isAvailable
        }
    }

    /// The ask a chosen picture answers — taken, so the next picture asks
    /// again.
    private func takePictureAsk() -> PictureAsk? {
        defer { pictureAsk = nil }
        return pictureAsk
    }

    /// Where a chosen picture's link goes, asked once the picture is ready:
    /// where the caret was when it was asked for, if the note's text has not
    /// changed since, and where the caret is now if it has — an offset kept
    /// across typing names another place, inside a word. Nil when the note
    /// on screen is not the one it was asked for: the editor is one view for
    /// every note, and the link went into whichever was open by the time a
    /// photo had loaded, at the other's offset — past its end, on the Mac,
    /// an exception.
    ///
    /// And never inside the front matter. A note only opened has no caret —
    /// the view's `{0, 0}` is not one (`EditorDocument.caret`) — and offset 0
    /// is its `---`: a picture put there made the block a rule and a heading,
    /// and its tags and aliases were gone at the next save. With no caret the
    /// picture goes at the end of the note; with one in the front matter, at
    /// the start of the body (`FrontMatter.bodyOffset`).
    private func pictureInsertion(for ask: PictureAsk?, in document: EditorDocument) -> NSRange? {
        guard proxy.shows(document) else { return nil }
        let asked = if let ask, ask.document == ObjectIdentifier(document), ask.revision == document.revision {
            ask.caret
        } else {
            document.caret
        }
        let text = document.text
        let length = (text as NSString).length
        guard let asked else { return NSRange(location: length, length: 0) }
        let range = clamped(asked, in: document)
        let body = FrontMatter.bodyOffset(in: text)
        return range.location < body ? NSRange(location: min(body, length), length: 0) : range
    }

    private func clamped(_ range: NSRange, in document: EditorDocument) -> NSRange {
        let length = (document.text as NSString).length
        guard range.location != NSNotFound else { return NSRange(location: length, length: 0) }
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }

    /// `markdown` in place of `range` as a paragraph of its own
    /// (`asParagraph`), and the focus back with the caret after it, so typing
    /// goes on after the picture. Returns the text as it went in, and where
    /// the link ends in the note — where a rewrite of it looks, not from the
    /// caret, which is past the blank lines after it — or nil when the editor
    /// took nothing, and nothing is to be written for it.
    private func put(_ markdown: String, at range: NSRange,
                     in document: EditorDocument) -> (block: String, linkEnd: Int)? {
        let range = clamped(range, in: document)
        // Inside whatever holds the caret's line — a callout, a quote, a list
        // item — with its markers on every line it adds (`ParagraphInsertion`).
        let placed = ParagraphInsertion.paragraph(markdown, at: range, in: document.text as NSString,
                                                  container: document.paragraphContainer(at: range.location))
        guard proxy.replace(range: placed.range, with: placed.text) else { return nil }
        proxy.focus(at: NSRange(location: placed.range.location + (placed.text as NSString).length, length: 0))
        let before = (placed.text as NSString).range(of: markdown).location
        return (placed.text, placed.range.location + before + (markdown as NSString).length)
    }

    /// A picture put in on purpose is a paragraph of its own: a blank line
    /// before it unless the note starts there or one is there already, and
    /// after it unless the note ends there or one is there. At the caret as it
    /// was, beside text, it was a picture inside that paragraph — drawn from
    /// the end of the line's last word, and off across the page. (A paste
    /// stays at the caret exactly, as a paste does anywhere.) This is the rule
    /// with nothing holding the line; inside a callout, a quote or a list item
    /// the container's markers go on every line too
    /// (`ParagraphInsertion.paragraph`, which `put` uses).
    nonisolated static func asParagraph(_ markdown: String, at range: NSRange, in text: NSString) -> String {
        ParagraphInsertion.paragraph(markdown, at: range, in: text, container: .none).text
    }

    /// A picture from the photo library or the camera: written into the
    /// collection beside the note, as a pasted one is, as `Photo-….jpg` — its
    /// bytes made, and a HEIC photo re-encoded as JPEG, off the main actor
    /// (`PhotoBytes`, `PictureFile.storable`). Put in only once it is ready,
    /// and only into the note it was asked for (`pictureInsertion`); nothing
    /// is written for a note that has been left.
    private func insertNew(_ bytes: @escaping PhotoBytes, asked ask: PictureAsk?,
                           into document: EditorDocument) {
        Task { @MainActor in
            guard let stored = await offMain({ bytes().flatMap { PictureFile.storable($0) } }),
                  let range = pictureInsertion(for: ask, in: document) else { return }
            let placement = ImagePaste.place(nextTo: note.fileURL, subfolder: attachmentFolder,
                                             timestamp: .now, stem: "Photo", ext: stored.ext)
            // The link first: a picture whose link did not go in is a picture
            // no note shows.
            guard let block = put(placement.markdown, at: range, in: document)?.block else {
                ImagePaste.release(placement)
                return
            }
            editor.onFileMaking?(placement.url)
            await finishPlacing(stored.data, as: placement, in: document, inserted: block)
        }
    }

    /// A picture already in the collection: linked where it is, from the
    /// note's folder (`PictureFile.markdown`) — nothing copied — and
    /// described by Vision when it is on this device. One an iCloud vault
    /// keeps online is not downloaded for a description.
    private func insertExisting(_ file: CollectionFile, asked ask: PictureAsk?, into document: EditorDocument) {
        guard let range = pictureInsertion(for: ask, in: document) else { return }
        let markdown = PictureFile.markdown(showing: file.url, in: note.fileURL)
        guard let linkEnd = put(markdown, at: range, in: document)?.linkEnd else { return }
        let url = file.url
        Task { @MainActor in
            guard await FileIO.onScanLane(for: url, { FileIO.isMaterialized(at: url) }),
                  let alt = await VisionAlt.describe(url) else { return }
            // Near where it went in: from the caret, past the blank lines
            // after it, the search missed it and took the first link to the
            // same picture in the note — one put in before and never
            // described.
            proxy.replaceFirst(markdown, with: "![\(alt)]" + markdown.dropFirst(3), in: document, near: linkEnd)
        }
    }

    /// A photo from an iPhone or iPad near a Mac (Continuity Camera): named
    /// now, for the link the editor puts at the caret, by its type
    /// (`PictureFile.fileExtension`), and written as a chosen picture is —
    /// re-encoded off the main actor when it must be.
    private func importPicture(_ data: Data, type: UTType, into document: EditorDocument) -> String? {
        guard isEditable else { return nil }
        let placement = ImagePaste.place(nextTo: note.fileURL, subfolder: attachmentFolder, timestamp: .now,
                                         stem: "Photo", ext: PictureFile.fileExtension(for: type))
        editor.onFileMaking?(placement.url)
        // A paragraph of its own, as a chosen picture is — inside what holds
        // the caret's line. The editor puts it at the caret itself, so a
        // placing that would move it (a caret among a line's markers) is not
        // taken: the paragraph is put as with nothing holding it.
        let caret = clamped(proxy.selection(), in: document)
        let text = document.text as NSString
        let placed = ParagraphInsertion.paragraph(placement.markdown, at: caret, in: text,
                                                  container: document.paragraphContainer(at: caret.location))
        let block = placed.range == caret ? placed.text : Self.asParagraph(placement.markdown, at: caret, in: text)
        Task { @MainActor in
            let stored = await offMain { PictureFile.storable(data) }
            guard let stored, stored.ext == placement.url.pathExtension else {
                ImagePaste.release(placement)
                takeBack(block, or: placement.markdown, in: document)
                return
            }
            await finishPlacing(stored.data, as: placement, in: document, inserted: block)
        }
        return block
    }

    /// A pasted bare URL becomes a Markdown link whose text is upgraded to the
    /// page title once fetched; pasted rich text becomes Markdown. Returns nil
    /// to let the plain-text paste stand, which is the right answer for
    /// anything without meaningful formatting.
    private func smartPaste(into document: EditorDocument) -> String? {
        if let (markdown, url) = SmartPaste.urlLink(fromString: SmartPaste.pasteboardString()) {
            Task { @MainActor in
                guard let title = await SmartPaste.fetchTitle(url) else { return }
                proxy.replaceFirst(markdown, with: "[\(title)](\(url.absoluteString))", in: document)
            }
            return markdown
        }
        return SmartPaste.markdownFromHTML(html: SmartPaste.pasteboardHTML())
    }

    /// Build the editor's wiki-link / code-colour / block-embed services, with
    /// the cross-platform adapters both platforms share.
    private func makeServices() -> EditorServices {
        // `search.linkTargets()` — "all note titles plus their aliases" — and
        // not `collection.notes.map(\.title)`. The two differ on exactly the
        // aliases, and the completion list drawn over this editor already
        // offers them (`ContentView` hands `NoteEditorView` `linkTargets()` for
        // its `WikiCompletionSource`), so with titles alone the editor suggested
        // an alias, you accepted it, and the finished `[[Alias]]` was painted
        // as a broken link. The Mac's host, before there was one host, had
        // always resolved through `linkTargets()`.
        //
        // A snapshot, as the Mac's host took: `wikiLinkExists` is `@Sendable` and
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
            blockRenderer: makeBlockRenderer(),
            // Every diagram gets an enlarge button, which `onDiagramZoom`
            // above answers.
            offersDiagramZoom: true
        )
    }

    /// The block-embed renderer: finds the pictures a note shows, and renders
    /// Mermaid / math / tables / `![[Note]]` transclusions via the app
    /// renderers.
    ///
    /// A Markdown image is a path from the note's folder — then, as it always
    /// was here, the pictures folder beside it. An `![[photo.png]]` is found
    /// as Obsidian finds it, anywhere in the collection
    /// (`CollectionEmbedProvider.pictureURL`); it looked only beside the note
    /// and in its pictures folder, so a vault keeping its pictures in its top
    /// folder — Obsidian's default — or in one folder of their own showed a
    /// line of text for every picture outside the top folder.
    private func makeBlockRenderer() -> BlockRenderAdapter {
        // Where the note is, as of each picture asked for, not as of this
        // renderer's making: a note renamed or moved keeps its document, and
        // the renderer with it (`EditorDocumentStore.documentMoved`), and its
        // pictures were found from the folder it had left.
        let place = NotePlace(note: note.fileURL, attachmentFolder: attachmentFolder)
        let embed = embedProvider
        return BlockRenderAdapter(
            place: place,
            resolve: { picture in
                let spot = place.now
                let noteURL = spot.note
                let noteDir = noteURL.deletingLastPathComponent()
                let subfolder = spot.attachmentFolder
                if picture.byName, let embed {
                    return await embed.pictureURL(for: picture, from: noteURL,
                                                  attachmentFolder: subfolder, waitForList: true)
                }
                let name = picture.path
                let candidates = [
                    noteDir.appendingPathComponent(name),
                    subfolder.isEmpty ? nil : noteDir.appendingPathComponent(subfolder).appendingPathComponent(name),
                ].compactMap { $0 }
                return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            },
            renderMermaid: { source, isDark in
                // Off the main actor: parse, layout and rasterise are
                // computation — 123ms for a 120-node diagram, which was a
                // frozen editor — and nothing in them needs the main thread
                // since the macOS flip became CoreGraphics
                // (`PlatformImageOrient.flippedVertically`).
                await offMain { MermaidDiagramRenderer.standaloneImage(source: source, isDark: isDark) }
            },
            renderMath: { source, isDark in
                await MainActor.run { NoteTranscluder.blockLatexImage(source: source, isDark: isDark) }
            },
            renderTransclusion: { target, isDark in
                await embed?.image(forName: target, isDark: isDark)
            },
            renderTable: { [accent] source, maxWidth, isDark in
                // The person's accent, which colours a link in a cell as it
                // colours one in Preview. The document this renders for is
                // keyed on the accent (`accentToken`), so a new accent is a new
                // document and a new picture.
                await MainActor.run {
                    TableImageRenderer.image(source: source, maxWidth: maxWidth, fontSize: fontSize,
                                             accent: accent, isDark: isDark)
                }
            },
            renderHTML: { source, maxWidth, isDark, keepsTrailingMargin in
                // Through the package's own renderer, which builds the page
                // with `GFMRenderer.page` — the same call Preview makes, with
                // the same palette — so the block is drawn as the fragment
                // Preview would have drawn there.
                let theme = EditorTheme(fontSize: fontSize)
                return await HTMLBlockImageRenderer.image(
                    source: source, maxWidth: maxWidth,
                    base: fontSize,
                    palette: theme.pagePalette(isDark: isDark), isDark: isDark,
                    keepsTrailingMargin: keepsTrailingMargin,
                    // The note's own folder, which is what `NoteEditorPane`
                    // hands Preview. Without it a `<div><img src="pic.png">`
                    // drew the picture in Preview and a broken-image box in
                    // Edit — the same markup, the same page builder, two base
                    // URLs.
                    baseURL: place.now.note.deletingLastPathComponent(),
                    // And what it points at is read as every file a note shows
                    // is: through `FileIO`, off the main actor (§51.64).
                    readFile: { await FileIO.embeddedData(at: $0) })
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

/// Which of an `EditorModel`'s loads an editor document reflects, and when the
/// two last held the same text. A class, so the flush hook, a pending sync and
/// the document store all see a refresh made after they were set up.
@MainActor
final class DocumentLoad {
    var revision: Int
    /// The document's `revision` and the buffer's `textGeneration` when the two
    /// last held the same text, and whose buffer it was. While both still say
    /// so, they still agree — which is how a settle knows there is nothing to
    /// carry, and a tab switch nothing to replace, without comparing the note
    /// with itself: a pass over a bridged string on the main actor, 31–57 ms a
    /// megabyte.
    private var match: (editor: String, document: Int, buffer: Int)?
    /// The document itself, beside its count: counts from two documents can
    /// agree by accident, and a document is carried only into the buffer it
    /// was matched with (`carry`).
    private weak var matchedDocument: EditorDocument?

    init(revision: Int) { self.revision = revision }

    /// The load of a document just built from the buffer as it stood at
    /// `generation` — brought up to date first if the buffer has moved on
    /// since: the note finished loading while it was built, say. Made from what
    /// the buffer said before, the document would go back to the model as the
    /// person's edit the first time they typed, and take the note with it.
    convenience init(built document: EditorDocument, at generation: Int, for model: EditorModel) {
        if model.textGeneration != generation { document.replaceText(model.text) }
        self.init(revision: model.loadRevision)
        matched(document, model)
    }

    /// The document and the model's buffer hold the same text now.
    func matched(_ document: EditorDocument, _ model: EditorModel) {
        match = (model.editorID, document.revision, model.textGeneration)
        matchedDocument = document
        self.model = model
    }

    /// The buffer the document was last matched with — whoever is asking. A
    /// document is carried into *its* buffer: the host can hold one tab's
    /// document beside the next tab's model for a render, so the model at hand
    /// is not the one to ask.
    private(set) weak var model: EditorModel?

    /// Which way a document and its buffer settle once they no longer hold the
    /// same text.
    enum Settle: Equatable {
        /// Neither moved.
        case nothing
        /// The document's text goes into the buffer.
        case carry
        /// The buffer's text goes into the document.
        case replace
    }

    /// **Whichever moved since they last matched wins.** Only the document —
    /// typing not yet carried: carry it. Only the buffer — a write the app made
    /// (`EditorModel.applyEdit`), or a load: put it in the document. Both:
    ///
    /// - **a load wins** if one is involved. A load is the file's text: a
    ///   reload the person chose, or a change taken while nothing typed had
    ///   been carried — which `reconcileWithDisk` prevents by carrying first,
    ///   so it arrives as a conflict instead.
    /// - **otherwise the typing wins.** Every write the app makes carries the
    ///   typing first, so both can only have moved if one did not; the typing
    ///   is on screen and in no undo stack once replaced, where a tag or a
    ///   property can be accepted again.
    ///
    /// Asked of the counts alone — the document's revision, the buffer's
    /// generation, the load. The host compared the two texts to decide, a
    /// bridged string against the buffer on the main actor, and then took the
    /// buffer's side whenever they differed: that is how typing was replaced
    /// on the way back to a tab. A pair this load never matched settles to the
    /// buffer: it belongs to another editor, whose own buffer carried it when
    /// that editor let go.
    func settle(_ document: EditorDocument, _ model: EditorModel) -> Settle {
        guard let match, match.editor == model.editorID, document === matchedDocument else { return .replace }
        switch (match.document != document.revision, match.buffer != model.textGeneration) {
        case (false, false): return .nothing
        case (true, false): return .carry
        case (false, true): return .replace
        case (true, true): return model.loadRevision != revision ? .replace : .carry
        }
    }

    /// The host is leaving this document for another note — one of the moments
    /// the text has settled, and the one nothing marked: the Mac's tab bar
    /// takes no focus and the text view is only rebound, and on iPad the text
    /// view is removed without saying so, so editing never ended. What was
    /// typed is carried into the document's own buffer, and that buffer is
    /// returned to be saved.
    @discardableResult
    func settleOnLeaving(_ document: EditorDocument) -> EditorModel? {
        guard let model, carry(document, into: model) else { return nil }
        return model
    }

    /// The host is back on a document the store kept. Returns whether the
    /// document's text was replaced (so the host resets undo).
    func settleOnReturn(_ document: EditorDocument, to model: EditorModel) -> Bool {
        apply(settle(document, model), document, model)
    }

    /// A document whose text the buffer's has just replaced.
    struct Replacement: Equatable {
        /// Where its caret goes: the one it had, moved with the body
        /// (`caret(_:bodyWas:bodyIs:)`) — or `nil` when it had none. A
        /// document built before its note loaded, or one nobody has clicked
        /// into since, has no caret to keep, and one put back at `{0, 0}`
        /// opened the front matter (`EditorDocument.caret`).
        let caret: NSRange?
    }

    /// The buffer moved while the document was on screen. Returns `nil` when
    /// the document's text was not replaced — nothing moved, or typing was
    /// carried — and otherwise the replacement: the host resets undo, and
    /// puts back the caret it names, if it names one.
    func settleWithBuffer(_ document: EditorDocument, _ model: EditorModel) -> Replacement? {
        let way = settle(document, model)
        guard way == .replace else {
            _ = apply(way, document, model)   // never a replacement here
            return nil
        }
        // Asked before the replace, which takes the caret with the text it
        // was in; the two front matters are a few lines each.
        let caret = document.caret
        let bodyWas = caret == nil ? 0 : FrontMatter.bodyOffset(in: document.text)
        _ = apply(.replace, document, model)   // always one here
        return Replacement(caret: caret.map {
            Self.caret($0, bodyWas: bodyWas, bodyIs: FrontMatter.bodyOffset(in: model.text))
        })
    }

    /// Settle them `way`. Returns whether the document's text was replaced.
    private func apply(_ way: Settle, _ document: EditorDocument, _ model: EditorModel) -> Bool {
        switch way {
        case .nothing:
            return false
        case .carry:
            carry(document, into: model)
            return false
        case .replace:
            document.replaceText(model.text)
            revision = model.loadRevision
            matched(document, model)
            return true
        }
    }

    /// Where a caret goes when the document's text is replaced by the buffer's,
    /// given where the body began before (`old`) and begins now (`new`).
    ///
    /// A write the app makes lands in the front matter — a property, a tag, a
    /// link, a summary — above a caret in the body, so a caret in the body
    /// keeps its place in the body, moved by as much as the front matter grew
    /// or shrank. Kept at its offset, it landed that many characters from
    /// where the person was typing — seven, for a priority of 250 in a note
    /// whose tags the panel wrote back as a list — and the next keystrokes went
    /// into the middle of a word. Asked of the two front matters alone, a few
    /// lines each; a caret in the front matter stays where it was.
    static func caret(_ caret: NSRange, bodyWas old: Int, bodyIs new: Int) -> NSRange {
        guard caret.location >= old else { return caret }
        return NSRange(location: caret.location - old + new, length: caret.length)
    }

    /// Whether neither has changed since they last matched — so they still do.
    func stillMatches(_ document: EditorDocument, _ model: EditorModel) -> Bool {
        guard let match, document === matchedDocument else { return false }
        return match.editor == model.editorID && match.document == document.revision
            && match.buffer == model.textGeneration
    }

    /// Carry the document's text into the model — **if it has been edited
    /// since the two last matched.** A document nobody has typed into has
    /// nothing to give, and its own revision says so for nothing; the snapshot
    /// alone would copy the whole note. Returns `false` when the model refuses
    /// the copy as made from an earlier load (`EditorModel.adopt`), and when
    /// the pair is not the one this load matched.
    ///
    /// That last refusal is the one that matters most. For a moment after a
    /// tab switch the host holds one tab's document beside the next tab's
    /// model, and an end of editing in that moment would carry the first note
    /// into the second's buffer and save it over the second's file — with
    /// every count agreeing, since both are on their first load.
    @discardableResult
    func carry(_ document: EditorDocument, into model: EditorModel) -> Bool {
        guard let match, match.editor == model.editorID, document === matchedDocument else { return false }
        guard match.document != document.revision else { return true }
        guard model.adopt(document.text, fromLoad: revision) else { return false }
        matched(document, model)
        return true
    }
}

private extension View {
    /// The camera, full screen, for Insert Image ▸ Take Photo… on iPhone and
    /// iPad (`CameraCapture`). The Mac takes one with an iPhone or iPad near
    /// it — Continuity Camera, in the editor's context menu.
    func takingPhoto(isPresented: Binding<Bool>, onFinish: @escaping (PhotoBytes?) -> Void) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented) {
            CameraCapture { photo in
                isPresented.wrappedValue = false
                onFinish(photo)
            }
            .ignoresSafeArea()
        }
        #else
        self
        #endif
    }
}
