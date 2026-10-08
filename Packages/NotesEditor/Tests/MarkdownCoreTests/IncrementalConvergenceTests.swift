//
//  IncrementalConvergenceTests.swift
//  MarkdownCoreTests
//
//  The other half of the incremental parser's promise. `IncrementalFuzzTests`
//  holds it to *correct* — the same blocks as a full parse after every edit;
//  these hold it to *local*: an edit costs the lines around it, whatever is
//  below it.
//
//  The walk used to stop only where nothing at all was open, which in prose is
//  almost nowhere: between two paragraphs a blank run is open, between two
//  items the item above is. So a keystroke near the top of a note of plain
//  paragraphs, or of a long checklist, re-walked every line to the end of the
//  file — correct, and O(document) per keystroke. Each test below builds a
//  note thousands of lines long out of one shape and edits near its top.
//

import Foundation
import Testing
@testable import MarkdownCore

@Suite struct IncrementalConvergenceTests {

    /// Far less than any of the notes below is long, and a little more than
    /// any edit here needs — 3 to 7 lines when this was written, against 1,500
    /// to 7,500 before: the walk starts one block above the edit and stops once
    /// it stands where the old walk stood.
    private static let local = 12

    /// One unit of a note, repeated with its number until the note is long.
    struct Shape: Sendable, CustomTestStringConvertible {
        var name: String
        var unit: @Sendable (Int) -> String
        var testDescription: String { name }
    }

    private static let shapes: [Shape] = [
        Shape(name: "paragraphs") { "Paragraph \($0) has a sentence of prose in it,\nand a second line.\n\n" },
        Shape(name: "one-line paragraphs") { "Paragraph \($0) is a single line.\n\n" },
        Shape(name: "tight list") { "- item number \($0)\n" },
        Shape(name: "task list") { "- [ ] task number \($0)\n" },
        Shape(name: "numbered list") { "\($0 + 1). step number \($0)\n" },
        Shape(name: "loose list") { "- item number \($0)\n\n" },
        Shape(name: "items with paragraphs") { "- item number \($0)\n\n  more of item \($0)\n\n" },
        Shape(name: "nested list") { "- parent \($0)\n  - child \($0)\n" },
        Shape(name: "quotes") { "> quoted \($0)\n> more of it\n\n" },
        Shape(name: "lazy quotes") { "> quoted \($0)\nlazy line \($0)\n\n" },
        Shape(name: "callouts") { "> [!note]\n> body \($0)\n\n" },
        Shape(name: "tables") { "| a | b |\n|---|---|\n| \($0) | x |\n\n" },
        Shape(name: "indented code") { "Paragraph \($0)\n\n    code \($0)\n\n" },
        Shape(name: "html blocks") { "<div>\nblock \($0)\n</div>\n\n" },
        Shape(name: "prose and lists") { "Paragraph \($0)\n\n- a \($0)\n- b \($0)\n\n" },
        Shape(name: "headings and prose") { "## Section \($0)\nText under it.\nMore text.\n\n" },
    ]

    /// Apply one edit, check it against a full parse, and return what the walk
    /// cost. A fast wrong answer is not the thing being measured.
    private static func apply(_ replacement: String, at location: Int, deleting length: Int = 0,
                              to text: NSMutableString, _ parse: inout ParseResult,
                              _ comment: Comment) -> Int {
        let range = NSRange(location: location, length: length)
        text.replaceCharacters(in: range, with: replacement)
        let edit = TextEdit(range: range, replacementLength: (replacement as NSString).length)
        let (result, walked) = BlockParser.incrementalWalk(text, edit: edit, previous: parse)
        let full = BlockParser.fullParse(text)
        #expect(result.blocks == full.blocks, comment)
        parse = result
        return walked
    }

    @Test(arguments: shapes)
    func anEditNearTheTopWalksOnlyTheLinesAroundIt(_ shape: Shape) {
        var note = ""
        for n in 0..<1_500 { note += shape.unit(n) }
        let text = NSMutableString(string: note)
        var parse = BlockParser.fullParse(text)
        #expect(parse.lines.lineCount > 1_500)

        // Inside the third unit's first word: no structure moves.
        let third = (note as NSString).range(of: shape.unit(2)).location
        let word = third + (shape.unit(2) as NSString).range(of: "2").location

        var worst = 0
        worst = max(worst, Self.apply("x", at: word, to: text, &parse, "typing in \(shape.name)"))
        worst = max(worst, Self.apply("yz", at: word + 1, to: text, &parse, "typing again in \(shape.name)"))
        worst = max(worst, Self.apply("", at: word, deleting: 3, to: text, &parse, "deleting in \(shape.name)"))
        #expect(worst <= Self.local, "an edit near the top of \(shape.name) walked \(worst) lines")
    }

    /// Edits that change structure — a line split, a paragraph break, a join
    /// — still settle within a few blocks in prose.
    @Test func structuralEditsInProseStayLocal() {
        var note = ""
        for n in 0..<1_500 { note += "Paragraph \(n) has a sentence of prose in it,\nand a second line.\n\n" }
        let text = NSMutableString(string: note)
        var parse = BlockParser.fullParse(text)
        let at = (note as NSString).range(of: "Paragraph 3 has").location + 9

        var worst = 0
        worst = max(worst, Self.apply("\n", at: at, to: text, &parse, "splitting a line"))
        worst = max(worst, Self.apply("\n", at: at, to: text, &parse, "opening a paragraph break"))
        worst = max(worst, Self.apply("", at: at, deleting: 2, to: text, &parse, "closing it again"))
        worst = max(worst, Self.apply("# ", at: at - 9, to: text, &parse, "making a heading"))
        worst = max(worst, Self.apply("", at: at - 9, deleting: 2, to: text, &parse, "and back"))
        worst = max(worst, Self.apply("- ", at: at - 9, to: text, &parse, "making an item"))
        worst = max(worst, Self.apply("> ", at: at - 9, to: text, &parse, "quoting it"))
        #expect(worst <= Self.local, "a structural edit near the top walked \(worst) lines")
    }

    /// The fresh walk starts one block above the edit and used to start
    /// knowing nothing above that — but whether `    - foo` after a blank line
    /// is a list item or indented code depends on the content column of the
    /// item *above the blank*, which can sit above where the walk starts. The
    /// full parse saw it; the walk did not, and typing at the end of the line
    /// turned an item into a code block.
    @Test func anItemAboveTheWalkStillDecidesWhatAnIndentedMarkerIs() {
        let text = NSMutableString(string: "- a\n\n    - foo\n")
        var parse = BlockParser.fullParse(text)
        guard parse.blocks.count > 2, case .listItem = parse.blocks[2].kind else {
            Issue.record("the premise moved: \(parse.blocks.map(\.kind))")
            return
        }
        let end = text.range(of: "foo").location + 3
        _ = Self.apply("x", at: end, to: text, &parse, "typing at the end of an indented item")
    }

    /// The same item decides from the other side. Below `- a` and a blank line,
    /// `    - b` is an item (four is past the item's column, 2); change the
    /// marker to `10.   ` and the column is 6, so the same line is a code
    /// block. Nothing about the blank run or the line itself changed, so a
    /// walk that compared only what is open would stop at it and keep the old
    /// item — the item behind the blank run is part of where the walk stands.
    @Test func anEditAboveABlankLineReachesTheMarkerBelowIt() {
        let text = NSMutableString(string: "- a\n\n    - b\n\nmore\n")
        var parse = BlockParser.fullParse(text)
        _ = Self.apply("10.   ", at: 0, deleting: 2, to: text, &parse, "widening the item above the blank line")
        #expect(parse.blocks.contains { $0.kind == .indentedCode }, "\(parse.blocks.map(\.kind))")
    }
}
