//
//  CollectionEmbedProvider.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(macOS)
import AppKit

/// Renders `![[Note]]` / `![[Note#heading]]` transclusions to images. The
/// target note's Markdown is rendered to a titled card via ``NoteTranscluder``;
/// non-note targets (image files) return nil (the editor loads those directly).
///
/// Reads the target note lazily on `image(forName:)` and caches by content
/// (keyed on a cheap mtime `stat` + appearance) so repeat renders are free.
final class CollectionEmbedProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var notesByName: [String: URL] = [:]   // lowercased title → file URL
    private var revision = 0
    private var cache: [String: NSImage] = [:]

    /// Refresh the name→URL map and invalidate cached cards. A `revision` bump
    /// (on any collection change) is what makes a stale transclusion re-render.
    func update(notes: [Note]) {
        lock.lock(); defer { lock.unlock() }
        notesByName = Dictionary(
            notes.map { ($0.title.lowercased(), $0.fileURL) },
            uniquingKeysWith: { first, _ in first }
        )
        revision += 1
    }

    /// A rendered transclusion card for an `![[Note]]` target, or nil when the
    /// target isn't a note in this collection. Main-actor (NoteTranscluder
    /// uses `lockFocus`).
    @MainActor
    func image(forName name: String) -> NSImage? {
        let (base, heading) = splitHeading(name)

        lock.lock()
        let url = notesByName[base.lowercased()]
        lock.unlock()
        guard let url else { return nil }   // not a note → no transclusion

        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let key = "\(isDark ? "d" : "l")\u{1}\(url.path)\u{1}\(heading ?? "")\u{1}\(mtime)"

        lock.lock()
        if let cached = cache[key] { lock.unlock(); return cached }
        lock.unlock()

        guard let markdown = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let sectioned = NoteTranscluder.section(heading, from: markdown)
        let title = heading.map { "\(base) › \($0)" } ?? base
        guard let image = NoteTranscluder.image(markdown: sectioned, title: title, isDark: isDark) else { return nil }

        lock.lock(); cache[key] = image; lock.unlock()
        return image
    }

    private func splitHeading(_ name: String) -> (base: String, heading: String?) {
        guard let hash = name.firstIndex(of: "#") else { return (name, nil) }
        let base = String(name[..<hash])
        let heading = String(name[name.index(after: hash)...])
        return (base, heading.isEmpty ? nil : heading)
    }
}
#endif
