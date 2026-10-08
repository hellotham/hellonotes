//
//  WikiLinkNavigation.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  What a `[[wiki link]]` means — decided once, for both shells.
//
//  This is the canonical case for why parity cannot be maintained by keeping two
//  implementations in agreement. `openWikiLink` existed in both content views.
//  The Mac's was 45 lines: web schemes, an empty target meaning "this note", the
//  link graph (which resolves aliases and relative paths), a case-insensitive
//  title match, create-on-miss, and a `#heading` jump that waits for the tab to
//  exist. The iPad's was six lines of title comparison. Same feature name, same
//  menu, same gesture — a different feature.
//
//  Making the short one match the long one fixed that instance and fixed nothing
//  structural: it left two copies that happen to agree today. So the *decision*
//  moves here, where it is written once and can be tested without a UI, and each
//  shell keeps only the two lines that are genuinely platform-specific — opening
//  a URL, and moving its own selection.
//

import Foundation
import MarkdownCore

@MainActor
enum WikiLinkNavigation {

    /// What following a link should do.
    enum Destination: Equatable {
        /// An external URL — the shell opens it with its own platform API.
        case web(URL)
        /// A note in the vault, and the heading to scroll to once it is open.
        case note(Note, heading: String?)
        /// Nothing to open: no collection, or a target that resolved to nothing
        /// and could not be created.
        case none
    }

    /// The schemes a `[[target]]` may name that are *not* notes.
    private static let webSchemes: Set<String> = ["http", "https", "mailto", "file"]

    /// Split what a link names into the note and the heading: the alias off
    /// first (`withoutAlias`), then the heading, and the note's name trimmed.
    /// An empty heading is no heading — `[[Note#]]` is a typo, not a request
    /// to jump to a nameless section.
    ///
    /// The editor hands over everything between the brackets, alias and all
    /// (`wikiTargetAttribute`), and colours the link by its name alone —
    /// alias off, heading off, trimmed (`StyleApplier.baseTitle`) — so
    /// following it goes where the colour says. This took off the heading and
    /// nothing else: `[[Roadmap|the plan]]`, coloured as found, was followed
    /// to a note named `Roadmap|the plan`, and the main window, which creates
    /// what a link names, made one (implemented.md §51.35).
    static func split(_ target: String) -> (base: String, heading: String?) {
        let named = withoutAlias(target)
        guard let hash = named.firstIndex(of: "#") else {
            return (named.trimmingCharacters(in: .whitespaces), nil)
        }
        let after = String(named[named.index(after: hash)...])
        return (String(named[..<hash]).trimmingCharacters(in: .whitespaces), after.isEmpty ? nil : after)
    }

    /// What a link names, before its alias: up to the first `|`, and without
    /// the backslash that escapes that pipe in a table's row — where the alias
    /// is written `[[Note\|alias]]`, or the pipe would divide the cell — by
    /// the rule every reader of a link shares (`WikiLinkSyntax`,
    /// implemented.md §51.36).
    static func withoutAlias(_ target: String) -> String {
        String(WikiLinkSyntax.split(target).target)
    }

    /// Resolve `target` to what should happen.
    ///
    /// - Parameters:
    ///   - collection: the note's *own* collection, never the focused one —
    ///     resolving against the wrong vocabulary silently writes links that
    ///     point nowhere.
    ///   - current: the note the link was followed from, so a bare `#heading`
    ///     means "this note".
    ///   - createOnMiss: create a note when the target names none. The one
    ///     behaviour a caller might not want (a read-only preview, say), so it
    ///     is a parameter rather than an assumption.
    static func resolve(target: String,
                        in collection: Collection?,
                        current: Note?,
                        createOnMiss: Bool = true) async -> Destination {
        // The alias off before anything else: `[[https://example.com|the
        // page]]` is an address, and the alias is not part of it.
        if let url = URL(string: withoutAlias(target).trimmingCharacters(in: .whitespaces)),
           let scheme = url.scheme?.lowercased(),
           webSchemes.contains(scheme) {
            return .web(url)
        }
        guard let collection else { return .none }

        let (base, heading) = split(target)

        // `[[#heading]]` — an anchor within the note you are already reading.
        if base.isEmpty {
            guard let current else { return .none }
            return .note(current, heading: heading)
        }
        // The link graph first: it resolves aliases and relative paths, which a
        // title comparison structurally cannot.
        if let url = collection.linkGraph.resolve(base),
           let note = collection.notes.first(where: { $0.fileURL == url }) {
            return .note(note, heading: heading)
        }
        if let match = collection.notes.first(where: {
            $0.title.localizedCaseInsensitiveCompare(base) == .orderedSame
        }) {
            return .note(match, heading: heading)
        }
        guard createOnMiss, let made = await collection.createNote(title: base) else { return .none }
        return .note(made, heading: heading)
    }
}
