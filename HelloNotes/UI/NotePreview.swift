//
//  NotePreview.swift
//  HelloNotes
//
//  Preview: the note as a page, built off the main actor from the text as of
//  the last pause in typing.
//
//  It was a `GFMPreview(markdown:)` in `NoteEditorPane`'s body, beside a task
//  keyed on the buffer's version. The initialiser renders the whole page with
//  cmark-gfm, the task walked every line of the note for maths, diagrams and
//  embeds, and both were on the main actor — and the Markdown pane writes the
//  buffer on every keystroke, so in Split mode each key rendered the page
//  twice (once in the redraw the keystroke caused, once when the task's pass
//  landed), walked the note, drew every diagram in it again and reloaded the
//  web view. 700ms of main-thread CPU a keystroke in a 700 KB note, with the
//  outline open beside it (`MainActorBudgetTests`).
//
//  Now the page follows `EditorModel.settledText`, which moves once typing
//  pauses, and is built in the task: the superset pass off the main actor
//  (`PreviewSuperset`, which hops back only to draw a formula or a card, each
//  once), the note → GFM step and cmark-gfm in `offMain`. The web view is
//  handed a page with a number, and loads one it has not seen. With nothing
//  of the note's on screen yet, the page without the superset comes first.
//

import SwiftUI
import MarkdownEditor

struct NotePreview: View {
    let editor: EditorModel
    let note: Note
    let appearance: AppearanceSettings
    /// Renders `![[Note]]` transclusion cards, and says when what they show
    /// may have changed (`CollectionEmbedProvider.revision`).
    let embeds: CollectionEmbedProvider?
    /// Where a diagram's enlarge button sends its press.
    var onDiagramZoom: (DiagramZoom) -> Void = { _ in }
    /// Where a wiki link clicked on the page goes — the handler a tap on one
    /// in Edit reaches, so the two surfaces follow a link to the same note.
    var onOpenWikiLink: (String) -> Void = { _ in }

    /// Which appearance the editor is drawing in, so Preview resolves the same
    /// dynamic colours rather than letting the page guess from
    /// `prefers-color-scheme`.
    @Environment(\.colorScheme) private var colorScheme
    /// Leaving the foreground is the last moment an iPhone promises: the place
    /// on the page is kept then (`keepPlace`).
    @Environment(\.scenePhase) private var scenePhase

    /// Where the reader is on the page, as Preview reports it — as often as
    /// once a frame while scrolling, so in an object no view observes — and
    /// the note it is a place in. Kept beyond the app as the note is left and
    /// as the app leaves the foreground (`ReadingPositions`): an iPhone opens
    /// a note in Preview, and ends a suspended app when it likes, so every
    /// note came back at its top (implemented.md §51.69).
    @State private var place = PagePlace()

    private final class PagePlace {
        var note: URL?
        var offset: Double?

        /// Keep where the reader was on the page of the note it was a place
        /// in, beyond the app (`ReadingPositions`).
        func keep() {
            guard let note else { return }
            ReadingPositions.keep(offset.map { Int($0.rounded()) }, of: note, kind: .previewOffset)
        }
    }

    /// The page on screen, its number (`GFMPreview`'s `pageID`), and the
    /// editor and note it was built for.
    @State private var page: Page?
    @State private var pagesBuilt = 0

    private struct Page {
        let html: String
        let id: Int
        let editor: String
        /// A place on this page is a place in this note — whatever note the
        /// view shows by the time its scroll is reported: the last note's page
        /// stays up until the next one is built, and its momentum was kept as
        /// the next note's place (§51.72).
        let note: URL
    }

    /// Everything the page is built from: the text as of the last pause, how
    /// it is drawn — the theme's size, the accent its links take, light or
    /// dark — and what its embeds resolve to.
    private struct Inputs: Equatable {
        let text: EditorModel.TextVersion?
        let style: GFMPreview.PageStyle
        let isDark: Bool
        let embeds: Int
    }

    var body: some View {
        let isDark = colorScheme == .dark
        // The same theme `EditorHost` hands the live editor, so Preview paints
        // the note in the same ink — and paints no canvas of its own, so the
        // background behind it does not change with the mode.
        let style = GFMPreview.PageStyle(
            theme: EditorTheme(fontSize: appearance.editorFontSize,
                               accent: appearance.editorAccentPlatformColor),
            isDark: isDark)
        // Read here, in this body, so this view alone is redrawn when a card
        // may have changed — not whatever holds it.
        let inputs = Inputs(text: editor.settledText.version, style: style,
                            isDark: isDark, embeds: embeds?.revision ?? 0)
        Group {
            if let page {
                GFMPreview(html: page.html,
                           baseURL: note.fileURL.deletingLastPathComponent(),
                           pageID: page.id)
                    // Heading jumps from this editor's outline, and no other's.
                    .commandBus(editorID: editor.editorID)
                    // Opened where the note was left, last time the app ran,
                    // and the place kept as the reader scrolls.
                    .readingPlace(
                        opening: { [note] in
                            ReadingPositions.position(of: note.fileURL, kind: .previewOffset).map(Double.init)
                        },
                        // The note the page on screen is a page of: this
                        // editor's — under its name now, if it was renamed —
                        // or the last note's, still up until this one's is built.
                        onChange: { [place, shown = page.editor == editor.editorID ? note.fileURL : page.note] offset in
                            place.note = shown
                            place.offset = offset
                        })
                    // The enlarge buttons `PreviewSuperset` puts on each diagram.
                    .onDiagramZoom(onDiagramZoom)
                    // A link clicked on the page, followed as one tapped in
                    // Edit is (`EditorHost`). The web view had no navigation
                    // delegate, so a wiki link went nowhere and a web link
                    // replaced the preview with the page it named
                    // (implemented.md §51.36).
                    .onLinkTap { tap in
                        switch tap {
                        case .wiki(let target): onOpenWikiLink(target)
                        case .url(let url): ExternalURL.open(url)
                        }
                    }
            } else {
                Color.clear
            }
        }
        .task(id: inputs) { await build(inputs) }
        .onChange(of: note.fileURL) { _, _ in keepPlace() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { keepPlace() }
        }
        // And at a quit: on the Mac ⌘Q changes no scene phase and runs no
        // `onDisappear`, so the place was kept only at the last switch
        // (§51.72). The app's own hook for "the app is going".
        .onAppear { TerminationGuard.current?.register(place) { [place] _ in place.keep() } }
        .onDisappear {
            keepPlace()
            TerminationGuard.current?.letGo(place) {}
        }
    }

    /// Keep where the reader was on the page of the note it was a place in,
    /// beyond the app (`ReadingPositions`).
    private func keepPlace() { place.keep() }

    /// Build the page for `inputs`, off the main actor, and show it — unless
    /// the inputs moved on while it was being built.
    ///
    /// **Asynchronous, and that is not incidental.** Maths and transclusion
    /// cards are bitmaps produced by the same renderers the editor uses, and a
    /// transclusion has to *read another note* to draw: on the way into a
    /// view's body that is a file read on the main actor once per embed, which
    /// is the exact hazard `CollectionEmbedProvider`'s own notes describe.
    ///
    /// **With nothing of this note's on screen, the page without the superset
    /// first.** That is cmark-gfm alone, and it is up in a moment; the whole
    /// page waits on every diagram not drawn yet and every embed's read. It
    /// was drawn in the view's initialiser, on the main actor, and built here
    /// the pane stayed empty for all of that — on first showing Preview, on a
    /// change of mode or of the split's orientation, and showed the last
    /// note's page after a switch of tab. Once this note's page is up, a pause
    /// in typing loads the whole page alone, and one no different from the
    /// plain page is not loaded again.
    private func build(_ inputs: Inputs) async {
        let text = editor.settledText.text
        let editorID = editor.editorID
        let noteURL = note.fileURL
        let style = inputs.style
        var plain: String?
        if page?.editor != editorID {
            let html = await offMain { GFMPreview.page(GitHubMarkdown.prepare(text), style: style) }
            guard !Task.isCancelled else { return }
            show(html, for: editorID, note: noteURL)
            plain = html
        }
        let superset = await PreviewSuperset.apply(to: text, isDark: inputs.isDark, embeds: embeds)
        guard !Task.isCancelled else { return }
        // Not again if it is the page on screen: the cards' revision moves
        // with every save in the collection, and most change no card here.
        let shown = plain ?? (page?.editor == editorID ? page?.html : nil)
        let html = await offMain { () -> String? in
            let html = GFMPreview.page(GitHubMarkdown.prepare(superset), style: style)
            return html == shown ? nil : html
        }
        guard !Task.isCancelled, let html else { return }
        show(html, for: editorID, note: noteURL)
    }

    private func show(_ html: String, for editorID: String, note: URL) {
        pagesBuilt &+= 1
        page = Page(html: html, id: pagesBuilt, editor: editorID, note: note)
    }
}
