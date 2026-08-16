//
//  RetrievalText.swift
//  HelloNotes
//
//  Created by Chris Tham on 16/8/2026.
//
//  Turning a note file into the text a retrieval index should actually see.
//
//  Three jobs, each measured rather than assumed
//  (`docs/semantic-retrieval-benchmark.md`):
//
//  1. **Drop what isn't prose** — front matter, fenced code, URLs. A note's YAML
//     keys and its base64 image blobs are not what it is about.
//  2. **Drop link markup, keeping display text.** `[[Second Brain|second brains]]`
//     contributes "second brains" and not the target's title. Otherwise a note's
//     vector is partly made of the titles of notes it *already* links to, which
//     is the one thing a link suggester must not reward.
//  3. **Cap the length.** This is the part that carries the retrieval win: a
//     capped note vector scored 43.2% recall@5 against 40.3% for the whole file,
//     and beat every chunk-level scheme measured. A converted book chapter
//     should not get to dominate the vocabulary of a 2,000-note vault.
//

import Foundation

enum RetrievalText {

    /// How much of a note the index reads. From the benchmark: the cap is worth
    /// ~3 points of recall@5 *and* an order of magnitude of build time, because
    /// tokenising a whole converted book is most of the cost of indexing one.
    static let maxCharacters = 21_600

    /// A hard ceiling on any single span handed to a tokeniser or model.
    ///
    /// Load-bearing, not defensive. A note converted from a PDF can contain no
    /// sentence-ending punctuation at all, so a sentence tokeniser returns the
    /// entire note as one "sentence" — the measured vault holds one whose
    /// longest span was **327,680 characters** against a median of 839. Passing
    /// that to an embedding model aborts the process with `std::bad_alloc`; two
    /// full benchmark runs died on it before the length histogram was looked at.
    static let maxSpanCharacters = 900

    private static let frontMatter = try! NSRegularExpression(
        pattern: #"\A---\r?\n.*?\r?\n---\r?\n"#, options: [.dotMatchesLineSeparators])
    private static let fencedCode = try! NSRegularExpression(
        pattern: "```[\\s\\S]*?```", options: [])
    /// `[[Target]]`, `[[Target|Display]]`, `![[Embed]]`.
    private static let wikiLink = try! NSRegularExpression(
        pattern: #"!?\[\[[^\]\r\n]*?(?:\|([^\]\r\n]*))?\]\]"#, options: [])
    private static let mdLink = try! NSRegularExpression(
        pattern: #"!?\[([^\]\r\n]*)\]\([^)\r\n]*\)"#, options: [])
    private static let bareURL = try! NSRegularExpression(
        pattern: #"https?://\S+"#, options: [])
    private static let runsOfSpace = try! NSRegularExpression(
        pattern: #"\s{2,}"#, options: [])

    /// The text an index should store for `raw`.
    static func prepare(_ raw: String) -> String {
        var t = raw as NSString
        func sub(_ re: NSRegularExpression, _ template: String) {
            t = re.stringByReplacingMatches(in: t as String, options: [],
                                            range: NSRange(location: 0, length: t.length),
                                            withTemplate: template) as NSString
        }
        sub(frontMatter, "")
        sub(fencedCode, " ")
        // `$1` is the alias when one is present, empty otherwise — so the words
        // the author wrote survive and the target's title does not.
        sub(wikiLink, " $1 ")
        sub(mdLink, "$1")
        sub(bareURL, " ")
        sub(runsOfSpace, " ")
        let cleaned = (t as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(maxCharacters))
    }

    /// The terms an index counts: lowercased, ≥3 characters, no stop words.
    ///
    /// Deliberately not stemmed. Stemming was not measured, and the vault this
    /// was tuned on runs on proper nouns (*Bronkhorst*, *Pāli*) where stemming
    /// has nothing to gain and something to lose.
    static func terms(in text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 && !stopWords.contains($0) }
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "are", "was", "were",
        "have", "has", "had", "not", "but", "you", "your", "its", "they", "them",
        "their", "there", "then", "what", "when", "which", "who", "will", "would",
        "can", "could", "should", "about", "into", "than", "also", "more", "most",
        "some", "such", "only", "other", "been", "being", "over", "these", "those",
    ]
}
