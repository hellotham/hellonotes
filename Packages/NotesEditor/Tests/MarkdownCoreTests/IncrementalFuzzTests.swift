//
//  IncrementalFuzzTests.swift
//  MarkdownCoreTests
//
//  The kernel's central invariant, enforced by force: apply thousands of
//  random edits to documents assembled from Markdown-shaped fragments and
//  assert after every single one that the incrementally-updated parse is
//  identical to a from-scratch reparse. Any divergence prints the failing
//  document, edit, and seed for a deterministic repro.
//

import Foundation
import Testing
@testable import MarkdownCore

@Suite struct IncrementalFuzzTests {

    /// Deterministic PRNG so failures reproduce from the logged seed.
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private static let fragments = [
        "# Heading\n", "## Two\n", "plain paragraph text\n", "more text with **bold** and *it*\n",
        "\n", "```swift\n", "let x = 1\n", "```\n", "~~~\n",
        "- item one\n", "- [ ] task\n", "1. ordered\n", "  continued indent\n",
        "> quoted line\n", "> [!note]\n", "| a | b |\n", "|---|---|\n", "| 1 | 2 |\n",
        "---\n", "===\n", "$$\n", "x^2 + y\n", "Title\n",
        "text with [[Wiki Link]] inline\n", "a #tag and `code`\n", "%%comment%% visible\n",
    ]

    private static let insertions = [
        "x", " ", "\n", "#", "# ", "`", "```", "```\n", "*", "**", ">", "> ",
        "- ", "---", "---\n", "===", "|", "$$", "[[", "]]", "\n\n", "word",
        "[[Note]]", "**b**", "~~~\n", "    ", "\t",
    ]

    @Test func incrementalAlwaysMatchesFullReparse() {
        var rng = SplitMix(state: 0x48656C6C6F4E6F74) // fixed seed: reproducible
        for round in 0..<60 {
            // Assemble a document from 0–25 fragments.
            let fragmentCount = Int.random(in: 0...25, using: &rng)
            var doc = ""
            for _ in 0..<fragmentCount {
                doc += Self.fragments.randomElement(using: &rng)!
            }

            let ns = NSMutableString(string: doc)
            var parse = BlockParser.fullParse(ns as NSString)

            for step in 0..<40 {
                let len = ns.length
                let kind = Int.random(in: 0..<3, using: &rng)
                var range = NSRange(location: 0, length: 0)
                var replacement = ""
                switch kind {
                case 0: // insert
                    range = NSRange(location: Int.random(in: 0...len, using: &rng), length: 0)
                    replacement = Self.insertions.randomElement(using: &rng)!
                case 1: // delete
                    guard len > 0 else { continue }
                    let loc = Int.random(in: 0..<len, using: &rng)
                    let maxLen = min(len - loc, 24)
                    range = NSRange(location: loc, length: Int.random(in: 1...max(1, maxLen), using: &rng))
                default: // replace
                    guard len > 0 else { continue }
                    let loc = Int.random(in: 0..<len, using: &rng)
                    let maxLen = min(len - loc, 12)
                    range = NSRange(location: loc, length: Int.random(in: 0...maxLen, using: &rng))
                    replacement = Self.insertions.randomElement(using: &rng)!
                }
                // Never split a surrogate pair (all fragments are ASCII, but
                // guard anyway for future fragment additions).
                if range.location < len, UTF16.isTrailSurrogate(ns.character(at: range.location)) { continue }
                let end = range.location + range.length
                if end < len, UTF16.isTrailSurrogate(ns.character(at: end)) { continue }

                ns.replaceCharacters(in: range, with: replacement)
                let edit = TextEdit(range: range, replacementLength: (replacement as NSString).length)
                parse = BlockParser.incremental(ns as NSString, edit: edit, previous: parse)
                let full = BlockParser.fullParse(ns as NSString)

                if parse.blocks != full.blocks || parse.lines != full.lines {
                    Issue.record("""
                    Incremental diverged at round \(round) step \(step)
                    edit: \(range) ← \(replacement.debugDescription)
                    document after edit:
                    \((ns as String).debugDescription)
                    incremental: \(parse.blocks.map(\.kind))
                    full:        \(full.blocks.map(\.kind))
                    """)
                    return
                }
            }
        }
    }

    /// The shapes long notes are made of — prose, lists tight and loose and
    /// nested, items holding paragraphs, quotes with lazy lines, tables,
    /// indented code, HTML blocks — in documents long enough to have a tail
    /// worth keeping. The walk stops wherever it stands exactly where the old
    /// walk stood (`IncrementalConvergenceTests`), so every state it can stand
    /// in has to survive this: an open paragraph, a blank run, an item, a
    /// quote, a table, a code block, an HTML block, and the item above a blank
    /// line that decides what an indented marker under it is.
    private static let proseFragments = [
        "Plain prose sentence.\n", "another line of prose\n", "\n", "\n", "\n", "\n",
        "- item\n", "- [ ] task\n", "* star item\n", "+ plus\n", "1. one\n", "2. two\n", "1) paren\n",
        "  - nested\n", "    - deep marker\n", "   - three spaces\n", "  continuation\n",
        "    indented code\n", "\tTabbed\n", "-\n", "1.\n",
        "> quote\n", "> [!tip]\n", ">     quoted code\n", "> - quoted item\n", "lazy line\n",
        "| a | b |\n", "|---|---|\n", "| 1 | 2 |\n", "a | b\n", "--- | ---\n",
        "# H1\n", "Setext\n", "===\n", "---\n", "***\n",
        "```\n", "~~~\n", "  ```\n", "$$\n", "$$ x $$\n",
        "<div>\n", "</div>\n", "<!-- c\n", "-->\n", "<span>\n", "<pre>\n", "</pre>\n",
        "[ref]: /url\n", "text [[Wiki]] here\n",
    ]

    private static let proseInsertions = [
        "x", " ", "\n", "\n\n", "  ", "    ", "- ", "1. ", "2. ", "> ", "#", "# ", "|",
        "---", "===", "```", "<div>", "-->", "\t", "-", "*", "word", "\n- ", "\n    ",
    ]

    @Test(arguments: [0x50726F7365 as UInt64, 0x4C69737473, 0x51756F746573, 0x5461626C6573])
    func proseAndListsAlwaysMatchFullReparse(seed: UInt64) {
        var rng = SplitMix(state: seed)
        for round in 0..<50 {
            let fragmentCount = Int.random(in: 10...70, using: &rng)
            var doc = ""
            for _ in 0..<fragmentCount {
                doc += Self.proseFragments.randomElement(using: &rng)!
            }

            let ns = NSMutableString(string: doc)
            var parse = BlockParser.fullParse(ns as NSString)

            for step in 0..<50 {
                let len = ns.length
                var range = NSRange(location: 0, length: 0)
                var replacement = ""
                switch Int.random(in: 0..<4, using: &rng) {
                case 0, 1: // insert — the commonest edit is typing
                    range = NSRange(location: Int.random(in: 0...len, using: &rng), length: 0)
                    replacement = Self.proseInsertions.randomElement(using: &rng)!
                case 2: // delete
                    guard len > 0 else { continue }
                    let loc = Int.random(in: 0..<len, using: &rng)
                    range = NSRange(location: loc, length: Int.random(in: 1...max(1, min(len - loc, 16)), using: &rng))
                default: // replace
                    guard len > 0 else { continue }
                    let loc = Int.random(in: 0..<len, using: &rng)
                    range = NSRange(location: loc, length: Int.random(in: 0...min(len - loc, 8), using: &rng))
                    replacement = Self.proseInsertions.randomElement(using: &rng)!
                }

                ns.replaceCharacters(in: range, with: replacement)
                let edit = TextEdit(range: range, replacementLength: (replacement as NSString).length)
                parse = BlockParser.incremental(ns as NSString, edit: edit, previous: parse)
                let full = BlockParser.fullParse(ns as NSString)

                if parse.blocks != full.blocks || parse.lines != full.lines {
                    Issue.record("""
                    Incremental diverged with seed \(seed) at round \(round) step \(step)
                    edit: \(range) ← \(replacement.debugDescription)
                    document after edit:
                    \((ns as String).debugDescription)
                    incremental: \(parse.blocks.map { "\($0.firstLine)+\($0.lineCount) \($0.kind)" })
                    full:        \(full.blocks.map { "\($0.firstLine)+\($0.lineCount) \($0.kind)" })
                    """)
                    return
                }
            }
        }
    }

    @Test func lineIndexSpliceMatchesRebuild() {
        var rng = SplitMix(state: 0x4C696E6573)
        var text = NSMutableString(string: "alpha\nbeta\ngamma\n\ndelta")
        var index = LineIndex(text: text as NSString)
        for step in 0..<2_000 {
            let len = text.length
            let insert = Bool.random(using: &rng) || len == 0
            var range = NSRange(location: 0, length: 0)
            var replacement = ""
            if insert {
                range = NSRange(location: Int.random(in: 0...len, using: &rng), length: 0)
                replacement = ["x", "\n", "ab\ncd", "\n\n", "tail"].randomElement(using: &rng)!
            } else {
                let loc = Int.random(in: 0..<len, using: &rng)
                range = NSRange(location: loc, length: Int.random(in: 1...min(len - loc, 8), using: &rng))
            }
            text.replaceCharacters(in: range, with: replacement)
            index.apply(TextEdit(range: range, replacementLength: (replacement as NSString).length), newText: text as NSString)
            let rebuilt = LineIndex(text: text as NSString)
            if index != rebuilt {
                Issue.record("LineIndex splice diverged at step \(step): \(index.starts) vs \(rebuilt.starts) for \((text as String).debugDescription)")
                return
            }
        }
        _ = (text, index)
    }
}
