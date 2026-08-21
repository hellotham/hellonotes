//
//  iOSNoteEditorPane.swift
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

#if os(iOS)
import SwiftUI
import MarkdownEditor

struct iOSNoteEditorPane: View {
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

    var body: some View {
        VStack(spacing: 0) {
            if showsBanners {
                if editor.hasConflict { ConflictBanner(editor: editor) }
                if editor.saveError != nil { SaveErrorBanner(editor: editor) }
            }
            if appearance.showInlineTitle {
                InlineNoteTitle(
                    title: note.title,
                    theme: EditorTheme(fontSize: appearance.editorFontSize,
                                       accent: appearance.editorAccentPlatformColor),
                    onRename: { onRename?($0) }
                )
                .disabled(onRename == nil)
            }
            switch mode {
            case .edit:     liveEditor
            case .markdown: sourceEditor
            case .split:    splitEditor
            default:        preview
            }
        }
        // S3: the pane is a viewport, whatever mode it is in. Without the clamp
        // the editor's or preview's ideal height sizes the column, and the
        // split view follows it past the screen.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The shared TextKit 2 live editor (inline styling, caret-driven reveal,
    /// list bullets, callouts, heading rules, checkboxes).
    private var liveEditor: some View {
        iOSLiveEditor(
            editor: editor,
            note: note,
            collection: collection,
            fontSize: appearance.editorFontSize,
            accent: appearance.editorAccentPlatformColor,
            textWidth: (appearance.readingWidth, appearance.editorWidth),
            wrapGuide: appearance.wrapGuide,
            onOpenWikiLink: onOpenWikiLink,
            selectionActions: selectionActions,
            completionSource: WikiCompletionSource(
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
        iOSSourceEditor(
            text: Binding(get: { editor.text }, set: { editor.text = $0 }),
            fontSize: appearance.editorFontSize
        )
        // `.editing`, monospaced — the Mac measures its source mode the same
        // way, and the character width has to be resolved against the
        // monospaced font or the column count means a different pane width on
        // each platform.
        .measuredText(.editing,
                      fontSize: appearance.editorFontSize,
                      monospaced: true,
                      reading: appearance.readingWidth,
                      editing: appearance.editorWidth)
    }

    /// Read-only rendered preview (WKWebView over the shared HTML export),
    /// through `GitHubMarkdown.prepare` exactly as the Mac's `githubPreview` is.
    private var preview: some View {
        MarkdownWebView(
            markdown: GitHubMarkdown.prepare(editor.text),
            title: note.title,
            baseURL: note.fileURL.deletingLastPathComponent(),
            fontScale: appearance.textScale
        )
        // Reading width, centred — the setting exists for prose, and the
        // preview is the one mode that is purely prose.
        .measuredText(.reading,
                      fontSize: appearance.editorFontSize,
                      reading: appearance.readingWidth,
                      editing: appearance.editorWidth)
    }

    /// Source + preview together — side by side on a wide (landscape) screen,
    /// stacked on a tall (portrait) one.
    private var splitEditor: some View {
        GeometryReader { geo in
            let sideBySide = geo.size.width >= geo.size.height
            let layout = sideBySide
                ? AnyLayout(HStackLayout(spacing: 0))
                : AnyLayout(VStackLayout(spacing: 0))
            layout {
                sourceEditor
                Divider()
                preview
            }
        }
    }
}

/// Preview / Markdown / Split switcher — the same control in the main window's
/// toolbar and a note window's.
struct iOSEditorModePicker: View {
    @Binding var mode: EditorMode

    var body: some View {
        Picker("View mode", selection: $mode) {
            ForEach(EditorMode.platformCases) { m in
                Image(systemName: m.symbol)
                    .accessibilityLabel(m.label)
                    .tag(m)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}
#endif
