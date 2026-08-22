//
//  NoteEditorPane.swift
//  HelloNotes
//
//  Created by Chris Tham on 21/8/2026.
//
//  One note, in whichever of the four view modes is selected, plus the two
//  banners that belong to the buffer rather than to the window: an edit
//  conflict and a failed save.
//
//  Extracted from `iOSContentView` so a second window can show a note without a
//  second implementation of what showing a note means. The Mac has had
//  `NoteWindowView` since July — a standalone window per note, with its own
//  `EditorModel` so its autosaves are independent — and "Open in New Window"
//  sat in the File menu on both platforms, offered by `AppCommands` and wired
//  to `nil` on iOS. iPadOS has supported multiple scenes for years and the
//  app's generated scene manifest already declares
//  `UIApplicationSupportsMultipleScenes`; what was missing was a view to put in
//  the second scene.
//

import SwiftUI
import MarkdownEditor

struct NoteEditorPane: View {
    @Bindable var editor: EditorModel
    let note: Note
    /// The note's *own* collection, never the focused one: `[[link]]` and `#tag`
    /// completion has to be asked of the vocabulary the note lives in.
    let collection: Collection?
    let appearance: AppearanceSettings
    let llmSettings: LLMSettings
    let mode: EditorMode

    var onOpenWikiLink: (String) -> Void
    var selectionActions: SelectionActions? = nil
    /// Renaming from the inline title. Nil hides the affordance's effect rather
    /// than the title — a window that cannot rename still shows what it holds.
    var onRename: ((String) -> Void)? = nil
    /// Banners are the main window's job when it owns the chrome; a standalone
    /// window has to draw its own.
    var showsBanners = true
    /// Every title the vault can be linked to, aliases included. Defaults to
    /// the collection's, for a caller that has one; the Mac's editor is handed
    /// a list instead, because at that level it has no `Collection`.
    var linkTargets: [String]? = nil
    /// Renders `![[Note]]` transclusion cards.
    var embedProvider: CollectionEmbedProvider? = nil
    /// What `[[` and `#` complete to. Defaults to the collection's index.
    var completionSource: WikiCompletionSource? = nil
    /// Preview mode is this pane with no caret.
    var isEditable: Bool = true

    /// Bumped when the caret arrives from the note below — see the Mac's
    /// `NoteEditorView`, which does the same with the same notification.
    @State private var titleFocusRequest = CaretHandoff()

    var body: some View {
        VStack(spacing: 0) {
            if showsBanners {
                if editor.hasConflict { ConflictBanner(editor: editor) }
                if editor.saveError != nil { SaveErrorBanner(editor: editor) }
                // An online-only note whose bytes have not arrived. The Mac has
                // shown this since cloud collections landed; iPad, which is
                // *more* likely to be looking at one, showed nothing.
                if editor.isDownloading { DownloadingBanner(editor: editor) }
            }
            if appearance.showInlineTitle {
                InlineNoteTitle(
                    title: note.title,
                    theme: EditorTheme(fontSize: appearance.editorFontSize,
                                       accent: appearance.editorAccentPlatformColor),
                    onRename: { onRename?($0) },
                    focusRequest: titleFocusRequest
                )
                .disabled(onRename == nil)
            }
            // The measure is the *pane's*, applied once, outside the mode
            // switch. It used to be applied per mode — Preview at the reading
            // measure, everything else at the editing one — so switching mode
            // changed the column's width and re-broke every line in the note.
            Group {
                switch mode {
                case .edit:     liveEditor
                case .markdown: sourceEditor
                case .split:    splitEditor
                default:        preview
                }
            }
            .measuredText(fontSize: appearance.editorFontSize,
                          reading: appearance.readingWidth,
                          editing: appearance.editorWidth)
        }
        .onReceive(NotificationCenter.default.publisher(for: .hnEditorCaretEscapedTop)) { notification in
            // The caret left the top of the note — catch it in the title. Only
            // when there *is* a title to catch it in, and only when this pane
            // can rename: a window that cannot rename must not steal focus into
            // a field that will not commit.
            guard appearance.showInlineTitle, onRename != nil else { return }
            titleFocusRequest = titleFocusRequest.next(x: notification.userInfo?["x"] as? CGFloat)
        }
        // S3: the pane is a viewport, whatever mode it is in. Without the clamp
        // the editor's or preview's ideal height sizes the column, and the
        // split view follows it past the screen.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The shared TextKit 2 live editor (inline styling, caret-driven reveal,
    /// list bullets, callouts, heading rules, checkboxes).
    private var liveEditor: some View {
        EditorHost(
            editor: editor,
            note: note,
            linkTargets: linkTargets ?? collection?.search.linkTargets() ?? [],
            fontSize: appearance.editorFontSize,
            accent: appearance.editorAccentPlatformColor,
            wrapGuide: appearance.wrapGuide,
            isEditable: isEditable,
            embedProvider: embedProvider ?? collection?.embedProvider,
            onOpenWikiLink: onOpenWikiLink,
            selectionActions: selectionActions,
            completionSource: completionSource ?? WikiCompletionSource(
                titles: collection?.search.linkTargets() ?? [],
                tags: collection?.search.allTags() ?? [],
                headings: { name in collection?.search.headings(forName: name) ?? [] },
                currentText: { editor.text }
            ),
            intelligence: IntelligenceService(settings: llmSettings)
        )
    }

    /// Raw Markdown source editor, bound straight to the note buffer.
    private var sourceEditor: some View {
        // Not `TextEditor`: SwiftUI cannot turn typographic substitution off,
        // and this view shows the note's literal Markdown source. See
        // `iOSSourceEditor` — typing `---` under a table header was producing
        // an em dash and quietly breaking the table.
        SourceEditor(
            text: Binding(get: { editor.text }, set: { editor.text = $0 }),
            fontSize: appearance.editorFontSize
        )
    }

    /// Read-only rendered preview (WKWebView over the shared HTML export),
    /// through `GitHubMarkdown.prepare` exactly as the Mac's `githubPreview` is.
    private var preview: some View {
        // `GFMPreview` — the package's own preview, cross-platform since it was
        // written. `MarkdownWebView` was a second WKWebView wrapper over the
        // same renderer, in the app, on one platform.
        GFMPreview(
            markdown: GitHubMarkdown.prepare(editor.text),
            baseURL: note.fileURL.deletingLastPathComponent(),
            fontScale: appearance.textScale
        )
    }

    /// Source + preview together — side by side on a wide (landscape) screen,
    /// stacked on a tall (portrait) one.
    private var splitEditor: some View {
        GeometryReader { geo in
            // Side by side in a landscape column, stacked in a portrait one —
            // the same rule on both. `HSplitView`/`VSplitView` give the Mac a
            // *draggable* divider and exist only there, so the arrangement is
            // shared and the splitter is not.
            if geo.size.width >= geo.size.height {
                #if canImport(AppKit)
                HSplitView {
                    sourceEditor.frame(minWidth: 180)
                    preview.frame(minWidth: 180)
                }
                #else
                HStack(spacing: 0) { sourceEditor; Divider(); preview }
                #endif
            } else {
                #if canImport(AppKit)
                VSplitView {
                    sourceEditor.frame(minHeight: 120)
                    preview.frame(minHeight: 120)
                }
                #else
                VStack(spacing: 0) { sourceEditor; Divider(); preview }
                #endif
            }
        }
    }
}

// `iOSEditorModePicker` used to sit here — a near-copy of
// `NoteEditorView.modePicker` with no call sites anywhere, and an `iOS` prefix
// in a tree whose whole point is one code base. `modePicker` is the one in use.
