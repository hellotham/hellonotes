//
//  BlockParserTests.swift
//  MarkdownCoreTests
//

import Foundation
import Testing
@testable import MarkdownCore

@Suite struct BlockParserTests {

    private func kinds(_ text: String) -> [BlockKind] {
        BlockParser.fullParse(text as NSString).blocks.map(\.kind)
    }

    // MARK: - Tiling invariant

    @Test func blocksTileTheDocument() {
        let text = """
        # Title

        Paragraph one
        continues here.

        ```swift
        let x = 1
        ```

        - item
        > quote
        """
        let result = BlockParser.fullParse(text as NSString)
        var expected = 0
        for b in result.blocks {
            #expect(b.range.location == expected, "gap or overlap before \(b.kind)")
            expected = b.range.location + b.range.length
        }
        #expect(expected == (text as NSString).length)
    }

    // MARK: - Headings

    @Test func atxHeadings() {
        #expect(kinds("# One") == [.heading(level: 1, setext: false)])
        #expect(kinds("### Three") == [.heading(level: 3, setext: false)])
        #expect(kinds("####### seven") == [.paragraph])   // > 6 = paragraph
        #expect(kinds("#nospace") == [.paragraph])        // tag-like, not heading
    }

    @Test func setextHeadings() {
        #expect(kinds("Title\n===") == [.heading(level: 1, setext: true)])
        #expect(kinds("Title\n---") == [.heading(level: 2, setext: true)])
        // No open paragraph → dashes are a thematic break.
        #expect(kinds("---") == [.thematicBreak])
        #expect(kinds("Para\n\n---") == [.paragraph, .blank, .thematicBreak])
    }

    // MARK: - Fences

    @Test func closedFence() {
        let text = "```swift\ncode\n```"
        #expect(kinds(text) == [.fencedCode(info: "swift", closed: true)])
    }

    @Test func unclosedFenceSwallowsRest() {
        let text = "```\ncode\nmore text\n# not a heading"
        #expect(kinds(text) == [.fencedCode(info: "", closed: false)])
    }

    @Test func fenceCloseNeedsMatchingMarker() {
        // ~~~ cannot close ``` — the fence stays open to EOF.
        #expect(kinds("```\ncode\n~~~") == [.fencedCode(info: "", closed: false)])
        // A longer close run is fine.
        #expect(kinds("```\ncode\n`````") == [.fencedCode(info: "", closed: true)])
    }

    @Test func tildeFence() {
        #expect(kinds("~~~\nx\n~~~") == [.fencedCode(info: "", closed: true)])
    }

    // MARK: - Front matter

    @Test func frontMatterAtTop() {
        let text = "---\ntitle: Hi\n---\nBody"
        #expect(kinds(text) == [.frontMatter, .paragraph])
    }

    @Test func frontMatterRequiresClose() {
        // No closing fence → the dashes are a thematic break, not front matter.
        let text = "---\ntitle: Hi\nBody"
        let k = kinds(text)
        #expect(k.first == .thematicBreak)
        #expect(!k.contains(.frontMatter))
    }

    @Test func frontMatterOnlyAtLineZero() {
        let text = "Body\n\n---\nkey: value\n---"
        #expect(!kinds(text).contains(.frontMatter))
    }

    // MARK: - Quotes, callouts, lists, tables

    @Test func quoteRunsGroup() {
        #expect(kinds("> a\n> b") == [.blockquote(callout: nil)])
        #expect(kinds("> a\n\n> b") == [.blockquote(callout: nil), .blank, .blockquote(callout: nil)])
    }

    @Test func calloutDetected() {
        #expect(kinds("> [!note]\n> body") == [.blockquote(callout: "note")])
        #expect(kinds("> [!TIP] Title\n> body") == [.blockquote(callout: "tip")])
    }

    @Test func listItems() {
        let k = kinds("- one\n- two\n  continued\n1. ordered")
        #expect(k.count == 3)
        guard case .listItem(let a) = k[0], case .listItem(let b) = k[1], case .listItem(let c) = k[2] else {
            Issue.record("expected three list items, got \(k)"); return
        }
        #expect(a.isOrdered == false)
        #expect(b.isOrdered == false)
        #expect(c.isOrdered == true)
    }

    @Test func taskItems() {
        let k = kinds("- [ ] todo\n- [x] done")
        guard case .listItem(let a) = k[0], case .listItem(let b) = k[1] else {
            Issue.record("expected task items, got \(k)"); return
        }
        #expect(a.task == .unchecked)
        #expect(b.task == .checked)
    }

    @Test func tableNeedsDelimiterRow() {
        #expect(kinds("| a | b |\n|---|---|\n| 1 | 2 |") == [.table])
        // A pipe line alone is just a paragraph.
        #expect(kinds("| a | b |\njust text") == [.paragraph])
    }

    // MARK: - Math blocks

    @Test func mathBlock() {
        #expect(kinds("$$\nx^2\n$$") == [.mathBlock(closed: true)])
        #expect(kinds("$$x^2$$") == [.mathBlock(closed: true)])
        #expect(kinds("$$\nx^2") == [.mathBlock(closed: false)])
    }

    // MARK: - Incremental == full (targeted edits)

    private func assertIncrementalMatchesFull(_ original: String, edit: (NSRange, String)) {
        let old = BlockParser.fullParse(original as NSString)
        let ns = NSMutableString(string: original)
        ns.replaceCharacters(in: edit.0, with: edit.1)
        let textEdit = TextEdit(range: edit.0, replacementLength: (edit.1 as NSString).length)
        let incremental = BlockParser.incremental(ns as NSString, edit: textEdit, previous: old)
        let full = BlockParser.fullParse(ns as NSString)
        #expect(incremental.blocks == full.blocks, "incremental diverged for edit \(edit)")
        #expect(incremental.lines == full.lines)
    }

    @Test func incrementalTypedCharacter() {
        assertIncrementalMatchesFull("# Title\n\nBody text here", edit: (NSRange(location: 12, length: 0), "x"))
    }

    @Test func incrementalOpensFence() {
        // Typing ``` at the top flips everything below into a fence.
        assertIncrementalMatchesFull("Para\n\nMore\n\nText", edit: (NSRange(location: 0, length: 0), "```\n"))
    }

    @Test func incrementalClosesFence() {
        assertIncrementalMatchesFull("```\ncode\nmore\nrest", edit: (NSRange(location: 9, length: 0), "```\n"))
    }

    @Test func incrementalDeletesBlankBetweenParagraphs() {
        assertIncrementalMatchesFull("aaa\n\nbbb", edit: (NSRange(location: 4, length: 1), ""))
    }

    @Test func incrementalMakesSetext() {
        assertIncrementalMatchesFull("Title\nbody", edit: (NSRange(location: 6, length: 0), "===\n"))
    }

    @Test func incrementalEditInsideFrontMatter() {
        assertIncrementalMatchesFull("---\ntitle: x\n---\nBody", edit: (NSRange(location: 11, length: 1), "y"))
    }

    @Test func incrementalBreaksFrontMatterOpen() {
        // Deleting a dash from the opening fence dissolves the front matter.
        assertIncrementalMatchesFull("---\ntitle: x\n---\nBody", edit: (NSRange(location: 0, length: 1), ""))
    }

    @Test func incrementalPasteMultipleBlocks() {
        assertIncrementalMatchesFull("start\n\nend", edit: (NSRange(location: 7, length: 0), "# H\n\n- a\n- b\n\n"))
    }

    @Test func incrementalDeleteAcrossBlocks() {
        assertIncrementalMatchesFull("# H\n\npara one\n\n> quote\n\nlast", edit: (NSRange(location: 3, length: 14), ""))
    }

    @Test func incrementalAtVeryEnd() {
        assertIncrementalMatchesFull("abc\ndef", edit: (NSRange(location: 7, length: 0), "\nghi"))
    }

    @Test func incrementalEmptyDocumentInsert() {
        assertIncrementalMatchesFull("", edit: (NSRange(location: 0, length: 0), "# Hello"))
    }
}
