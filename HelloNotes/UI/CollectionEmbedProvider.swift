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
/// guarded by `lock`; `update(notes:)` may be called from any thread, while
/// `image(forName:)` is `@MainActor`. The lock makes the shared state safe to
/// touch across those isolation domains.
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
    /// target isn't a note in this collection. Main-actor (NoteTranscluder
    /// draws with the platform graphics context).
    @MainActor
    func image(forName name: String, isDark: Bool) -> PlatformImage? {
        let (base, heading) = splitHeading(name)

        lock.lock()
        let url = notesByName[base.lowercased()]
        lock.unlock()
        guard let url else { return nil }   // not a note → no transclusion

        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        let key = "\(isDark ? "d" : "l")\u{1}\(url.path)\u{1}\(heading ?? "")\u{1}\(mtime)"

        lock.lock()
        if let cached = cache[key] { lock.unlock(); return cached }
        lock.unlock()

        guard let markdown = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let sectioned = NoteTranscluder.section(heading, from: markdown)
        let title = heading.map { "\(base) › \($0)" } ?? base
        guard let image = NoteTranscluder.image(markdown: sectioned, title: title, isDark: isDark) else { return nil }

        lock.lock()
        // Keys are mtime-versioned, so an edited note's old cards would otherwise
        // accumulate forever. Bound the cache (like the editor's own image caches).
        if cache.count > 64 { cache.removeAll(keepingCapacity: true) }
        cache[key] = image
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
