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

/// Where the caret should land when it crosses the title/body seam, and a token
/// so the same destination twice in a row still fires.
///
/// `x` is a distance in points from the first glyph — not a character index —
/// because the title and the body are set in different fonts, so only a distance
/// means the same thing on both sides. `nil` means there is no column to keep.
struct CaretHandoff: Equatable {
    var token: Int = 0
    var x: CGFloat?

    /// The next request for the same seam, carrying a new destination.
    func next(x: CGFloat?) -> CaretHandoff { CaretHandoff(token: token &+ 1, x: x) }
}

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
    /// Defaulted because only the Mac hands the caret back up: the iOS editor
    /// exposes no `EditorProxy`, so there is nothing there to arrow up *from*.
    var focusRequest: CaretHandoff = .init()

    @State private var draft = ""
    #if !os(macOS)
    /// Focus for the iOS field — the Mac's representable manages its own.
    @FocusState private var titleFocused: Bool
    #endif

    var body: some View {
        field
        .padding(.leading, EditorMetrics.textLeadingInset)
        .padding(.trailing, EditorMetrics.textContainerInset.width)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .task(id: title) { draft = title }
        .accessibilityLabel("Note title")
        .accessibilityHint("Renaming updates the file and every link to it")
    }

    /// The Mac owns its field editor (see `InlineTitleField`) because the caret
    /// crosses between the title and the note body there and both boundary
    /// behaviours have to be corrected at the source. iOS has no such crossing
    /// — the editor exposes no proxy to hand the caret to — so the platform's
    /// own text field is exactly right.
    @ViewBuilder
    private var field: some View {
        #if os(macOS)
        InlineTitleField(
            text: $draft,
            font: theme.headingFont(level: 1),
            onCommit: { commit(from: $0) },
            onEnterBody: { x in
                NotificationCenter.default.post(
                    name: .hnEditorFocusStart, object: nil,
                    userInfo: x.map { ["x": $0] })
            },
            focusRequest: focusRequest
        )
        #else
        // Focusable, so the caret can arrive here from the note below it. The
        // Mac's field has taken `focusRequest` since the inline title shipped;
        // iOS's ignored it, so ↑ from the first line of a note on an iPad
        // keyboard did nothing at all.
        //
        // No column is carried across the seam on this platform: SwiftUI's
        // `TextField` has no way to place a caret at an x offset, so the whole
        // field takes focus. The Mac keeps the column through its own
        // `NSTextField` representable.
        TextField("Untitled", text: $draft)
            .textFieldStyle(.plain)
            .font(Font(theme.headingFont(level: 1)))
            .submitLabel(.done)
            .autocorrectionDisabled()
            .focused($titleFocused)
            .onChange(of: focusRequest) { _, _ in titleFocused = true }
            .onChange(of: draft) { _, value in
                let clean = Self.sanitised(value)
                if clean != value { draft = clean }
            }
            .onSubmit { commit(from: draft) }
        #endif
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
