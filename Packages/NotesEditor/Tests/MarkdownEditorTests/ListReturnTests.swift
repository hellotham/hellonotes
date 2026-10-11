//
//  ListReturnTests.swift
//  MarkdownEditorTests
//
//  Return in a list, through the text view, as a keyboard sends it: the next
//  item, the end of the list with the caret at the margin, and nothing at all
//  in code. `ListContinuationTests` holds the rule; this holds that the
//  editor asks it — through `insertNewline` on the Mac and the text view's
//  delegate on iOS, where a hardware keyboard's Return and the software
//  keyboard's both arrive as a newline.
//
//  The caret's place on the empty line after a list is its own check: that
//  line has no character to be styled, so it is drawn from the typing
//  attributes, and those were the list item's — the caret stood under the
//  item's text, 20pt in from where the next paragraph starts (build 28).
//

import Foundation
import Testing
@testable import MarkdownEditor
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@MainActor
@Suite struct ListReturnTests {
    typealias Editor = EditorBusTests.Editor

    /// Return at the end of `editor`'s text, as the keyboard sends it.
    private func pressReturn(in editor: Editor) {
        #if canImport(AppKit)
        editor.window.makeFirstResponder(editor.textView)
        editor.textView.setSelectedRange(NSRange(location: (editor.document.text as NSString).length, length: 0))
        editor.textView.insertNewline(nil)
        #else
        let tv = editor.textView
        let caret = (editor.document.text as NSString).length
        tv.selectedRange = NSRange(location: caret, length: 0)
        if editor.coordinator.textView(tv, shouldChangeTextIn: NSRange(location: caret, length: 0),
                                       replacementText: "\n") {
            tv.insertText("\n")
        }
        #endif
    }

    /// Where the caret is drawn, across: its distance from the view's leading
    /// edge.
    private func caretX(in editor: Editor) -> CGFloat {
        #if canImport(AppKit)
        let tv = editor.textView
        let screen = tv.firstRect(forCharacterRange: tv.selectedRange(), actualRange: nil)
        return tv.convert(editor.window.convertFromScreen(screen), from: nil).minX
        #else
        let tv = editor.textView
        guard let range = tv.selectedTextRange else { return -1 }
        return tv.caretRect(for: range.start).minX
        #endif
    }

    @Test("Return in an item starts the next one")
    func returnContinuesTheList() {
        let editor = Editor(text: "- apples")
        defer { editor.close() }
        pressReturn(in: editor)
        #expect(editor.document.text == "- apples\n- ")
        #expect(editor.selection == NSRange(location: 11, length: 0))

        let numbered = Editor(text: "1. one")
        defer { numbered.close() }
        pressReturn(in: numbered)
        #expect(numbered.document.text == "1. one\n2. ")
    }

    @Test("Return on an empty item ends the list, the caret at the margin")
    func returnOnAnEmptyItemEndsTheList() {
        let paragraph = Editor(text: "Para")
        defer { paragraph.close() }
        pressReturn(in: paragraph)
        pressReturn(in: paragraph)
        let margin = caretX(in: paragraph)

        let list = Editor(text: "- apples")
        defer { list.close() }
        pressReturn(in: list)   // "- apples\n- "
        pressReturn(in: list)   // the list ends
        #expect(list.document.text == "- apples\n\n")
        #expect(abs(caretX(in: list) - margin) < 0.5,
                "after the list the caret stands at \(caretX(in: list)), not at the margin (\(margin)) where the next paragraph starts")

        // A plain Return on the line after an item — the platform's own
        // newline, carrying the item's paragraph with it — leaves a blank line
        // too, and the caret below it belongs at the margin as well.
        let after = Editor(text: "- apples\n")
        defer { after.close() }
        pressReturn(in: after)
        #expect(after.document.text == "- apples\n\n")
        #expect(abs(caretX(in: after) - margin) < 0.5,
                "after a blank line the caret stands at \(caretX(in: after)), not at the margin (\(margin))")
    }

    @Test("Return in code is a newline, whatever the line looks like")
    func returnInCodeIsANewline() {
        let editor = Editor(text: "```\n- not an item")
        defer { editor.close() }
        pressReturn(in: editor)
        #expect(editor.document.text == "```\n- not an item\n")
    }

    #if canImport(AppKit)
    @Test("One undo takes a continued item back")
    func undoTakesTheItemBack() throws {
        let editor = Editor(text: "- apples")
        defer { editor.close() }
        pressReturn(in: editor)
        #expect(editor.document.text == "- apples\n- ")
        let undo = try #require(editor.textView.undoManager)
        undo.undo()
        #expect(editor.document.text == "- apples")
    }
    #endif
}
