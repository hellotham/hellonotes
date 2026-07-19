//
//  OutlineView.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(macOS)
import SwiftUI

extension Notification.Name {
    /// Host → engine: scroll to (and briefly highlight) the first match of a
    /// query in the editor's displayed text. Used for table-of-contents jumps.
    static let hnEditorFindQuery = Notification.Name("hn.editor.findQuery")
    /// Host → engine: clear find highlights.
    static let hnEditorClearHighlights = Notification.Name("hn.editor.clearHighlights")
    /// Engine → host: number of matches for the last `findQuery` (`userInfo["count"]`).
    static let hnEditorFindResults = Notification.Name("hn.editor.findResults")
    /// Host → engine: replace the current find match (`userInfo` query/replacement/currentIndex).
    static let hnEditorReplaceCurrent = Notification.Name("hn.editor.replaceCurrent")
    /// Host → engine: replace every find match (`userInfo` query/replacement).
    static let hnEditorReplaceAll = Notification.Name("hn.editor.replaceAll")
}

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
#endif
