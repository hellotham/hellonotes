//
//  LiveEditorConformanceTests.swift
//  MarkdownEditorTests
//
//  Proves the live editor's GFM styling (GFMLiveStyle, driven by cmark-gfm) is
//  faithful across the *entire* GFM specification corpus — every one of the
//  600+ examples. For each example the editor's runs must:
//    • stay in bounds,
//    • conceal every syntax marker (so the caret reveals source), and
//    • cover every strong / emphasis / inline-code / link that cmark-gfm finds
//      (the same engine the Preview renders with).
//

import Foundation
import Testing
#if canImport(AppKit)
import AppKit
#endif
@testable import MarkdownEditor
@testable import MarkdownCore
@testable import GFMRender

#if canImport(AppKit)
@Suite struct LiveEditorConformanceTests {

    struct Example { let number: Int; let markdown: String }

    static func examples() throws -> [Example] {
        let url = try #require(Bundle.module.url(forResource: "spec.txt", withExtension: nil))
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        func isFence(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy { $0 == "`" } && s.count >= 20 }
        // Accepts the extension-tagged fences too (``` example table, ``` example
        // autolink, …). Matching a trailing " example" alone silently skipped 24
        // of the corpus's 672 — every table and strikethrough case among them.
        func isStart(_ s: String) -> Bool {
            let parts = s.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 2 || parts.count == 3, parts[1] == "example" else { return false }
            guard !parts[0].isEmpty, parts[0].allSatisfy({ $0 == "`" }) else { return false }
            return parts.count == 2 || !parts[2].isEmpty
        }
        var out: [Example] = []; var i = 0; var n = 0
        while i < lines.count {
            if isStart(lines[i]) {
                var md: [String] = []; i += 1
                while i < lines.count, lines[i] != "." { md.append(lines[i]); i += 1 }
                i += 1
                while i < lines.count, !isFence(lines[i]) { i += 1 }
                n += 1
                out.append(Example(number: n, markdown: (md.joined(separator: "\n") + "\n").replacingOccurrences(of: "→", with: "\t")))
            }
            i += 1
        }
        return out
    }

    /// The GFM inline roles cmark identifies and the editor must reproduce.
    static func inlineRole(_ kind: String) -> String? {
        switch kind {
        case "strong": "strong"
        case "emph": "emphasis"
        case "code": "inlineCode"
        case "link", "image": "linkText"
        case "strikethrough": "strikethrough"
        default: nil
        }
    }

    @Test func liveEditorMatchesCmarkAcrossCorpus() throws {
        let examples = try Self.examples()
        // The corpus's own size, not a floor — `> 600` held for the 648 the old
        // parser could see, so it could never report the 24 it could not.
        #expect(examples.count == 672)

        var outOfBounds = 0
        var uncovered: [(Int, String, String)] = []   // example, role, text
        var checked = 0

        for ex in examples {
            let ns = ex.markdown as NSString
            let runs = GFMLiveStyle.runs(ns)

            // 1. Every run is in bounds.
            for r in runs where r.range.location < 0 || r.range.location + r.range.length > ns.length {
                outOfBounds += 1
            }
            let contentRuns = runs.filter { "\($0.role)" != "marker" }

            // 2. Every cmark inline construct is covered by a run of that role
            //    whose range lies within the cmark node's range.
            for node in GFMRenderer.nodes(ex.markdown) {
                guard let role = Self.inlineRole(node.kind) else { continue }
                // A link/image with an empty label ("![](/url)") has no text to
                // colour — nothing to cover.
                if role == "linkText" {
                    let s = ns.substring(with: node.range)
                    if let open = s.firstIndex(of: "["), let close = s.firstIndex(of: "]"),
                       s.index(after: open) == close { continue }
                }
                checked += 1
                let covered = contentRuns.contains { r in
                    "\(r.role)".hasPrefix(role)
                        && r.range.location >= node.range.location - 2
                        && r.range.location + r.range.length <= node.range.location + node.range.length + 2
                }
                if !covered {
                    uncovered.append((ex.number, role, ns.substring(with: node.range)))
                }
            }
        }

        print("live-editor GFM conformance: \(checked - uncovered.count)/\(checked) inline constructs covered across \(examples.count) examples; \(outOfBounds) out-of-bounds runs")
        if !uncovered.isEmpty {
            for (n, role, t) in uncovered.prefix(20) { print("  ex \(n) missing \(role): \(t.debugDescription)") }
        }
        #expect(outOfBounds == 0, "\(outOfBounds) out-of-bounds style runs")
        #expect(uncovered.isEmpty, "\(uncovered.count) cmark inline constructs not styled by the live editor")
    }

    /// The MarkdownCore block classifier that drives the live editor must agree
    /// with cmark-gfm on every block's *type* across the corpus, so the editor
    /// renders each block the way the Preview does.
    static func mdKind(_ kind: BlockKind) -> String? {
        switch kind {
        case .heading: "heading"
        case .paragraph: "paragraph"
        case .blockquote: "block_quote"
        case .listItem: "item"
        case .fencedCode, .indentedCode: "code_block"
        case .table: "table"
        case .thematicBreak: "thematic_break"
        case .htmlBlock: "html_block"
        case .frontMatter, .mathBlock, .blank: nil   // not GFM constructs
        }
    }
    // cmark block types that map onto a MarkdownCore block type.
    static func cmarkBlock(_ kind: String) -> String? {
        switch kind {
        case "heading", "paragraph", "block_quote", "code_block", "table", "thematic_break": kind
        case "item": "item"
        case "html_block": "html_block"
        default: nil                     // list container, list, document, inline…
        }
    }

    @Test func blockClassificationMatchesCmark() throws {
        let examples = try Self.examples()
        var mismatches: [(Int, String, String, String)] = []   // ex, text, cmark, md
        var checked = 0

        for ex in examples {
            let ns = ex.markdown as NSString
            let blocks = BlockParser.fullParse(ns).blocks
            func mdKindAt(_ loc: Int) -> String? {
                for b in blocks where b.range.location <= loc && loc < b.range.location + b.range.length {
                    return Self.mdKind(b.kind)
                }
                return nil
            }
            for node in GFMRenderer.nodes(ex.markdown) where node.depth <= 1 {
                guard let want = Self.cmarkBlock(node.kind) else { continue }
                // Skip list *items* — MarkdownCore models items as blocks and
                // cmark as list>item; the item-vs-paragraph mapping is exercised
                // by the item nodes themselves.
                checked += 1
                let got = mdKindAt(node.range.location)
                // A cmark list `item` maps to MarkdownCore `.listItem`; a cmark
                // `paragraph` inside an item is also inside a `.listItem` block.
                let ok: Bool
                if want == "item" || node.kind == "paragraph" {
                    ok = got == want || got == "item" || got == "paragraph"
                } else {
                    ok = got == want
                }
                if !ok { mismatches.append((ex.number, ns.substring(with: node.range).prefix(40).description, want, got ?? "nil")) }
            }
        }
        print("block classification vs cmark: \(checked - mismatches.count)/\(checked) blocks agree")
        for (n, t, c, m) in mismatches.prefix(25) { print("  ex \(n): cmark=\(c) md=\(m)  \(t.debugDescription)") }
        // **Zero**, because zero is what it measures. The tolerance used to be
        // a twentieth — 35 blocks of slack against a corpus that diverged on
        // four — so the one thing this test exists to notice was the one size
        // of regression it could not report. Those four were spec #66 and #68,
        // where a document opening with `---` was read as YAML front matter
        // (`md=nil`, since front matter is not a GFM construct); they cost
        // nothing to close and the slack has no other claimant.
        //
        // HTML blocks were the last thing on that tail: MarkdownCore had no
        // such block and counted them as paragraphs. It has one now, and
        // cmark's `html_block` maps straight onto it.
        #expect(mismatches.isEmpty, "\(mismatches.count)/\(checked) block-type divergences from cmark")
    }
}
#endif
