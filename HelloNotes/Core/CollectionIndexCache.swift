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

    static func relativePath(of fileURL: URL, in root: URL) -> String {
        let file = fileURL.standardizedFileURL.path
        var base = root.standardizedFileURL.path
        if !base.hasSuffix("/") { base += "/" }
        return file.hasPrefix(base) ? String(file.dropFirst(base.count)) : file
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
