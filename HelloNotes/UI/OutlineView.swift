//
//  OutlineView.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import SwiftUI
import MarkdownEditor

extension Notification.Name {
    /// Menu → editor: toggle the Find & Replace bar (the Edit ▸ Find command),
    /// addressed to one editor (`EditorModel.editorID`). It was addressed to
    /// none, so ⌘F in one window toggled the find bar in every window — the
    /// same defect as the rest of the editor's bus (`EditorBus`).
    static func hnEditorToggleFind(editor: String) -> Notification.Name {
        Notification.Name("hn.editor.toggleFind.\(editor)")
    }
    /// Menu → editor: open the rewrite sheet over the whole note (Note ▸ Rewrite
    /// or Expand Note…). A notification for the same reason Find is one — the
    /// sheet belongs to the editor, which owns the text and the replace path,
    /// while the command belongs to the menu bar. Addressed to one editor, as
    /// ⌘F is: posted to none, one Rewrite opened a rewrite sheet in every
    /// window at once, each over its own note and wired to replace it.
    static func hnRewriteNote(editor: String) -> Notification.Name {
        Notification.Name("hn.editor.rewriteNote.\(editor)")
    }

    /// Show the note as Marp slides / open the diagram zoom on the diagram
    /// nearest the caret.
    ///
    /// Posted rather than called because the sheets live on `NoteEditorView`
    /// and the commands that ask for them live in the shell's menus — the same
    /// split `hnRewriteNote` already had. Before this, iOS kept its own copies
    /// of both sheets so its menu had something local to set. Addressed to one
    /// editor too: View Diagram (then Mermaid Diagrams) chosen in one window
    /// opened the sheet in every window — an empty one over a note that had no
    /// diagrams.
    static func hnShowSlides(editor: String) -> Notification.Name {
        Notification.Name("hn.editor.showSlides.\(editor)")
    }
    static func hnShowMermaid(editor: String) -> Notification.Name {
        Notification.Name("hn.editor.showMermaid.\(editor)")
    }
    /// Put the caret in the band's library-search field (⌥⌘F).
    static let hnFocusLibrarySearch = Notification.Name("hn.shell.focusLibrarySearch")
    /// The caret tried to leave the top of the document — put focus on the
    /// inline title, so title and body arrow like one flow.
    static let hnEditorCaretEscapedTop = Notification.Name("hn.editor.caretEscapedTop")
    /// The inline title is handing the caret down into the body.
    static let hnEditorFocusStart = Notification.Name("hn.editor.focusStart")
    /// A note was just created: put the caret in its title, because naming it
    /// is the first thing anybody does with a new note. Without this a new note
    /// opened with nothing focused at all — no caret, no keyboard — which reads
    /// as the app having lost focus rather than never having taken it.
    static let hnEditorFocusTitle = Notification.Name("hn.editor.focusTitle")
}

/// Take the editor to a heading: at once where a surface of it is showing, and
/// otherwise as soon as one is (`EditorBus.requestHeadingJump`).
///
/// Addressed to `editor`, the one whose outline was tapped (`EditorBus`):
/// unaddressed, a jump in one window scrolled every editor and preview in
/// every other.
///
/// It used to clear a highlight 1.2s later, on a timer started by the post.
/// There was no highlight to clear — a jump leaves a caret at the heading, not
/// a selection — so all the timer did was collapse whatever selection there was
/// by then and drop the find bar's query: a word selected in the second after
/// a jump was deselected under the pointer, and a find in progress lost its
/// matches. A jump now ends where it lands.
@MainActor
func hnJumpToHeading(ordinal: Int, title: String, editor: String) {
    EditorBus.requestHeadingJump(HeadingJump(ordinal: ordinal, title: title), editor: editor)
}

/// Jump to the heading *named* `title` — for `[[Note#Heading]]`, which carries a
/// name and nothing else.
///
/// The name has to become an ordinal somewhere, and that means one pass over the
/// text. It happens **off the main actor**, and only when a link is followed —
/// never while typing. Every other caller already knows the ordinal, because the
/// outline drew the row.
func hnJumpToHeading(titled title: String, in text: String, editor: String) async {
    let ordinal = await offMain {
        MarkdownParsing.headings(in: text).firstIndex { $0.title == title }
    }
    guard let ordinal else { return }
    await MainActor.run { hnJumpToHeading(ordinal: ordinal, title: title, editor: editor) }
}

/// A popover showing the note's statistics and an outline (table of contents).
/// Clicking a heading jumps the editor to that section.
struct OutlineView: View {
    /// The note, compared by its version: a redraw of whatever holds this view
    /// would otherwise compare the note with itself (`NoteText`). The text as
    /// of the last pause in typing (`EditorModel.settledText`).
    let content: NoteText
    var onSelectHeading: (Int, DocumentHeading) -> Void = { _, _ in }
    /// How tall the headings' list may grow before it scrolls: a popover's
    /// cap, or `nil` for the panel, which is as tall as the window. The panel
    /// kept the popover's 320pt, and a long outline scrolled inside a short
    /// box in a tall panel (secondary.md §9, item 5; implemented.md §51.36).
    var headingsHeight: CGFloat? = 320

    /// What the note was analysed to, off the main actor.
    ///
    /// It was analysed in `body` — the statistics and a full Markdown parse
    /// for the headings, two passes over the whole note on the main actor at
    /// every redraw, and in Markdown and Split mode the note changed at every
    /// keystroke. Kept until the next analysis lands, so the outline does not
    /// blank while it is made.
    @State private var analysis: Analysis?

    private struct Analysis {
        let stats: DocumentStatistics
        let headings: [DocumentHeading]
    }

    var body: some View {
        let stats = analysis?.stats ?? .empty
        let headings = analysis?.headings ?? []
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("STATISTICS")
                    .font(Chrome.Style.caption2)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                statRow("Words", stats.words.formatted())
                statRow("Characters", stats.characters.formatted())
                statRow("Paragraphs", stats.paragraphs.formatted())
                statRow("Reading time", stats.readingMinutes <= 0 ? "—" : "\(stats.readingMinutes) min")
            }
            .padding(12)

            ChromeDivider()

            VStack(alignment: .leading, spacing: 6) {
                Text("OUTLINE")
                    .font(Chrome.Style.caption2)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)

                if headings.isEmpty {
                    Text("No headings")
                        .font(Chrome.Style.callout)
                        .foregroundStyle(Chrome.Colour.secondaryLabel)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(headings.enumerated()), id: \.offset) { ordinal, heading in
                                Button {
                                    onSelectHeading(ordinal, heading)
                                } label: {
                                    Text(heading.title)
                                        .font(heading.level == 1 ? Chrome.Style.callout.weight(.semibold) : Chrome.Style.callout)
                                        .lineLimit(1)
                                        .padding(.leading, CGFloat(heading.level - 1) * 14)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(.rect)
                                }
                                .buttonStyle(ChromePlainStyle())
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .frame(maxHeight: headingsHeight ?? .infinity)
                }
            }
            .padding(12)
        }
        // The panel's width, whatever it is dragged to — a fixed 260 sat
        // centred in a wide panel and overflowed a narrow one.
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: content.version) {
            let text = content.text
            let (stats, headings) = await offMain {
                (DocumentAnalyzer.analyze(text), MarkdownParsing.headings(in: text))
            }
            guard !Task.isCancelled else { return }
            analysis = Analysis(stats: stats, headings: headings)
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(Chrome.Colour.secondaryLabel).monospacedDigit()
        }
        .font(Chrome.Style.callout)
    }
}
