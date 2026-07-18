//
//  iOSLiveEditor.swift
//  HelloNotes
//
//  Hosts the shared TextKit 2 live editor (Packages/NotesEditor) on iOS,
//  mirroring the macOS NewEditorHost: it builds an EditorDocument from the
//  note buffer, feeds the model back on edit (for autosave), and rebuilds when
//  the note / font / appearance changes. Block embeds (images, Mermaid, math,
//  tables, `![[Note]]` transclusions) and code-syntax colours are wired via the
//  same cross-platform adapters the macOS host uses.
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

    @AppStorage("attachmentFolder") private var attachmentFolder = "assets"
    @Environment(\.colorScheme) private var colorScheme
    @State private var document: EditorDocument?

    var body: some View {
        Group {
            if let document {
                MarkdownEditorView(document: document)
                    .editable(true)
                    .onLinkTap { tap in
                        switch tap {
                        case .wiki(let target): onOpenWikiLink(target)
                        case .url(let url): UIApplication.shared.open(url)
                        }
                    }
                    .ignoresSafeArea(.container, edges: .bottom)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: taskKey) {
            let built = await EditorDocument.make(
                text: editor.text,
                theme: EditorTheme(fontSize: fontSize),
                services: makeServices()
            )
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
                MermaidDiagramRenderer.standaloneImage(source: source, isDark: isDark)
            },
            renderMath: { source, isDark in
                await MainActor.run { NoteTranscluder.blockLatexImage(source: source, isDark: isDark) }
            },
            renderTransclusion: { target, isDark in
                await MainActor.run { embed?.image(forName: target, isDark: isDark) }
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
