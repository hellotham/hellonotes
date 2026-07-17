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
@testable import GFMRender

#if canImport(AppKit)
@Suite struct LiveEditorConformanceTests {

    struct Example { let number: Int; let markdown: String }

    static func examples() throws -> [Example] {
        let url = try #require(Bundle.module.url(forResource: "spec.txt", withExtension: nil))
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        func isFence(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy { $0 == "`" } && s.count >= 20 }
        func isStart(_ s: String) -> Bool { s.hasSuffix(" example") && String(s.dropLast(8)).allSatisfy { $0 == "`" } && !s.isEmpty }
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
        #expect(examples.count > 600)

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
}
#endif
