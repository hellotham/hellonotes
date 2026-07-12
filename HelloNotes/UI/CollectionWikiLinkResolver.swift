//
//  CollectionWikiLinkResolver.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(macOS)
import Foundation
import MarkdownEngine

/// Tells MarkdownEngine which `[[wiki-link]]` targets exist so links to real
/// notes render as clickable links (and broken ones appear muted).
///
/// It only ever reports `exists` — it never returns a non-empty `id`. That
/// matters: the editor writes a resolver's id back into the file as
/// `[[Name|id]]`. By resolving purely on title existence we keep the user's
/// `[[Name]]` text byte-for-byte intact.
///
/// The known-title set is updated from the main actor as the collection changes;
/// `resolve`/`fingerprint` may be called off the main actor during styling, so
/// access is lock-guarded.
final class CollectionWikiLinkResolver: WikiLinkResolver, @unchecked Sendable {
    private let lock = NSLock()
    private var titles: Set<String> = []
    private var revision = 0

    /// Replace the set of existing note titles (case-insensitive). Bumping the
    /// revision changes `fingerprint()`, which makes the editor restyle links —
    /// so a newly-created target becomes clickable immediately.
    func update(titles newTitles: some Sequence<String>) {
        lock.lock(); defer { lock.unlock() }
        titles = Set(newTitles.map { $0.lowercased() })
        revision += 1
    }

    func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? {
        lock.lock(); defer { lock.unlock() }
        // A `[[Note#heading]]` target resolves on the note title alone — the
        // `#heading` fragment locates a spot *within* that note and isn't part of
        // its filename. Strip it before the existence check so heading links
        // render as resolved (and therefore clickable → navigable) rather than
        // muted. The full `displayName` (heading included) is still what the
        // editor hands back to `onLinkClick`, so the host can scroll to it.
        let base = displayName.split(separator: "#", maxSplits: 1,
                                     omittingEmptySubsequences: false).first
            .map(String.init) ?? displayName
        let exists = titles.contains(base.lowercased())
        return WikiLinkResolution(id: "", exists: exists)
    }

    func fingerprint() -> AnyHashable {
        lock.lock(); defer { lock.unlock() }
        return AnyHashable(revision)
    }
}
#endif
