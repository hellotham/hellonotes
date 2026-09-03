//
//  LinkGraph.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import Foundation
import Observation

/// Builds and holds the collection's `[[wiki-link]]` graph: for any note, which
/// notes link *to* it (backlinks) and which it links *out* to. Link targets are
/// resolved through note titles, their `aliases:`, **and their path suffixes**,
/// so `[[alias]]` and `[[Manual/Collections]]` both count as links to the note
/// they name. Rebuilt off the main actor when the note set or a note's contents
/// change.
///
/// The path suffixes were missing until they were seen to be missing: the graph
/// window drew the bundled manual's four pages as unlinked orphans while
/// `Manual/Index.md` linked to every one of them, because a title-only
/// resolution map has no entry for `manual/collections`. Transclusion had
/// resolved paths for a while by then, which is the shape of this bug — two
/// resolvers for one question, and only one of them fixed.
@MainActor
@Observable
final class LinkGraph {
    /// Backlink index: canonical note URL → the set of note URLs linking to it.
    private(set) var backlinksByURL: [URL: Set<URL>] = [:]

    /// Outgoing index: note URL → its wiki-link targets, in document order.
    private(set) var outgoingByURL: [URL: [String]] = [:]

    /// Resolution map: lowercased title or alias → the note's URL.
    private(set) var resolution: [String: URL] = [:]

    /// Rebuild the entire graph from the current notes. Reads every file off the
    /// main actor. (A future optimisation is incremental per-note updates.)
    func rebuild(from notes: [Note], texts sharedTexts: [URL: String]? = nil) async {
        // Carry the online-only flag through: a mirror placeholder is a file
        // that exists with no content, which `isMaterialized` alone calls
        // available.
        let items = notes.map { ($0.fileURL, $0.title, FileIO.hasContentAvailable($0)) }
        let result = await Task.detached(priority: .utility) { () -> (back: [URL: Set<URL>], out: [URL: [String]], resolve: [String: URL]) in
            // Pass 1: read files (or use the shared texts), register title + aliases.
            var resolve: [String: URL] = [:]
            var loaded: [(URL, String)] = []
            for (url, title, hasContent) in items {
                let text: String
                if let sharedTexts {
                    guard let shared = sharedTexts[url] else { continue }
                    text = shared
                } else {
                    // Skip files whose content isn't local rather than download
                    // the vault — or index a placeholder as an empty note.
                    guard hasContent,
                          let read = try? FileIO.readString(at: url) else { continue }
                    text = read
                }
                loaded.append((url, text))
                if resolve[title.lowercased()] == nil { resolve[title.lowercased()] = url }
            }
            // **Three passes, each first-wins**, and the order is the ranking:
            // a title beats another note's alias, and both beat a path key we
            // derived. Within a rank the earliest note wins, which makes the
            // map a function of the (sorted) note list rather than of iteration
            // order — this used to be last-wins, so with two notes titled
            // "Index" the winner changed with the note order.
            //
            // First-wins is also what `CollectionEmbedProvider` has always
            // done. The two were the same question answered twice and they
            // disagreed: `[[Index]]` and `![[Index]]` could name different
            // notes in the same collection.
            for (url, text) in loaded {
                for alias in MarkdownParsing.aliases(in: text)
                where resolve[alias.lowercased()] == nil {
                    resolve[alias.lowercased()] = url
                }
            }
            for (url, _) in loaded {
                for key in MarkdownParsing.pathKeys(for: url) where resolve[key] == nil {
                    resolve[key] = url
                }
            }
            // Pass 2: index outgoing targets and resolved backlinks.
            var back: [URL: Set<URL>] = [:]
            var out: [URL: [String]] = [:]
            for (url, text) in loaded {
                let targets = MarkdownParsing.wikiLinkTargets(in: text)
                out[url] = targets
                for target in targets where !target.isEmpty {
                    if let dest = resolve[target.lowercased()] {
                        back[dest, default: []].insert(url)
                    }
                }
            }
            return (back, out, resolve)
        }.value

        backlinksByURL = result.back
        outgoingByURL = result.out
        resolution = result.resolve
    }

    /// Rebuild the entire graph from already-parsed metadata — no file reads.
    /// This is pure in-memory work (O(notes + links), a few ms even for
    /// thousands of notes), so it's always correct to call after any change:
    /// backlinks and alias resolution are derived fresh from every record.
    func load(pairs: [(note: Note, record: NoteIndexRecord)]) {
        // Titles, then aliases, then path keys — each first-wins. See
        // `rebuild(from:)` for why the ranking and the first-wins matter.
        var resolve: [String: URL] = [:]
        for (note, _) in pairs where resolve[note.title.lowercased()] == nil {
            resolve[note.title.lowercased()] = note.fileURL
        }
        for (note, record) in pairs {
            for alias in record.aliases where resolve[alias.lowercased()] == nil {
                resolve[alias.lowercased()] = note.fileURL
            }
        }
        for (note, _) in pairs {
            for key in MarkdownParsing.pathKeys(for: note.fileURL) where resolve[key] == nil {
                resolve[key] = note.fileURL
            }
        }
        var back: [URL: Set<URL>] = [:]
        var out: [URL: [String]] = [:]
        for (note, record) in pairs {
            out[note.fileURL] = record.outgoing
            for target in record.outgoing where !target.isEmpty {
                if let dest = resolve[target.lowercased()] {
                    back[dest, default: []].insert(note.fileURL)
                }
            }
        }
        backlinksByURL = back
        outgoingByURL = out
        resolution = resolve
    }

    /// Incrementally re-index a single note from its in-memory text — no disk
    /// read, no whole-vault rebuild. Correct when the note's title and aliases
    /// are unchanged (an alias/title change can alter *other* notes' backlinks,
    /// so the caller must full-rebuild in that case).
    func updateNote(url: URL, title: String, text: String) {
        // Drop this note's previous outgoing contributions from the backlinks.
        for target in outgoingByURL[url] ?? [] where !target.isEmpty {
            if let dest = resolution[target.lowercased()] {
                backlinksByURL[dest]?.remove(url)
            }
        }
        // Its title/aliases still resolve to it (idempotent in the unchanged case).
        resolution[title.lowercased()] = url
        for alias in MarkdownParsing.aliases(in: text) { resolution[alias.lowercased()] = url }
        for key in MarkdownParsing.pathKeys(for: url) where resolution[key] == nil {
            resolution[key] = url
        }
        // Recompute this note's outgoing targets and resolved backlinks.
        let targets = MarkdownParsing.wikiLinkTargets(in: text)
        outgoingByURL[url] = targets
        for target in targets where !target.isEmpty {
            if let dest = resolution[target.lowercased()] {
                backlinksByURL[dest, default: []].insert(url)
            }
        }
    }

    /// The notes that link to `note` (via its title or any alias), excluding
    /// self-references.
    func backlinks(for note: Note, in notes: [Note]) -> [Note] {
        let urls = backlinksByURL[note.fileURL] ?? []
        guard !urls.isEmpty else { return [] }
        return notes.filter { $0.fileURL != note.fileURL && urls.contains($0.fileURL) }
    }

    /// The existing notes `note` links out to, in order, de-duplicated and
    /// excluding self-references. Unresolved (broken) targets are omitted.
    func outgoingLinks(for note: Note, in notes: [Note]) -> [Note] {
        let byURL = Dictionary(notes.map { ($0.fileURL, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<URL>()
        var result: [Note] = []
        for target in outgoingByURL[note.fileURL] ?? [] {
            guard let dest = resolution[target.lowercased()],
                  dest != note.fileURL,
                  let linked = byURL[dest],
                  seen.insert(dest).inserted else { continue }
            result.append(linked)
        }
        return result
    }

    /// Resolve a link target (title or alias, case-insensitive) to a note URL.
    func resolve(_ target: String) -> URL? {
        resolution[target.lowercased()]
    }
}
