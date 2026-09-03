//
//  OutlineView.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import SwiftUI

extension Notification.Name {
    /// Menu → editor: toggle the Find & Replace bar (the Edit ▸ Find command).
    static let hnEditorToggleFind = Notification.Name("hn.editor.toggleFind")
    /// Menu → editor: open the rewrite sheet over the whole note (Note ▸ Rewrite
    /// or Expand Note…). A notification for the same reason Find is one — the
    /// sheet belongs to the editor, which owns the text and the replace path,
    /// while the command belongs to the menu bar.
    static let hnRewriteNote = Notification.Name("hn.editor.rewriteNote")

    /// Show the note as Marp slides / preview its Mermaid diagrams.
    ///
    /// Posted rather than called because the sheets live on `NoteEditorView`
    /// and the commands that ask for them live in the shell's menus — the same
    /// split `hnRewriteNote` already had. Before this, iOS kept its own copies
    /// of both sheets so its menu had something local to set.
    static let hnShowSlides = Notification.Name("hn.editor.showSlides")
    static let hnShowMermaid = Notification.Name("hn.editor.showMermaid")
    /// Host → engine: scroll to (and briefly highlight) the first match of a
    /// query in the editor's displayed text. Used for table-of-contents jumps.
    static let hnEditorFindQuery = Notification.Name("hn.editor.findQuery")
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
    /// Host → engine: clear find highlights.
    static let hnEditorClearHighlights = Notification.Name("hn.editor.clearHighlights")
    /// Host → whichever surface is on screen: put the n-th heading at the top.
    ///
    /// **Not a find, and not an offset either.**
    ///
    /// It began as a find — the heading's own text, posted as a search query —
    /// so "go to Maths" meant "select the first occurrence of the word Maths",
    /// which is the front matter's `title:` line as often as not.
    ///
    /// The obvious repair, a source offset, is worse than it looks: an offset is
    /// only valid for the text it was measured against, so it goes stale the
    /// moment anything above the heading is typed — and on iPad the inspector is
    /// a *column*, so the outline is on screen while you type. Keeping it fresh
    /// means re-parsing the document, and a whole-document parse is precisely
    /// what may not happen on the editor's actor.
    ///
    /// So what travels is an **ordinal**: the heading's index in document order,
    /// which the outline already knows because it drew that row. Each surface
    /// resolves it against something it already maintains — the editor against
    /// `EditorDocument.blocks`, whose ranges the splicer keeps current with no
    /// parse at all; Preview against the n-th `<h1>`…`<h6>` in the DOM. The
    /// `title` rides along only to notice when the two disagree, and the
    /// fallback is still a *heading*, never prose.
    static let hnEditorJumpToHeading = Notification.Name("hn.editor.jumpToHeading")
    /// Engine → host: number of matches for the last `findQuery` (`userInfo["count"]`).
    static let hnEditorFindResults = Notification.Name("hn.editor.findResults")
    /// Host → engine: replace the current find match (`userInfo` query/replacement/currentIndex).
    static let hnEditorReplaceCurrent = Notification.Name("hn.editor.replaceCurrent")
    /// Host → engine: replace every find match (`userInfo` query/replacement).
    static let hnEditorReplaceAll = Notification.Name("hn.editor.replaceAll")
}

/// Scroll the editor to a heading and clear the resulting highlight a moment
/// later, so a table-of-contents jump flashes the destination instead of
/// leaving it permanently marked.
///
/// One implementation because there are two callers — the toolbar's outline
/// popover and the inspector's outline — and they each had their own copy of
/// the same `asyncAfter(1.2)`. Two copies of a timing constant drift, and when
/// they do, "clear highlight" starts behaving differently depending on which
/// outline you used.
@MainActor
func hnJumpToHeading(ordinal: Int, title: String) {
    NotificationCenter.default.post(
        name: .hnEditorJumpToHeading, object: nil,
        userInfo: ["ordinal": ordinal, "title": title]
    )
    DispatchQueue.main.asyncAfter(deadline: .now() + hnHeadingHighlightDuration) {
        NotificationCenter.default.post(name: .hnEditorClearHighlights, object: nil)
    }
}

/// Jump to the heading *named* `title` — for `[[Note#Heading]]`, which carries a
/// name and nothing else.
///
/// The name has to become an ordinal somewhere, and that means one pass over the
/// text. It happens **off the main actor**, and only when a link is followed —
/// never while typing. Every other caller already knows the ordinal, because the
/// outline drew the row.
func hnJumpToHeading(titled title: String, in text: String) async {
    let ordinal = await offMain {
        MarkdownParsing.headings(in: text).firstIndex { $0.title == title }
    }
    guard let ordinal else { return }
    await MainActor.run { hnJumpToHeading(ordinal: ordinal, title: title) }
}

/// How long a jumped-to heading stays highlighted. Long enough to catch the
/// eye after the scroll settles, short enough not to look like a selection.
let hnHeadingHighlightDuration: TimeInterval = 1.2

/// A popover showing the note's statistics and an outline (table of contents).
/// Clicking a heading jumps the editor to that section.
struct OutlineView: View {
    let text: String
    var onSelectHeading: (Int, DocumentHeading) -> Void = { _, _ in }

    var body: some View {
        // Compute once per render: these were computed properties referenced
        // several times in `body`, so each render re-ran analyze()/headings()
        // over the whole note 4× / 2×.
        let stats = DocumentAnalyzer.analyze(text)
        let headings = MarkdownParsing.headings(in: text)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("STATISTICS")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                statRow("Words", stats.words.formatted())
                statRow("Characters", stats.characters.formatted())
                statRow("Paragraphs", stats.paragraphs.formatted())
                statRow("Reading time", stats.readingMinutes <= 0 ? "—" : "\(stats.readingMinutes) min")
            }
            .padding(12)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("OUTLINE")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if headings.isEmpty {
                    Text("No headings")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(headings.enumerated()), id: \.offset) { ordinal, heading in
                                Button {
                                    onSelectHeading(ordinal, heading)
                                } label: {
                                    Text(heading.title)
                                        .font(heading.level == 1 ? .callout.weight(.semibold) : .callout)
                                        .lineLimit(1)
                                        .padding(.leading, CGFloat(heading.level - 1) * 14)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                }
            }
            .padding(12)
        }
        .frame(width: 260)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.callout)
    }
}
