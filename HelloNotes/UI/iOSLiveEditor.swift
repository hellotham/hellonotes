//
//  iOSLiveEditor.swift
//  HelloNotes
//
//  Hosts the shared TextKit 2 live editor (Packages/NotesEditor) on iOS,
//  mirroring the macOS NewEditorHost: it builds an EditorDocument from the
//  note buffer, feeds the model back on edit (for autosave), and rebuilds when
//  the note / font / appearance changes. Block embeds and code-colour services
//  are macOS-only for now; iOS gets live inline styling, caret-driven
//  concealment, list bullets, callouts, heading rules and task checkboxes.
//

#if os(iOS)
import SwiftUI
import MarkdownEditor

struct iOSLiveEditor: View {
    @Bindable var editor: EditorModel
    let note: Note
    let fontSize: CGFloat
    var onOpenWikiLink: (String) -> Void

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
                theme: EditorTheme(fontSize: fontSize)
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

    /// Rebuild the document when the note (or its loaded-from-disk revision),
    /// font, or appearance changes — never on our own edits.
    private var taskKey: String {
        "\(note.fileURL.path)|\(editor.loadRevision)|\(Int(fontSize))|\(colorScheme == .dark ? "d" : "l")"
    }
}
#endif
