//
//  WikiLinkCompletionList.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

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
/// inside a `[[wiki-link]]`. Click (or tap) a row to insert it. (Keyboard
/// navigation isn't available because the text view keeps first-responder
/// focus.)
struct WikiLinkCompletionList: View {
    let matches: [WikiCompletion]
    let onSelect: (WikiCompletion) -> Void

    /// The Mac's row — a 4pt inset around one line — on both platforms, as the
    /// sidebar's rows are. The whole row takes the tap, which is as much
    /// target as a column of adjacent rows can give a finger.
    private let rowInset: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(matches) { match in
                Button {
                    onSelect(match)
                } label: {
                    Label(match.label, systemImage: match.isHeading ? "number" : "doc.text")
                        .lineLimit(1)
                        .padding(.vertical, rowInset)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(ChromePlainStyle())
            }
        }
        .frame(width: 260, alignment: .leading)
        .padding(4)
        // A card of the content colour: `.regularMaterial` and `.separator`
        // are each platform's own blur and rule.
        .background(Chrome.Colour.content, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Chrome.Colour.separator))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}
