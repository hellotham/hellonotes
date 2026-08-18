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
/// `@unchecked Sendable`: every stored property (`notesByName`, `cache`) is
/// guarded by `lock`; both `update(notes:)` and `image(forName:isDark:)` may be
/// called from any thread. The lock makes the shared state safe to touch across
/// those isolation domains.
final class CollectionEmbedProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var notesByName: [String: URL] = [:]   // lowercased title → file URL
    private var cache: [String: PlatformImage] = [:]

    /// Refresh the name→URL map. Cached cards are keyed by the target's path +
    /// mtime + appearance, so an edited transclusion re-renders on its own once
    /// its file's mtime advances — no explicit invalidation needed here.
    func update(notes: [Note]) {
        lock.lock(); defer { lock.unlock() }
        notesByName = Dictionary(
            notes.map { ($0.title.lowercased(), $0.fileURL) },
            uniquingKeysWith: { first, _ in first }
        )
    }

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

        lock.lock()
        let url = notesByName[base.lowercased()]
        lock.unlock()
        guard let url else { return nil }   // not a note → no transclusion

        // `stat` and read together, in one hop off the main actor.
        let loaded = await offMain { () -> (key: String, markdown: String)? in
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            let key = "\(isDark ? "d" : "l")\u{1}\(url.path)\u{1}\(heading ?? "")\u{1}\(mtime)"
            guard let markdown = try? FileIO.readString(at: url) else { return nil }
            return (key, markdown)
        }
        guard let loaded else { return nil }

        lock.lock()
        if let cached = cache[loaded.key] { lock.unlock(); return cached }
        lock.unlock()

        let sectioned = NoteTranscluder.section(heading, from: loaded.markdown)
        let title = heading.map { "\(base) › \($0)" } ?? base
        guard let image = await MainActor.run(body: {
            NoteTranscluder.image(markdown: sectioned, title: title, isDark: isDark)
        }) else { return nil }

        lock.lock()
        // Keys are mtime-versioned, so an edited note's old cards would otherwise
        // accumulate forever. Bound the cache (like the editor's own image caches).
        if cache.count > 64 { cache.removeAll(keepingCapacity: true) }
        cache[loaded.key] = image
        lock.unlock()
        return image
    }

    private func splitHeading(_ name: String) -> (base: String, heading: String?) {
        guard let hash = name.firstIndex(of: "#") else { return (name, nil) }
        let base = String(name[..<hash])
        let heading = String(name[name.index(after: hash)...])
        return (base, heading.isEmpty ? nil : heading)
    }
}
