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

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Untitled", text: $draft)
            .textFieldStyle(.plain)
            .font(Font(theme.headingFont(level: 1)))
            .lineLimit(1)
            .focused($isFocused)
            .onSubmit(commit)
            // Escape abandons the edit rather than renaming the file — a
            // rename rewrites links across the vault, so it should never
            // happen by accident on a half-typed word.
            #if os(macOS)
            .onExitCommand { revert() }
            #endif
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            // A different note (or a rename from elsewhere, like the note list)
            // reseeds the field.
            .onChange(of: title) { _, _ in revert() }
            .task(id: title) { revert() }
            // Start exactly where the first glyph starts. The editor insets its
            // text by the container inset *plus* the line-fragment padding, and
            // a title that ignores either sits visibly out of margin with the
            // body no matter how well it matches the H1 font.
            .padding(.leading, EditorMetrics.textLeadingInset)
            .padding(.trailing, EditorMetrics.textContainerInset.width)
            .padding(.top, 4)
            .padding(.bottom, 2)
            .accessibilityLabel("Note title")
            .accessibilityHint("Renaming updates the file and every link to it")
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // A blank title would leave the file unnameable; treat it as a cancel.
        guard !trimmed.isEmpty else { revert(); return }
        guard trimmed != title else { return }
        onRename(trimmed)
    }

    private func revert() {
        draft = title
    }
}
