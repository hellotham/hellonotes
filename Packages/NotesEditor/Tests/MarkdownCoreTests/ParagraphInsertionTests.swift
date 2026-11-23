//
//  ParagraphInsertionTests.swift
//  MarkdownCoreTests
//
//  A picture put in on purpose, inside what holds the caret's line.
//
//  At a caret in a callout the picture landed after the callout, and in a list
//  item it split the list: a paragraph of its own was blank lines around it
//  and nothing else, and a line without the container's markers is not in the
//  container.
//

import Foundation
import Testing
@testable import MarkdownCore

struct ParagraphInsertionTests {

    /// The note with the picture put in at the caret, written `|`.
    private func insert(_ marked: String, _ markdown: String = "![](p.jpg)") -> String {
        let caret = (marked as NSString).range(of: "|").location
        let text = (marked as NSString).replacingCharacters(in: NSRange(location: caret, length: 1), with: "") as NSString
        let parse = BlockParser.fullParse(text)
        let container = ParagraphInsertion.container(in: text, at: caret, parse: parse)
        let placed = ParagraphInsertion.paragraph(markdown, at: NSRange(location: caret, length: 0),
                                                  in: text, container: container)
        return text.replacingCharacters(in: placed.range, with: placed.text)
    }

    private func container(_ marked: String) -> String {
        let caret = (marked as NSString).range(of: "|").location
        let text = (marked as NSString).replacingCharacters(in: NSRange(location: caret, length: 1), with: "") as NSString
        return ParagraphInsertion.container(in: text, at: caret, parse: BlockParser.fullParse(text)).prefix
    }

    // MARK: - Nothing holding the line: as it always was

    @Test func withNothingHoldingTheLineItIsBlankLinesAround() {
        #expect(insert("|") == "![](p.jpg)")
        #expect(insert("Text|") == "Text\n\n![](p.jpg)")
        #expect(insert("One|\nTwo") == "One\n\n![](p.jpg)\n\nTwo")
        #expect(insert("One\n\n|\n\nTwo") == "One\n\n![](p.jpg)\n\nTwo")
        #expect(insert("Wo|rd") == "Wo\n\n![](p.jpg)\n\nrd")
        #expect(container("Plain|") == "")
        #expect(container("# Heading|") == "")
    }

    // MARK: - Quotes and callouts

    @Test func aCalloutKeepsItsFigure() {
        // The sweep's case: a callout's empty body line.
        #expect(insert("> [!note] Figure\n> |") == "> [!note] Figure\n> \n> ![](p.jpg)")
        // At the end of its title line.
        #expect(insert("> [!note] Figure|") == "> [!note] Figure\n>\n> ![](p.jpg)")
        // With more of the callout after it: still one callout.
        #expect(insert("> [!note] T\n> |\n> more") == "> [!note] T\n> \n> ![](p.jpg)\n>\n> more")
    }

    @Test func aQuoteKeepsItsMarkersOnEveryLine() {
        #expect(insert("> text|") == "> text\n>\n> ![](p.jpg)")
        #expect(insert("> te|xt") == "> te\n>\n> ![](p.jpg)\n>\n> xt")
        #expect(insert("> one|\n> two") == "> one\n>\n> ![](p.jpg)\n>\n> two")
        // A blank line already there is used, not doubled.
        #expect(insert("> one|\n>\n> two") == "> one\n>\n> ![](p.jpg)\n>\n> two")
        // Nested.
        #expect(container("> > deep|") == "> > ")
        // A caret among the markers goes to the text.
        #expect(insert("> one\n|> two") == "> one\n> \n> ![](p.jpg)\n>\n> two")
    }

    // MARK: - List items

    @Test func aListItemKeepsItsPictureAndTheListStaysOne() {
        #expect(container("- two|") == "  ")
        #expect(insert("- one\n- two|\n- three") == "- one\n- two\n\n  ![](p.jpg)\n\n- three")
        #expect(insert("1. one|") == "1. one\n\n   ![](p.jpg)")
        #expect(container("10. ten|") == "    ")
        // A task's later paragraphs sit at its marker's text, not past its box.
        #expect(container("- [ ] task|") == "  ")
        // Nested: the nested item's own text column.
        #expect(container("- one\n  - sub|") == "    ")
        // A line of an item's own text, under its marker line.
        #expect(container("- item\n  more|") == "  ")
        #expect(insert("- item\n  more|") == "- item\n  more\n\n  ![](p.jpg)")
        // Right after the marker: the item's first block.
        #expect(insert("- |text") == "- ![](p.jpg)\n\n  text")
    }

    @Test func aListInAQuoteKeepsBoth() {
        #expect(container("> - item|") == ">   ")
        #expect(insert("> - item|") == "> - item\n>\n>   ![](p.jpg)")
    }

    // MARK: - Code is not a container

    @Test func aFenceInsideAnItemIsCodeNotAContainer() {
        #expect(container("- step\n  ```\n  code|\n  ```") == "")
        #expect(container("> ```\n> code|\n> ```") == "")
    }

    /// The range returned is where the text goes: moved only off a line's
    /// markers, never otherwise.
    @Test func theRangeMovesOnlyOffALinesMarkers() {
        let text = "> one\n> two" as NSString
        let parse = BlockParser.fullParse(text)
        let atStart = NSRange(location: 6, length: 0)                  // before "> two"
        let placed = ParagraphInsertion.paragraph("x", at: atStart, in: text,
                                                  container: ParagraphInsertion.container(in: text, at: 6, parse: parse))
        #expect(placed.range == NSRange(location: 8, length: 0))
        let atText = NSRange(location: 3, length: 0)
        let same = ParagraphInsertion.paragraph("x", at: atText, in: text,
                                                container: ParagraphInsertion.container(in: text, at: 3, parse: parse))
        #expect(same.range == atText)
    }
}
