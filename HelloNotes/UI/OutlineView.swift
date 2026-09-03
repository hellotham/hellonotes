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
    /// Host → whichever surface is on screen: put this heading at the top.
    ///
    /// **Not a find.** This used to be posted as `findQuery`, so "jump to the
    /// Maths heading" meant "select the first occurrence of the word Maths
    /// anywhere in the file" — which is the front matter's `title:` line as
    /// often as not, and prose before the heading the rest of the time. It
    /// carries an `offset` (UTF-16, into the source) and an `ordinal` (the
    /// heading's index in document order) so every surface can land on the
    /// heading itself: the two text editors use the offset, and Preview uses
    /// the ordinal, because rendered HTML has no source offsets but its
    /// headings are in the same order.
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
func hnJumpToHeading(offset: Int?, ordinal: Int, title: String) {
    var info: [String: Any] = ["ordinal": ordinal, "title": title]
    if let offset { info["offset"] = offset }
    NotificationCenter.default.post(name: .hnEditorJumpToHeading, object: nil, userInfo: info)
    DispatchQueue.main.asyncAfter(deadline: .now() + hnHeadingHighlightDuration) {
        NotificationCenter.default.post(name: .hnEditorClearHighlights, object: nil)
    }
}

/// Jump to the heading *named* `title` — for `[[Note#Heading]]`, which carries a
/// name and no position. The name is resolved against the document's headings
/// here, so what travels is still a position.
@MainActor
func hnJumpToHeading(titled title: String, in text: String) {
    let headings = MarkdownParsing.headings(in: text)
    guard let ordinal = headings.firstIndex(where: { $0.title == title }) else { return }
    hnJumpToHeading(offset: headings[ordinal].offset, ordinal: ordinal, title: title)
}

/// How long a jumped-to heading stays highlighted. Long enough to catch the
/// eye after the scroll settles, short enough not to look like a selection.
let hnHeadingHighlightDuration: TimeInterval = 1.2

/// A popover showing the note's statistics and an outline (table of contents).
/// Clicking a heading jumps the editor to that section.
struct OutlineView: View {
    let text: String
    var onSelectHeading: (DocumentHeading) -> Void = { _ in }

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
                            ForEach(Array(headings.enumerated()), id: \.offset) { _, heading in
                                Button {
                                    onSelectHeading(heading)
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
