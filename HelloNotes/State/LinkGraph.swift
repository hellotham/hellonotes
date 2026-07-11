//
//  LinkGraph.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import Foundation
import Observation

/// Builds and holds the vault's `[[wiki-link]]` graph: for any note, which
/// notes link *to* it (backlinks) and which it links *out* to. Link targets are
/// resolved through note titles **and** their `aliases:`, so `[[alias]]` counts
/// as a link to the aliased note. Rebuilt off the main actor when the note set
/// or a note's contents change.
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
    func rebuild(from notes: [Note]) async {
        let items = notes.map { ($0.fileURL, $0.title) }
        let result = await Task.detached(priority: .utility) { () -> (back: [URL: Set<URL>], out: [URL: [String]], resolve: [String: URL]) in
            // Pass 1: read files, register each note's title + aliases.
            var resolve: [String: URL] = [:]
            var texts: [(URL, String)] = []
            for (url, title) in items {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                texts.append((url, text))
                resolve[title.lowercased()] = url
                for alias in MarkdownParsing.aliases(in: text) {
                    resolve[alias.lowercased()] = url
                }
            }
            // Pass 2: index outgoing targets and resolved backlinks.
            var back: [URL: Set<URL>] = [:]
            var out: [URL: [String]] = [:]
            for (url, text) in texts {
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
