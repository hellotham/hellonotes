//
//  iOSLiveEditor.swift
//  HelloNotes
//
//  Hosts the shared TextKit 2 live editor (Packages/NotesEditor) on iOS,
//  mirroring the macOS NewEditorHost: it builds an EditorDocument from the
//  note buffer, feeds the model back on edit (for autosave), and rebuilds when
//  the note / font / appearance changes. Code-syntax colours are wired via the
//  cross-platform CodeHighlighterAdapter. The block-embed renderer is wired
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
    var onOpenWikiLink: (String) -> Void
    /// What the collection can do with a selected phrase. Surfaced in the
    /// system edit menu — see `SelectionActionBar.swift` for why there rather
    /// than in a bar of our own.
    var selectionActions: SelectionActions? = nil

    @AppStorage("attachmentFolder") private var attachmentFolder = "assets"
    @Environment(\.colorScheme) private var colorScheme
    /// Documents outlive this view. On iPad this matters most: rotating between
    /// the tall and wide shells re-creates the editor, and without the store
    /// every rotation would re-parse the note and drop the caret.
    @Environment(EditorDocumentStore.self) private var documents
    @State private var document: EditorDocument?

    /// The vault-aware items added to the system edit menu for `selected`.
    ///
    /// Built per selection rather than once, so **Link** appears only when a
    /// note actually matches — an item that cannot apply is worse than a
    /// missing one, because you have to tap it to find out.
    private func selectionMenu(for selected: String) -> [EditorMenuItem] {
        guard let actions = selectionActions else { return [] }
        var items: [EditorMenuItem] = []
        if SelectionActions.isLinkable(selected), let target = actions.linkTarget(selected) {
            items.append(EditorMenuItem(title: "Link to “\(target)”", systemImage: "link.badge.plus") { phrase in
                NoteEdits.wikiLink(to: target, shownAs: phrase)
            })
        }
        items.append(EditorMenuItem(title: "Find Related", systemImage: "text.magnifyingglass") { phrase in
            actions.findRelated(phrase)
            return nil       // read-only: the note is not touched
        })
        items.append(EditorMenuItem(title: "Ask Your Library", systemImage: "sparkles.rectangle.stack") { phrase in
            actions.explain(phrase)
            return nil
        })
        return items
    }

    var body: some View {
        Group {
            if let document {
                MarkdownEditorView(document: document)
                    .commandBus(documentId: note.fileURL.path)
                    .editable(true)
                    .onLinkTap { tap in
                        switch tap {
                        case .wiki(let target): onOpenWikiLink(target)
                        case .url(let url): UIApplication.shared.open(url)
                        }
                    }
                    .selectionMenuItems { selected in selectionMenu(for: selected) }
                    .ignoresSafeArea(.container, edges: .bottom)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // S3: the editor fills whatever the detail column offers.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: taskKey) {
            let key = EditorDocumentStore.Key(path: note.fileURL.path,
                                              fontSize: fontSize,
                                              isDark: colorScheme == .dark)
            let built: EditorDocument
            if let existing = documents.document(for: key) {
                built = existing
                if built.text != editor.text { built.replaceText(editor.text) }
            } else {
                let made = await EditorDocument.make(
                    text: editor.text,
                    theme: EditorTheme(fontSize: fontSize),
                    services: makeServices()
                )
                documents.insert(made, for: key)
                built = made
            }
            // Push edits back to the model (its didSet debounces + saves).
            built.onEdit = { _ in
                if editor.text != built.text { editor.text = built.text }
            }
            // A flush (note switch, resign, background) must persist the
            // document's *current* text, not a snapshot trailing the sync.
            editor.willFlush = { [weak built] in
                guard let built else { return }
                if built.text != editor.text { editor.text = built.text }
            }
            document = built
        }
        .onDisappear { editor.willFlush = nil }
    }

    /// Build the editor's wiki-link / code-colour / block-embed services, using
    /// the same cross-platform adapters as the macOS host.
    private func makeServices() -> EditorServices {
        let titles = Set((collection?.notes ?? []).map { $0.title.lowercased() })
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

    /// Rebuild the document when the note (or its loaded-from-disk revision),
    /// font, or appearance changes — never on our own edits.
    private var taskKey: String {
        "\(note.fileURL.path)|\(editor.loadRevision)|\(Int(fontSize))|\(colorScheme == .dark ? "d" : "l")"
    }
}

#endif
