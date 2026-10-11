//
//  ListContinuationTests.swift
//  MarkdownCoreTests
//
//  What Return does in a list (`ListContinuation`): the next item, or the end
//  of the list — and nothing at all where the line is not an item.
//

import Foundation
import Testing
@testable import MarkdownCore

@Suite struct ListContinuationTests {

    /// `text` with Return pressed at `|`, as the editor would apply it; `nil`
    /// when Return is left to be a plain newline.
    private func pressReturn(_ marked: String) -> String? {
        let caret = (marked as NSString).range(of: "|").location
        let text = marked.replacingOccurrences(of: "|", with: "") as NSString
        guard let edit = ListContinuation.returnKey(parsing: text, at: caret) else { return nil }
        let result = NSMutableString(string: text)
        result.replaceCharacters(in: edit.range, with: edit.replacement)
        result.insert("|", at: edit.caret)
        return result as String
    }

    @Test("A bullet continues with the same bullet")
    func bullets() {
        #expect(pressReturn("- apples|") == "- apples\n- |")
        #expect(pressReturn("* apples|") == "* apples\n* |")
        #expect(pressReturn("+ apples|") == "+ apples\n+ |")
        #expect(pressReturn("- apples|\n- pears") == "- apples\n- |\n- pears")
    }

    @Test("A number continues with the next number and the same delimiter")
    func numbers() {
        #expect(pressReturn("1. one|") == "1. one\n2. |")
        #expect(pressReturn("1. one\n2. two|") == "1. one\n2. two\n3. |")
        #expect(pressReturn("9) nine|") == "9) nine\n10) |")
    }

    @Test("A task continues unchecked, whatever the box held")
    func tasks() {
        #expect(pressReturn("- [x] done|") == "- [x] done\n- [ ] |")
        #expect(pressReturn("- [ ] todo|") == "- [ ] todo\n- [ ] |")
        #expect(pressReturn("1. [X] done|") == "1. [X] done\n2. [ ] |")
    }

    @Test("A nested item continues at its own indent, and inside its quote")
    func indentAndQuotes() {
        #expect(pressReturn("- parent\n  - child|") == "- parent\n  - child\n  - |")
        #expect(pressReturn("> - quoted|") == "> - quoted\n> - |")
        #expect(pressReturn("> 1. quoted|") == "> 1. quoted\n> 2. |")
    }

    @Test("Return in the middle of an item splits it, the rest starting the next")
    func split() {
        #expect(pressReturn("- apples| and pears") == "- apples\n- |and pears")
        #expect(pressReturn("1. one|two") == "1. one\n2. |two")
    }

    /// …with a blank line after the list: a line typed straight after an
    /// item is more of that item in Markdown, drawn and rendered inside it.
    @Test("Return on an empty item ends the list: a blank line, and the caret at the margin")
    func emptyItemEndsTheList() {
        #expect(pressReturn("- apples\n- |") == "- apples\n\n|")
        #expect(pressReturn("1. one\n2. |") == "1. one\n\n|")
        #expect(pressReturn("- [ ] todo\n- [ ] |") == "- [ ] todo\n\n|")
        #expect(pressReturn("- apples\n- |\nMore") == "- apples\n\n|\nMore")
        // A quote's blank line is a quote line.
        #expect(pressReturn("> - quoted\n> - |") == "> - quoted\n>\n> |")
        // Already a blank line above, or nothing: just the marker goes.
        #expect(pressReturn("Para\n\n- |") == "Para\n\n|")
        #expect(pressReturn("- |") == "|")
    }

    @Test("Return on an empty nested item moves it out a level")
    func emptyNestedItemOutdents() {
        #expect(pressReturn("- parent\n  - |") == "- parent\n- |")
        #expect(pressReturn("1. parent\n   1. |") == "1. parent\n2. |")
        #expect(pressReturn("- a\n  - b\n    - |") == "- a\n  - b\n  - |")
    }

    @Test("Before the item's text, Return is a plain newline")
    func inTheMarker() {
        #expect(pressReturn("|- apples") == nil)
        #expect(pressReturn("-| apples") == nil)
    }

    @Test("Not a list: a paragraph, a heading's underline, a rule, code, front matter")
    func notAList() {
        #expect(pressReturn("Just prose|") == nil)
        #expect(pressReturn("Title\n-|") == nil, "a setext underline is not an empty item")
        #expect(pressReturn("- - -|") == nil, "a thematic break is not an item")
        #expect(pressReturn("```\n- not an item|\n```") == nil)
        #expect(pressReturn("    - indented code|") == nil)
        #expect(pressReturn("---\ntags:\n- one|\n---\n") == nil, "front matter")
        #expect(pressReturn("$$\n- x|\n$$") == nil, "maths")
    }

    /// A fence under an item, or inside a quote, is part of that item's or
    /// quote's block, so the block's kind alone would let these through.
    @Test("Not in a fence inside a list item or a quote")
    func notInNestedCode() {
        #expect(pressReturn("1. Step\n\n   ```yaml\n   - name: x|\n   ```") == nil)
        #expect(pressReturn("- Step\n  ```\n  - not an item|") == nil, "an unclosed fence, still being typed")
        #expect(pressReturn("> ```\n> - x|\n> ```") == nil)
        // …and after the fence closes, the list is a list again.
        #expect(pressReturn("- Step\n  ```\n  code\n  ```\n- next|") == "- Step\n  ```\n  code\n  ```\n- next\n- |")
        #expect(pressReturn("> ```\n> code\n> ```\n> - x|") == "> ```\n> code\n> ```\n> - x\n> - |")
    }

    /// The Markdown pane has no parse of its own, so it parses the note — on
    /// the main actor, on a keystroke. A note past the limit is not parsed.
    @Test("A note past the parse limit is left a plain newline, and one inside it is not")
    func theUnparsedPathIsBounded() {
        let filler = String(repeating: "Prose.\n", count: ListContinuation.parseLimit / 7 + 1)
        let long = (filler + "- apples") as NSString
        #expect(long.length > ListContinuation.parseLimit)
        #expect(ListContinuation.returnKey(parsing: long, at: long.length) == nil)
        // With a parse in hand — Edit's — length is no object.
        #expect(ListContinuation.returnKey(in: long, at: long.length, parse: BlockParser.fullParse(long)) != nil)

        let short = (String(repeating: "Prose.\n", count: 100) + "- apples") as NSString
        #expect(ListContinuation.returnKey(parsing: short, at: short.length) != nil)
    }

    @Test("The marker is read as written")
    func parsing() {
        let item = ListContinuation.parse("  12) [x]  text")
        #expect(item?.indent == "  ")
        #expect(item?.bullet == "12")
        #expect(item?.delimiter == ")")
        #expect(item?.task == "[x] ")
        #expect(ListContinuation.parse("-no space") == nil)
        #expect(ListContinuation.parse("1234567890. too long") == nil)
        #expect(ListContinuation.parse("-") != nil, "an empty item")
    }
}
