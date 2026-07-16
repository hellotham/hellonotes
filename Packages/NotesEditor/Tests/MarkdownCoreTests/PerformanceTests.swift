//
//  PerformanceTests.swift
//  MarkdownCoreTests
//
//  Generous budgets that fail loudly if a change reintroduces O(document)
//  work on the editing path. These are ceilings, not targets — the real
//  numbers should be far lower (they're printed for the record).
//

import Foundation
import Testing
@testable import MarkdownCore

@Suite struct PerformanceTests {

    /// Budgets only mean anything with the optimizer on; a debug run prints
    /// the numbers but doesn't enforce ceilings.
    private static var isOptimizedBuild: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    /// ~1 MB of varied Markdown.
    private static func bigDocument() -> String {
        var doc = "---\ntitle: Perf\n---\n"
        let chunk = """
        # Section heading

        A paragraph with **bold**, *italic*, `code`, a [[Wiki Link]] and a #tag \
        plus some longer prose to pad the line out to something realistic.

        - list item one with [[Another Note|alias]]
        - [ ] a task item
        > A quote with ==highlight== and ~~strike~~.

        ```swift
        func example() -> Int { 42 }
        ```

        | col a | col b |
        |-------|-------|
        | 1     | 2     |

        """
        while doc.utf8.count < 1_048_576 { doc += chunk }
        return doc
    }

    @Test func fullParseOneMegabyteUnder50ms() {
        let text = Self.bigDocument() as NSString
        let t0 = DispatchTime.now()
        let result = BlockParser.fullParse(text)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        print("fullParse 1MB: \(String(format: "%.1f", ms)) ms, \(result.blocks.count) blocks")
        if Self.isOptimizedBuild { #expect(ms < 50, "full parse of 1 MB took \(ms) ms") }
        #expect(result.blocks.count > 1000)
    }

    @Test func incrementalKeystrokeUnderTwoMs() {
        let text = NSMutableString(string: Self.bigDocument())
        var parse = BlockParser.fullParse(text as NSString)

        // Simulate typing in the middle of the document.
        let mid = text.length / 2
        let insertAt = (parse.blockIndex(at: mid)).map { parse.blocks[$0].range.location } ?? mid

        var worst = 0.0
        var total = 0.0
        let keystrokes = 200
        for i in 0..<keystrokes {
            let range = NSRange(location: insertAt + i, length: 0)
            text.replaceCharacters(in: range, with: "x")
            let t0 = DispatchTime.now()
            parse = BlockParser.incremental(text as NSString, edit: TextEdit(range: range, replacementLength: 1), previous: parse)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
            worst = max(worst, ms)
            total += ms
        }
        print("incremental keystroke on 1MB: avg \(String(format: "%.3f", total / Double(keystrokes))) ms, worst \(String(format: "%.3f", worst)) ms")
        if Self.isOptimizedBuild { #expect(worst < 2.0, "worst keystroke reparse took \(worst) ms") }
    }

    @Test func inlineParseParagraphMicroseconds() {
        let para = "A paragraph with **bold**, *italic*, `code`, a [[Wiki Link]], https://x.io and a #tag." as NSString
        let range = NSRange(location: 0, length: para.length)
        // Warm up, then measure many iterations.
        _ = InlineParser.parse(para, in: range)
        let iterations = 2_000
        let t0 = DispatchTime.now()
        for _ in 0..<iterations { _ = InlineParser.parse(para, in: range) }
        let us = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / Double(iterations) / 1e3
        print("inline parse of a busy paragraph: \(String(format: "%.1f", us)) µs")
        if Self.isOptimizedBuild { #expect(us < 100, "inline parse took \(us) µs per paragraph") }
    }

    @Test func styleRunsForViewportUnderBudget() {
        let text = Self.bigDocument() as NSString
        let parse = BlockParser.fullParse(text)
        // A "viewport" of 60 blocks somewhere in the middle.
        let start = parse.blocks.count / 2
        let slice = parse.blocks[start..<min(start + 60, parse.blocks.count)]
        let t0 = DispatchTime.now()
        var runCount = 0
        for block in slice {
            runCount += StyleSpec.runs(for: block, text: text, lines: parse.lines).count
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        print("style 60 blocks: \(String(format: "%.2f", ms)) ms, \(runCount) runs")
        if Self.isOptimizedBuild { #expect(ms < 5, "styling a viewport of blocks took \(ms) ms") }
    }
}
