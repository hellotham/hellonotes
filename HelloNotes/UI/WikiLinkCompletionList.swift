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
/// inside a `[[wiki-link]]` or a `#tag`. Click (or tap) a row to insert it —
/// or, on a keyboard, choose one with ↑ and ↓ and take it with Return or Tab;
/// Escape sends the list away.
///
/// The text view keeps first responder, so no key ever comes here: the editor
/// asks the host for each one and the host tells this list which row is
/// chosen (`CompletionChoice`). Nothing is chosen until an arrow chooses it.
struct WikiLinkCompletionList: View {
    let matches: [WikiCompletion]
    /// The row the arrow keys have chosen, if any.
    var chosen: Int? = nil
    let onSelect: (WikiCompletion) -> Void

    @Environment(AppearanceSettings.self) private var appearance

    /// The Mac's row — a 4pt inset around one line — on both platforms, as the
    /// sidebar's rows are. The whole row takes the tap, which is as much
    /// target as a column of adjacent rows can give a finger.
    private let rowInset: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                Button {
                    onSelect(match)
                } label: {
                    Label(match.label, systemImage: match.isHeading ? "number" : "doc.text")
                        .lineLimit(1)
                        .padding(.vertical, rowInset)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // The chosen row, as a chosen row is drawn everywhere:
                        // the accent, faint, behind it.
                        .background(index == chosen ? Chrome.selection(appearance.resolvedAccent) : .clear,
                                    in: .rect(cornerRadius: Chrome.Metric.radius))
                        .contentShape(.rect)
                }
                .buttonStyle(ChromePlainStyle())
                .accessibilityAddTraits(index == chosen ? .isSelected : [])
            }
        }
        .frame(width: 260, alignment: .leading)
        .padding(4)
        // Named, so the interface test can find the list it presses keys for.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.completions")
        // A card of the content colour: `.regularMaterial` and `.separator`
        // are each platform's own blur and rule.
        .background(Chrome.Colour.content, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Chrome.Colour.separator))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}
