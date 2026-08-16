//
//  DeclinedLinkStore.swift
//  HelloNotes
//
//  Created by Chris Tham on 16/8/2026.
//
//  Remembering "never link that".
//
//  Without this, auto-linking is a nuisance rather than a feature: every review
//  re-proposes everything previously rejected, so the twentieth pass costs the
//  same as the first and the rejections have to be made again. The whole reason
//  the spell-check metaphor works is that "Ignore" means *ignore*.
//
//  Stored per collection, beside the index cache and for the same reason: it is
//  about one vault, it must not follow the user to a different one, and losing
//  it costs some repeated clicks rather than any content.
//
//  Deliberately **not** kept in the notes themselves. A rejection is a personal
//  editorial decision, and writing it into the Markdown would put it in Git, in
//  every sync, and in front of every collaborator.
//

import Foundation
import CryptoKit

/// The set of proposals a user has said "never" to, for one collection.
nonisolated final class DeclinedLinkStore {
    private var keys: Set<String>
    private let fileURL: URL

    init(collectionRoot: URL) {
        fileURL = Self.storeURL(for: collectionRoot)
        keys = Self.load(from: fileURL)
    }

    func contains(_ key: String) -> Bool { keys.contains(key) }

    var all: Set<String> { keys }

    /// Record a rejection and persist it.
    func decline(_ key: String) {
        guard keys.insert(key).inserted else { return }
        save()
    }

    /// Forget every rejection — the escape hatch for a user who has said "never"
    /// to something they now want, and cannot otherwise get back.
    func reset() {
        guard !keys.isEmpty else { return }
        keys.removeAll()
        save()
    }

    // MARK: - Persistence

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(keys.sorted())
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Derived, personal, and re-earnable: a failure here costs the user
            // some repeated clicks, so it must never interrupt them.
        }
    }

    private static func load(from url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }

    /// `Application Support/HelloNotes/DeclinedLinks/<hash>.json`, keyed by the
    /// collection root — the same scheme as `CollectionIndexCache`.
    static func storeURL(for rootURL: URL) -> URL {
        let base = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("HelloNotes/DeclinedLinks", isDirectory: true)
        let digest = SHA256.hash(data: Data(rootURL.standardizedFileURL.path.utf8))
        let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent("\(name).json")
    }
}
