//
//  InlineNoteTitle.swift
//  HelloNotes
//
//  The note's filename, shown above its body as a level-1 heading and editable
//  in place — rename here and the file is renamed, with every `[[wiki-link]]`
//  to it rewritten.
//
//  Why this exists: the title is the first thing a note *is*, and without it
//  on screen a note appears to start mid-content. The window title bar had it,
//  which is not where anyone reads.
//
//  It is deliberately **not** part of the text storage. The editor's founding
//  invariant is that raw Markdown IS the text — one text, one coordinate
//  system — so a title that lives in the filename rather than the file cannot
//  be a line in the buffer. It is chrome that renders as though it weren't.
//

import SwiftUI
import MarkdownEditor

struct InlineNoteTitle: View {
    /// The current title (filename without extension).
    let title: String
    /// The editor theme, so the title is drawn in the document's own H1 rather
    /// than something that merely looks similar.
    let theme: EditorTheme
    /// Commit a new title. Called only when it actually changed and isn't blank.
    var onRename: (String) -> Void

    /// Bumped by the host to pull focus here — the caret arrived from the
    /// note below. A counter rather than a Bool so a second request in a row
    /// still fires.
    var focusRequest: Int

    @State private var draft = ""

    var body: some View {
        InlineTitleField(
            text: $draft,
            font: theme.headingFont(level: 1),
            onCommit: { commit(from: $0) },
            onEnterBody: {
                NotificationCenter.default.post(name: .hnEditorFocusStart, object: nil)
            },
            focusRequest: focusRequest
        )
        .padding(.leading, EditorMetrics.textLeadingInset)
        .padding(.trailing, EditorMetrics.textContainerInset.width)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .task(id: title) { draft = title }
        .accessibilityLabel("Note title")
        .accessibilityHint("Renaming updates the file and every link to it")
    }

    private func commit(from value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // A blank title would leave the file unnameable; treat it as a cancel.
        guard !trimmed.isEmpty else { revert(); return }
        // Already sanitised as typed; trimming is the last step.
        guard trimmed != title else { return }
        onRename(trimmed)
    }

    private func revert() {
        draft = title
    }

    /// What the file system will accept. `/` is a path separator and `:` is the
    /// legacy HFS separator that Finder still displays as `/`.
    static func sanitised(_ raw: String) -> String {
        raw.replacingOccurrences(of: "/", with: "-")
           .replacingOccurrences(of: ":", with: "-")
           .replacingOccurrences(of: "\n", with: " ")
    }
}
