//
//  CollectionEmbedProvider.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(macOS)
import AppKit
import MarkdownEngine

/// Supplies images for `![[…]]` embeds. Note references (`![[Note]]` /
/// `![[Note#heading]]`) are transcluded: the target note's Markdown is rendered
/// to an image via ``NoteTranscluder``. Image-file references fall back to
/// loading the file from disk relative to a known note.
///
/// The engine caches embed images by reference + `fingerprint()`, so a `revision`
/// bump (on any collection change) is what makes a stale transclusion re-render.
/// Reads the target note lazily on `image(for:)` and caches by content.
final class CollectionEmbedProvider: EmbeddedImageProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var notesByName: [String: URL] = [:]   // lowercased title → file URL
    private var revision = 0
    private var cache: [String: NSImage] = [:]

    /// Refresh the name→URL map and invalidate the engine's embed cache.
    func update(notes: [Note]) {
        lock.lock(); defer { lock.unlock() }
        notesByName = Dictionary(
            notes.map { ($0.title.lowercased(), $0.fileURL) },
            uniquingKeysWith: { first, _ in first }
        )
        revision += 1
    }

    func fingerprint() -> AnyHashable {
        lock.lock(); defer { lock.unlock() }
        return AnyHashable(revision)
    }

    func image(for reference: EmbeddedImageRequest) -> NSImage? {
        let (base, heading) = splitHeading(reference.name)

        lock.lock()
        let url = notesByName[base.lowercased()]
        lock.unlock()
        guard let url else { return nil }   // not a note → no transclusion

        // Key the cache on a cheap mtime `stat` (not a full read) so a cache hit
        // costs no file read, while a changed target still re-renders. The
        // engine invalidates its own cache on any collection change (`revision`),
        // so without this every unrelated edit re-read every visible embed.
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
