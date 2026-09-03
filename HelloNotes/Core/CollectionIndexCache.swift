//
//  CollectionIndexCache.swift
//  HelloNotes
//
//  Created by Chris Tham on 14/7/2026.
//
//  A persistent cache of each note's *parsed metadata* (headings, tags,
//  aliases, outgoing wiki-links), fingerprinted by mtime + size — the same
//  strategy Obsidian uses. On launch the cache is loaded and only notes whose
//  fingerprint changed are re-read and re-parsed, so a large collection is
//  fully indexed in milliseconds instead of seconds. The cache is purely
//  derived data: deleting it costs one full rebuild, never any user content.
//

import Foundation
import CryptoKit

/// One note's parsed metadata plus the stat fingerprint that validates it.
nonisolated struct NoteIndexRecord: Codable, Sendable {
    var relativePath: String
    var mtime: TimeInterval        // contentModificationDate, reference-date based
    var size: Int
    var aliases: [String]
    var tags: [String]
    var headings: [DocumentHeading]
    var outgoing: [String]         // wiki-link targets, in document order

    /// Whether this record still describes the file `note` points at.
    func matches(_ note: Note) -> Bool {
        size == note.fileSize
            && abs(mtime - note.lastModified.timeIntervalSinceReferenceDate) < 0.001
    }
}

nonisolated enum CollectionIndexCache {

    /// Rebuild the note list from the cache alone, without touching the disk.
    ///
    /// A record carries everything a `Note` needs — its path, its size, its
    /// modification date — so a collection can be *opened* from the cache and
    /// only walked when there is a reason to. `activate` used to walk the whole
    /// vault every launch before anything could be shown; on a 2,000-note vault
    /// in iCloud that is the startup.
    ///
    /// `isOnlineOnly` is left false: it is a property of the file's current
    /// materialisation rather than of its content, it changes without the file
    /// changing, and the only cost of guessing wrong is a cloud badge that
    /// appears a moment late.
    static func notes(for root: URL) -> [Note]? {
        guard let records = load(for: root), !records.isEmpty else { return nil }
        return records.values
            // An absolute path here is a record written before `relativePath`
            // could see past `/var` vs `/private/var`. Appending it to the root
            // produces a URL for a file that does not exist, so the note is
            // dropped and the folder walk supplies it instead.
            .filter { !$0.relativePath.hasPrefix("/") }
            .map { record in
            let url = root.appending(path: record.relativePath)
            return Note(title: url.deletingPathExtension().lastPathComponent,
                        fileURL: url,
                        lastModified: Date(timeIntervalSinceReferenceDate: record.mtime),
                        fileSize: record.size)
        }
        .sorted { $0.lastModified > $1.lastModified }
    }

    /// Bump when the record format **or what the parse extracts** changes; a
    /// version mismatch simply forces one full rebuild.
    ///
    /// 2 — tags no longer include link fragments. The cache is keyed on each
    ///     file's mtime and size, so fixing the *parser* changed nothing on
    ///     disk and every note kept serving the tags the old parser had
    ///     written. A parser fix is a cache invalidation.
    static let version = 2

    private struct Snapshot: Codable {
        var version: Int
        var records: [NoteIndexRecord]
    }

    // MARK: - Parse

    /// Everything the index needs from one note, extracted in a single place so
    /// the cache, the full rebuild, and the per-save update all agree.
    static func parse(_ text: String) -> (headings: [DocumentHeading], tags: [String], aliases: [String], outgoing: [String]) {
        (MarkdownParsing.fastHeadings(in: text),
         MarkdownParsing.tags(in: text),
         MarkdownParsing.aliases(in: text),
         MarkdownParsing.wikiLinkTargets(in: text))
    }

    /// Build the record for `note` from its text.
    static func record(for note: Note, relativeTo root: URL, text: String) -> NoteIndexRecord {
        let parsed = parse(text)
        return NoteIndexRecord(
            relativePath: relativePath(of: note.fileURL, in: root),
            mtime: note.lastModified.timeIntervalSinceReferenceDate,
            size: note.fileSize,
            aliases: parsed.aliases,
            tags: parsed.tags,
            headings: parsed.headings,
            outgoing: parsed.outgoing
        )
    }

    // MARK: - Load / save

    /// Cached records keyed by relative path, or `nil` when there is no usable
    /// cache (first run, version mismatch, or a corrupt file).
    static func load(for rootURL: URL) -> [String: NoteIndexRecord]? {
        guard let data = try? Data(contentsOf: cacheURL(for: rootURL)),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == version else { return nil }
        return Dictionary(snapshot.records.map { ($0.relativePath, $0) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// Persist `records` atomically. Failures are non-fatal — the cache is an
    /// optimisation, and the next launch just rebuilds.
    static func save(_ records: [NoteIndexRecord], for rootURL: URL) {
        let url = cacheURL(for: rootURL)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Snapshot(version: version, records: records)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Remove the cache (used by Rescan to guarantee a from-scratch rebuild).
    static func remove(for rootURL: URL) {
        try? FileManager.default.removeItem(at: cacheURL(for: rootURL))
    }

    // MARK: - Paths

    /// A note's path relative to the collection root.
    ///
    /// **`/var` and `/private/var` are the same directory and
    /// `standardizedFileURL` does not unify them.** It resolves `.` and `..`
    /// and nothing else. So a root spelled one way and a file URL spelled the
    /// other shared no prefix, this returned the *absolute* path as though it
    /// were relative, and the cache stored it — after which `notes(for:)` built
    /// `root.appending(path: "/private/var/…/Note.md")`, a URL for a file that
    /// does not exist. The collection then disagreed with itself about what its
    /// own notes were called: the cache-painted picture never matched the
    /// walked one, and a merge could not tell a note in an unreadable subtree
    /// from a note that had been deleted.
    ///
    /// Both spellings of the *root* are tried, which costs one `stat` per call
    /// site rather than one per note — the per-file form is what
    /// `ResumableTreeWalk`'s own notes warn about, where a resource lookup per
    /// file cost seconds of blocked main thread.
    static func relativePath(of fileURL: URL, in root: URL) -> String {
        let file = fileURL.standardizedFileURL.path
        for base in rootPrefixes(root) where file.hasPrefix(base) {
            return String(file.dropFirst(base.count))
        }
        return file
    }

    /// Every spelling of `root` a file URL under it might carry, each ending in
    /// a separator so `"Notes"` cannot prefix-match `"NotesArchive"`.
    ///
    /// **`resolvingSymlinksInPath` is not enough, and it fails in the direction
    /// that surprises you.** It normalises *towards* the short name: given
    /// `/private/var/x` it returns `/var/x`, not the other way round. So asking
    /// it for "the other spelling" of a root already written as `/var/…` returns
    /// the same string, and the set had one element where it needed two.
    ///
    /// That is exactly the shape CI failed in. `FileManager.temporaryDirectory`
    /// reported the root as `/var/folders/…` while
    /// `contentsOfDirectory(at:)` reported every file under it as
    /// `/private/var/folders/…`, no prefix matched, and a merge could not place
    /// a single note inside the collection it had just walked — so it kept a
    /// note that had been deleted, on the grounds that it might live somewhere
    /// the walk had not reached.
    ///
    /// The long form is therefore added by hand. `/private` in front of a path
    /// that is not `/var` or `/tmp` names nothing and simply never matches.
    static func rootPrefixes(_ root: URL) -> [String] {
        var forms = Set<String>()
        for base in [root.standardizedFileURL.path,
                     root.resolvingSymlinksInPath().standardizedFileURL.path] {
            forms.insert(base)
            if base.hasPrefix("/private/") {
                forms.insert(String(base.dropFirst("/private".count)))
            } else {
                forms.insert("/private" + base)
            }
        }
        return forms.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
    }

    /// `Application Support/HelloNotes/IndexCache/<hash>.json`, keyed by the
    /// collection's root path (mirrors `ChatSessionStore`'s per-collection files).
    static func cacheURL(for rootURL: URL) -> URL {
        let base = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("HelloNotes/IndexCache", isDirectory: true)
        let digest = SHA256.hash(data: Data(rootURL.standardizedFileURL.path.utf8))
        let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent("\(name).json")
    }
}
