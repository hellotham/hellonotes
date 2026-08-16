//
//  SelectionActionBar.swift
//  HelloNotes
//
//  Created by Chris Tham on 16/8/2026.
//
//  What a selection can do that the OS cannot.
//
//  These deliberately carry **nothing the OS already does**. Both platforms put
//  Writing Tools — rewrite, proofread, summarise, tone — on any text selection,
//  and offering the same verbs again would be a worse copy of something the
//  user already has and already trusts. What the OS cannot do is anything
//  involving *this vault*: it has never heard of the other 2,000 notes. So that
//  is all this offers — link it, find notes like it, ask the library about it.
//  Three actions, each impossible for Writing Tools by construction.
//
//  How they *surface* differs, because the platforms differ. macOS floats the
//  bar below (an `NSTextView` has no system selection bar to join). iOS puts
//  them in the system edit menu, which is already there and already where the
//  hand goes — see `iOSLiveEditor`.
//

import SwiftUI

/// What the collection can do with a selected phrase.
struct SelectionActions {
    /// The note this phrase should link to, or `nil` if none matches.
    ///
    /// Resolution is the *collection's* job and rewriting the text is the
    /// *editor's*, which is why this answers a question rather than performing
    /// an action — the host knows the titles, the editor owns the range.
    var linkTarget: (String) -> String?
    /// Show notes related to the phrase.
    var findRelated: (String) -> Void
    /// Ask the library about the phrase.
    var explain: (String) -> Void

    /// Whether a phrase is worth offering a link for at all. A passage spanning
    /// paragraphs is not a term, and nothing in a vault is titled after one —
    /// so asking would only cost a lookup per selection change.
    static func isLinkable(_ phrase: String) -> Bool {
        !phrase.contains("\n") && phrase.count <= 120
    }
}

#if os(macOS)
struct SelectionActionBar: View {
    let text: String
    let actions: SelectionActions
    /// Called with the note title to link to, once the user asks for it.
    var onLink: (String) -> Void

    private var target: String? {
        guard SelectionActions.isLinkable(text) else { return nil }
        return actions.linkTarget(text)
    }

    var body: some View {
        HStack(spacing: 2) {
            if let target {
                button("Link", "link.badge.plus",
                       help: "Link this to “\(target)”") { onLink(target) }
                Divider().frame(height: 14)
            }
            button("Related", "text.magnifyingglass",
                   help: "Find notes about this") { actions.findRelated(text) }
            Divider().frame(height: 14)
            button("Ask", "sparkles.rectangle.stack",
                   help: "Ask your library about this") { actions.explain(text) }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }

    private func button(_ title: String, _ symbol: String,
                        help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
#endif
