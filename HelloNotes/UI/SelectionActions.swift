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
import MarkdownEditor   // EditorMenuItem

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


// MARK: - The menu both editors offer

extension SelectionActions {
    /// The vault actions for `selected`, as menu items.
    ///
    /// One builder, used by the AppKit context menu and the UIKit edit menu
    /// alike. It lived on `iOSLiveEditor` while macOS drew a floating
    /// `SelectionActionBar` positioned by an `onSelectionChange` hook UIKit did
    /// not have — two implementations of the same three commands, each free to
    /// drift, and only one of them offering "Rewrite with AI…" until this
    /// session.
    ///
    /// Built per selection rather than once, so **Link** appears only when a
    /// note actually matches: an item that cannot apply is worse than a missing
    /// one, because you have to tap it to find out.
    func menuItems(for selected: String) -> [EditorMenuItem] {
        var items: [EditorMenuItem] = []
        if SelectionActions.isLinkable(selected), let target = linkTarget(selected) {
            items.append(EditorMenuItem(title: "Link to “\(target)”",
                                        systemImage: "link.badge.plus") { phrase in
                NoteEdits.wikiLink(to: target, shownAs: phrase)
            })
        }
        items.append(EditorMenuItem(title: "Find Related",
                                    systemImage: "text.magnifyingglass") { phrase in
            findRelated(phrase)
            return nil       // read-only: the note is not touched
        })
        items.append(EditorMenuItem(title: "Ask Your Library",
                                    systemImage: "sparkles.rectangle.stack") { phrase in
            explain(phrase)
            return nil
        })
        return items
    }
}
