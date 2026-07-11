//
//  WikiLinkCompletionList.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(macOS)
import SwiftUI

/// One suggestion in the `[[wiki-link]]` autocomplete popup — either a note
/// title/alias or a heading within a note.
struct WikiCompletion: Identifiable, Hashable {
    /// Text shown in the row.
    let label: String
    /// Inner text to place inside `[[ ]]` (e.g. `Note` or `Note#Heading`).
    let insert: String
    /// Whether this is a heading (drives the row icon).
    let isHeading: Bool

    var id: String { (isHeading ? "#" : "") + insert }
}

/// A small floating list of suggestions shown next to the caret while typing
/// inside a `[[wiki-link]]`. Click a row to insert it. (Keyboard navigation
/// isn't available because the text view keeps first-responder focus.)
struct WikiLinkCompletionList: View {
    let matches: [WikiCompletion]
    let onSelect: (WikiCompletion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(matches) { match in
                Button {
                    onSelect(match)
                } label: {
                    Label(match.label, systemImage: match.isHeading ? "number" : "doc.text")
                        .lineLimit(1)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 260, alignment: .leading)
        .padding(4)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .shadow(radius: 8, y: 2)
    }
}
#endif
