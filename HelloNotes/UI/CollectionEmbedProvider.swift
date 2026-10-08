//
//  CollectionEmbedProvider.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import Foundation
import MarkdownEditor   // PlatformImage

/// Renders `![[Note]]` / `![[Note#heading]]` transclusions to images. The
/// target note's Markdown is rendered to a titled card via ``NoteTranscluder``;
/// non-note targets (image files) return nil (the editor loads those directly).
///
/// Reads the target note lazily on `image(forName:isDark:)` and caches by
/// content (keyed on a cheap mtime `stat` + appearance) so repeat renders are
/// free. Cross-platform.
///
/// **`nonisolated`, and `@unchecked Sendable` because of `lock`**, which
/// guards `notesByName` and `cache`: `update(notes:)` is called on the main
/// actor and `image(forName:isDark:)` from wherever a card is wanted — Edit's
/// renderer on the main actor, Preview's page on the pool. Unannotated, the
/// class was main-actor in this target, so the lock guarded nothing and
/// Preview's every card hopped to the main actor (implemented.md §51.36).
nonisolated final class CollectionEmbedProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var notesByName: [String: URL] = [:]   // lowercased title → file URL
    private var cache = BoundedCache<String, PlatformImage>(limit: 64)

    /// The collection whose notes this draws — set by the collection. A
    /// provider of a view's own has none.
    @MainActor weak var owner: Collection?

    /// Moves when what a card shows may have: a note saved, a rebuild landed,
    /// the note set changed — the owner's `derivedRevision`, read through, so
    /// a view that reads this in its body is redrawn when that moves.
    ///
    /// Preview was handed the revision beside the provider, as
    /// `collection?.derivedRevision ?? 0`, by a pane the main window gives no
    /// collection — so it was always 0 there, and a card redrew only when the
    /// open note itself changed (implemented.md §51.36). Coming with the
    /// cards, it goes wherever they go.
    @MainActor var revision: Int { owner?.derivedRevision ?? 0 }

    /// Refresh the name→URL map. Cached cards are keyed by the target's path +
    /// mtime + appearance, so an edited transclusion re-renders on its own once
    /// its file's mtime advances — no explicit invalidation needed here.
    func update(notes: [Note]) {
        lock.lock(); defer { lock.unlock() }
        // **Indexed by every trailing path a `![[target]]` might name, not by
        // title alone.**
        //
        // Wiki-link *navigation* resolves through `linkGraph`, which handles
        // aliases and relative paths — `WikiLinkNavigation.resolve` says so in
        // as many words. Transclusion had its own map keyed only on the title,
        // so the two resolvers disagreed about what a target meant:
        // `[[Examples/Nested Note]]` opened the note and
        // `![[Examples/Nested Note]]` rendered nothing at all. The shipped tour
        // uses the second form, so the one note in `DefaultCollection` that
        // demonstrates transclusion demonstrated it not working — on both
        // platforms, for anyone who opened it.
        //
        // Suffixes rather than a root-relative path, because this object is not
        // told the collection root and does not need to be: "Nested Note",
        // "Examples/Nested Note" and any deeper qualification all land on the
        // same file, and a title still wins a tie because it is inserted first.
        var map: [String: URL] = [:]
        for note in notes {
            let key = note.title.lowercased()
            if map[key] == nil { map[key] = note.fileURL }
        }
        for note in notes {
            for key in Self.pathKeys(for: note.fileURL) where map[key] == nil {
                map[key] = note.fileURL
            }
        }
        notesByName = map
    }

    /// The note a target names, or nil. Exposed so the resolver can be tested
    /// without rendering an image — the drawing needs a graphics context and
    /// the lookup is the part that was wrong.
    func url(forName name: String) -> URL? {
        let base = name.split(separator: "#", maxSplits: 1).first.map(String.init) ?? name
        lock.lock(); defer { lock.unlock() }
        return notesByName[base.lowercased()]
    }

    /// "Nested Note", "Examples/Nested Note", … — each trailing run of path
    /// components, extension dropped, lowercased.
    ///
    /// One definition, in `MarkdownParsing`, because `LinkGraph` needs the same
    /// answer: a target that transcludes must also be a link, and for a while
    /// `![[Manual/Collections]]` rendered a card while `[[Manual/Collections]]`
    /// counted as broken. Kept here as a name so the existing tests still read.
    static func pathKeys(for url: URL) -> [String] { MarkdownParsing.pathKeys(for: url) }

    /// A rendered transclusion card for an `![[Note]]` target, or nil when the
    /// target isn't a note in this collection.
    ///
    /// **`async`, and the file work happens off the main actor.** This used to
    /// be a synchronous `@MainActor` method that did a `stat` and a
    /// *coordinated read* inline — once per `![[transclusion]]` the editor laid
    /// out. Against a File Provider both of those are blocking XPC calls, so a
    /// note with a handful of transclusions could stall typing for as long as
    /// iCloud felt like taking. Only the drawing needs the main actor (it uses
    /// the platform graphics context), so only the drawing stays there.
    ///
    /// The caller (`BlockRenderAdapter.renderTransclusion`) already awaits, so
    /// this costs no extra machinery — no placeholder, no invalidation pass.
    func image(forName name: String, isDark: Bool) async -> PlatformImage? {
        let (base, heading) = splitHeading(name)

        // `withLock`, not `lock()` and `unlock()`: this is an `async` function,
        // where a suspension between the two would hold the lock across it —
        // Swift 6 refuses the pair here, and this target could only warn.
        let url = lock.withLock { notesByName[base.lowercased()] }
        guard let url else { return nil }   // not a note → no transclusion

        // **The note's date first, and its text only for a card not drawn.**
        // A card already drawn at this date is the card; the note was read
        // whole on every call, hit or miss — at each pause in typing in Edit
        // and each page in Preview.
        let key = await offMain { () -> String in
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            return "\(isDark ? "d" : "l")\u{1}\(url.path)\u{1}\(heading ?? "")\u{1}\(mtime)"
        }
        if let cached = lock.withLock({ cache[key] }) { return cached }

        // Read and sectioned off the main actor; only the drawing needs it.
        let sectioned = await offMain { () -> String? in
            guard let markdown = try? FileIO.readString(at: url) else { return nil }
            return NoteTranscluder.section(heading, from: markdown)
        }
        guard let sectioned else { return nil }
        let title = heading.map { "\(base) › \($0)" } ?? base
        guard let image = await MainActor.run(body: {
            NoteTranscluder.image(markdown: sectioned, title: title, isDark: isDark)
        }) else { return nil }

        // Keys are date-versioned, so an edited note's old cards would pile
        // up: the cache keeps 64, letting go of the one used longest ago. It
        // was emptied outright past 64, and the next page drew every card again.
        lock.withLock { cache[key] = image }
        return image
    }

    private func splitHeading(_ name: String) -> (base: String, heading: String?) {
        guard let hash = name.firstIndex(of: "#") else { return (name, nil) }
        let base = String(name[..<hash])
        let heading = String(name[name.index(after: hash)...])
        return (base, heading.isEmpty ? nil : heading)
    }
}
