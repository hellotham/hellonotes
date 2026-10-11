//
//  StyledBitsTests.swift
//  MarkdownEditorTests
//
//  An edit made before the background styling pass has finished keeps what
//  the pass has done (`EditorDocument.splicedStyledBits`).
//
//  It threw it all away — every block marked unstyled — and restyled the
//  30,000 characters around the edit on the spot, invalidating their layout,
//  on every keystroke: the pass restarts only after 400ms of quiet, so typing
//  in a note opened moments before paid it again key after key.
//

import Foundation
import Testing
import MarkdownCore
@testable import MarkdownEditor

@Suite struct StyledBitsTests {

    static let text = (1...200).map { "Paragraph \($0)." }.joined(separator: "\n\n")

    /// `text` with `insert` typed at `location`: both parses and the edit.
    private func typed(_ insert: String, at location: Int) -> (old: ParseResult, new: ParseResult, edit: TextEdit) {
        let before = Self.text as NSString
        let old = BlockParser.fullParse(before)
        let after = NSMutableString(string: before)
        after.insert(insert, at: location)
        let edit = TextEdit(range: NSRange(location: location, length: 0), replacementLength: (insert as NSString).length)
        return (old, BlockParser.incremental(after, edit: edit, previous: old), edit)
    }

    @Test("Bits away from the edit are kept, and only the blocks around it are cleared")
    func bitsAwayFromTheEditAreKept() throws {
        let location = (Self.text as NSString).range(of: "Paragraph 100.").location + 4
        let (old, new, edit) = typed("x", at: location)
        var bits = Array(repeating: true, count: old.blocks.count)
        bits[10] = false                      // not yet styled, far above
        bits[old.blocks.count - 3] = false    // and far below
        let spliced = EditorDocument.splicedStyledBits(bits, old: old, new: new,
                                                       oldRange: edit.range, delta: edit.delta)
        #expect(spliced.count == new.blocks.count)
        #expect(spliced[10] == false && spliced[new.blocks.count - 3] == false,
                "a block the pass had not reached came back styled")
        let cleared = spliced.enumerated().filter { !$0.element }.map(\.offset)
        let editBlock = try #require(new.blockIndex(at: location))
        #expect(cleared.contains(editBlock), "the edited block kept its bit — the edit has to restyle it")
        #expect(cleared.count <= 2 + 3, "the splice cleared \(cleared.count) bits, not just those around the edit")
    }

    @Test("A new block typed in moves the bits after it along")
    func aNewBlockShiftsTheBitsAfterIt() {
        let location = NSMaxRange((Self.text as NSString).range(of: "Paragraph 100."))
        let (old, new, edit) = typed("\n\nA new paragraph.", at: location)
        var bits = Array(repeating: true, count: old.blocks.count)
        bits[old.blocks.count - 3] = false
        let spliced = EditorDocument.splicedStyledBits(bits, old: old, new: new,
                                                       oldRange: edit.range, delta: edit.delta)
        #expect(new.blocks.count == old.blocks.count + 2)
        #expect(spliced.count == new.blocks.count)
        #expect(spliced[new.blocks.count - 3] == false, "the bit below the new block was not carried along")
    }
}
