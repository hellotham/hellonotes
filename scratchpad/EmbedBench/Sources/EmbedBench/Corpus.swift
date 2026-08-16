//
//  Corpus.swift
//  EmbedBench
//
//  Loading the vault, and deriving ground truth from it.
//
//  ## Where the ground truth comes from
//
//  The plan called for hand-labelled pairs. The vault already contains
//  thousands of relatedness judgements made by the person whose vault it is —
//  every `[[wiki-link]]` is someone deciding, in context, that two notes belong
//  together. That is better evidence than anything a stranger could label from
//  the outside, and it is *the exact signal auto-linking has to reproduce*.
//
//  What this can and cannot measure, stated plainly because it decides how much
//  the numbers are worth:
//
//  - **Recall, yes.** Given a note, does the backend rank the notes the author
//    actually linked near the top? Comparable across backends, which is all
//    "choose the backend by measurement" needs.
//  - **Precision, no.** A pair the author did *not* link is not evidence they
//    are unrelated — the missing links are the whole reason auto-linking exists.
//    So every number here is a *lower bound*, and the precision floor the
//    feature must clear before shipping needs human review of real proposals.
//  - **Bias.** Index and map-of-content notes link to everything, and some links
//    are structural rather than semantic. Both are reported rather than hidden.
//
//  ## The validity control that matters most
//
//  If note A contains `[[Second Brain]]`, then the words "Second Brain" are
//  literally in A's text, and *any* method — including plain substring search —
//  finds B. That would measure nothing. So link markup is removed from the
//  embedded text entirely, target and display text alike, before any backend
//  sees it. Every backend then has to find B by meaning, not by echo.
//

import Foundation

struct Note {
    let url: URL
    let title: String
    /// Text as a backend sees it: no front matter, no code, no link markup.
    let text: String
    /// Note indices this note links to, resolved within the vault.
    var links: Set<Int> = []
    /// Chunk index range in the flat chunk array.
    var chunkRange: Range<Int> = 0..<0
}

enum Corpus {

    // MARK: - Loading

    /// Every `.md` file under `root`, skipping dot-directories.
    static func markdownFiles(under root: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e where url.pathExtension.lowercased() == "md" {
            out.append(url)
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Coordinated read. The vault lives in iCloud, and an uncoordinated read of
    /// a dataless file fails with EDEADLK rather than downloading it — the same
    /// rule the app itself follows (`Core/FileIO`).
    static func read(_ url: URL) -> String? {
        var result: String?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { actual in
            result = try? String(contentsOf: actual, encoding: .utf8)
        }
        return result
    }

    // MARK: - Cleaning

    private static let frontMatter = try! NSRegularExpression(
        pattern: #"\A---\r?\n.*?\r?\n---\r?\n"#, options: [.dotMatchesLineSeparators])
    private static let fencedCode = try! NSRegularExpression(
        pattern: "```[\\s\\S]*?```", options: [])
    /// `[[Target]]`, `[[Target|Display]]`, `![[Embed]]` — removed whole.
    private static let wikiLink = try! NSRegularExpression(
        pattern: #"!?\[\[[^\]\r\n]*\]\]"#, options: [])
    private static let mdLink = try! NSRegularExpression(
        pattern: #"!?\[([^\]\r\n]*)\]\([^)\r\n]*\)"#, options: [])
    private static let bareURL = try! NSRegularExpression(
        pattern: #"https?://\S+"#, options: [])
    private static let whitespace = try! NSRegularExpression(
        pattern: #"[ \t]*\n[ \t]*(\n[ \t]*)+"#, options: [])

    /// Strip everything that would let a backend cheat, or that is markup rather
    /// than meaning. Markdown link *text* is kept (it is prose); the destination
    /// is not.
    static func clean(_ raw: String) -> String {
        var t = raw as NSString
        func sub(_ re: NSRegularExpression, _ template: String) {
            t = re.stringByReplacingMatches(in: t as String, options: [],
                                            range: NSRange(location: 0, length: t.length),
                                            withTemplate: template) as NSString
        }
        sub(frontMatter, "")
        sub(fencedCode, " ")
        sub(wikiLink, " ")          // <- the validity control
        sub(mdLink, "$1")
        sub(bareURL, " ")
        sub(whitespace, "\n\n")
        return (t as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Ground truth

    private static let wikiTarget = try! NSRegularExpression(
        pattern: #"(?<!!)\[\[([^\|\]\r\n]*)(?:\|[^\]\r\n]+)?\]\]"#, options: [])
    /// `[text](Some Note.md)` — an equally deliberate link between two notes,
    /// and 418 notes in the measured vault use this form. Counting only
    /// wiki-links would discard that evidence for no reason.
    private static let mdNoteLink = try! NSRegularExpression(
        pattern: #"\]\(([^)\r\n]+?\.md)\)"#, options: [.caseInsensitive])

    /// A link target reduced to the key notes are indexed under.
    ///
    /// Obsidian resolves `[[Folder/Note]]`, `[[Note#Heading]]` and `[[Note]]` to
    /// the same file. Matching the raw target against note *titles* therefore
    /// misses every subfolder-qualified link — and in this vault the only links
    /// that resolve at all are subfolder-qualified, so getting this wrong drops
    /// the ground truth to near zero and makes the corpus look linkless.
    static func normaliseTarget(_ raw: String) -> String? {
        var t = raw.split(separator: "#", maxSplits: 1,
                          omittingEmptySubsequences: false).first.map(String.init) ?? raw
        t = t.removingPercentEncoding ?? t
        t = t.trimmingCharacters(in: .whitespaces)
        // Last path component, extension dropped — the file's title.
        if let slash = t.lastIndex(of: "/") { t = String(t[t.index(after: slash)...]) }
        if t.lowercased().hasSuffix(".md") { t = String(t.dropLast(3)) }
        t = t.trimmingCharacters(in: .whitespaces).lowercased()
        return t.isEmpty ? nil : t
    }

    /// Every deliberate note-to-note link in `raw`, as normalised titles.
    static func linkTargets(in raw: String) -> [String] {
        let ns = raw as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var out: [String] = []
        for re in [wikiTarget, mdNoteLink] {
            for m in re.matches(in: raw, options: [], range: whole) {
                guard m.range(at: 1).location != NSNotFound else { continue }
                if let t = normaliseTarget(ns.substring(with: m.range(at: 1))) { out.append(t) }
            }
        }
        return out
    }

    /// Load the vault: cleaned text per note, plus resolved link ground truth.
    static func load(root: URL, limit: Int?) -> [Note] {
        var files = markdownFiles(under: root)
        // Stride-sample rather than take a prefix. Files are sorted by path, so
        // a prefix is *one folder* — the first 200 of this vault contained no
        // wiki-links at all and reported "nothing to measure", which looks like
        // a broken harness and is really a broken sample.
        if let limit, files.count > limit {
            let stride = Double(files.count) / Double(limit)
            files = (0..<limit).map { files[min(files.count - 1, Int(Double($0) * stride))] }
        }

        var raws: [String] = []
        var notes: [Note] = []
        for url in files {
            guard let raw = read(url) else { continue }
            let title = url.deletingPathExtension().lastPathComponent
            let text = clean(raw)
            // A note with almost no prose cannot be embedded meaningfully and
            // would only add noise to both sides of the comparison.
            guard text.count >= 80 else { continue }
            raws.append(raw)
            notes.append(Note(url: url, title: title, text: text))
        }

        // Resolve targets to indices by title (the app resolves by title/alias;
        // title alone is the conservative subset, and an unresolved target is
        // simply not counted rather than guessed at).
        var indexByTitle: [String: Int] = [:]
        for (i, n) in notes.enumerated() { indexByTitle[n.title.lowercased()] = i }

        for i in notes.indices {
            var resolved = Set<Int>()
            for target in linkTargets(in: raws[i]) {
                if let j = indexByTitle[target], j != i { resolved.insert(j) }
            }
            notes[i].links = resolved
        }
        return notes
    }
}
