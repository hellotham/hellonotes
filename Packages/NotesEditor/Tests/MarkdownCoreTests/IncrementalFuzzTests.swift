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
