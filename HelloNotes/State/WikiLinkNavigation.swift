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

    /// Split `Note#heading` into its parts. An empty heading is no heading —
    /// `[[Note#]]` is a typo, not a request to jump to a nameless section.
    static func split(_ target: String) -> (base: String, heading: String?) {
        guard let hash = target.firstIndex(of: "#") else { return (target, nil) }
        let after = String(target[target.index(after: hash)...])
        return (String(target[..<hash]), after.isEmpty ? nil : after)
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
        if let url = URL(string: target),
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
