//
//  CompletionKeyTests.swift
//  MarkdownEditorTests
//
//  The keys for a list of suggestions the host shows by the caret.
//
//  The list of notes and tags offered while a `[[link` or a `#tag` is typed
//  could only be clicked or tapped: the text view keeps first responder, so
//  the list never had a key (found by fact-checking the 1.3.3 website against
//  the source; docs/implemented.md §51.44). The view asks the host before it
//  acts on ↑, ↓, Return, Tab or Escape (`CompletionKeyHandler`) — and these
//  hold both halves of that: a key the host wants reaches the host and does
//  nothing to the text, and a key it does not want is the text's, exactly as
//  it was.
//
//  On the Mac the keys arrive as the commands AppKit binds them to
//  (`moveDown:`, `insertNewline:`, …), which is what these send. On iOS they
//  are key commands, which UIKit asks for before every key: what is offered,
//  and what each does when called. Whether UIKit *calls* one is not something
//  a unit test can see — `wantsPriorityOverSystemBehavior` decides it, and is
//  asserted here; the app's interface test presses the keys.
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
@Suite struct CompletionKeyTests {
    typealias Editor = EditorBusTests.Editor

    /// What the host was given, and what it says it wants.
    @MainActor final class Host {
        var wanted: Set<CompletionKey> = []
        var taken: [CompletionKey] = []
        var asked = 0

        var handler: CompletionKeyHandler {
            CompletionKeyHandler(wants: { [unowned self] in asked += 1; return wanted.contains($0) },
                                 perform: { [unowned self] in taken.append($0) })
        }
    }

    private static let note = "First line\nSecond [[No\nThird line\n"

    /// An editor on `note` with the caret after `[[No`, and the host its keys
    /// are offered to.
    private func editorInALink() -> (Editor, Host, caret: Int) {
        let editor = Editor(text: Self.note)
        let host = Host()
        editor.textView.completionKeys = host.handler
        let caret = (Self.note as NSString).range(of: "[[No").upperBound
        #if canImport(AppKit)
        editor.window.makeFirstResponder(editor.textView)
        editor.textView.setSelectedRange(NSRange(location: caret, length: 0))
        #else
        editor.textView.selectedRange = NSRange(location: caret, length: 0)
        #endif
        return (editor, host, caret)
    }

    private func caret(of editor: Editor) -> Int {
        #if canImport(AppKit)
        editor.textView.selectedRange().location
        #else
        editor.textView.selectedRange.location
        #endif
    }

    #if canImport(AppKit)

    /// Each key the host wants goes to the host, and the text and the caret
    /// are as they were.
    @Test func aKeyTheListWantsIsTheLists() {
        let (editor, host, caret) = editorInALink()
        host.wanted = Set(CompletionKey.allCases)

        editor.textView.moveDown(nil)
        editor.textView.moveUp(nil)
        editor.textView.insertNewline(nil)
        editor.textView.insertTab(nil)
        editor.textView.cancelOperation(nil)

        #expect(host.taken == [.down, .up, .accept, .accept, .dismiss])
        #expect(editor.document.text == Self.note, "a key given to the list also changed the text")
        #expect(self.caret(of: editor) == caret, "a key given to the list also moved the caret")
    }

    /// The control, and the half that must not change: with the list wanting
    /// nothing, every key does what it always did. (An editor each: where ↑
    /// lands after ↓ depends on what the line conceals once the caret has
    /// left it, which is not this test's business.)
    @Test func aKeyTheListDoesNotWantIsTheTexts() {
        var (editor, host, caret) = editorInALink()
        editor.textView.moveDown(nil)
        #expect(self.caret(of: editor) > caret, "↓ did not move the caret down a line")
        #expect(host.taken.isEmpty && host.asked >= 1, "the host was never asked — so nothing shows it can refuse")

        (editor, host, caret) = editorInALink()
        editor.textView.moveUp(nil)
        #expect(self.caret(of: editor) < caret, "↑ did not move the caret up a line")
        #expect(host.taken.isEmpty && host.asked >= 1)

        (editor, host, caret) = editorInALink()
        editor.textView.insertNewline(nil)
        #expect(editor.document.text == "First line\nSecond [[No\n\nThird line\n", "Return did not type a newline")
        #expect(host.taken.isEmpty && host.asked >= 1)

        (editor, host, caret) = editorInALink()
        editor.textView.insertTab(nil)
        #expect(editor.document.text == "First line\nSecond [[No\t\nThird line\n", "Tab did not type a tab")
        #expect(host.taken.isEmpty && host.asked >= 1)
    }

    /// Wanted one at a time: ↓ chosen and Return not is the list as it opens,
    /// with nothing chosen yet — Return must still be Return.
    @Test func eachKeyIsAskedForByItself() {
        let (editor, host, _) = editorInALink()
        host.wanted = [.up, .down]

        editor.textView.moveDown(nil)
        editor.textView.insertNewline(nil)

        #expect(host.taken == [.down])
        #expect(editor.document.text == "First line\nSecond [[No\n\nThird line\n")
    }

    /// With no host there is no list, and nothing is asked of anyone.
    @Test func withNoHostNothingChanges() {
        let (editor, _, caret) = editorInALink()
        editor.textView.completionKeys = nil
        editor.textView.moveDown(nil)
        #expect(self.caret(of: editor) > caret)
    }

    #else

    private func commands(of editor: Editor) -> [UIKeyCommand] {
        (editor.textView.keyCommands ?? []).filter { $0.action == Selector(("completionKeyCommand:")) }
    }

    /// Offered for the keys the host wants, and only those — and each ahead
    /// of the system's own handling, or a text view's arrows and Return never
    /// reach it.
    @Test func theKeysTheListWantsAreOfferedAndNoOthers() {
        let (editor, host, _) = editorInALink()

        #expect(commands(of: editor).isEmpty, "keys are taken from the text with no list wanting them")

        host.wanted = [.up, .down]
        #expect(Set(commands(of: editor).compactMap(\.input))
                == [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow])

        host.wanted = Set(CompletionKey.allCases)
        let all = commands(of: editor)
        #expect(Set(all.compactMap(\.input))
                == [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, "\r", "\t", UIKeyCommand.inputEscape])
        #expect(all.allSatisfy { $0.wantsPriorityOverSystemBehavior },
                "a key command a text view's own handling comes before is never called")
        #expect(all.allSatisfy { $0.modifierFlags.isEmpty })
    }

    /// Called, each reaches the host as the key it is, and the text and the
    /// caret are as they were.
    @Test func aKeyTheListWantsIsTheLists() {
        let (editor, host, caret) = editorInALink()
        host.wanted = Set(CompletionKey.allCases)

        for input in [UIKeyCommand.inputDownArrow, UIKeyCommand.inputUpArrow, "\r", "\t", UIKeyCommand.inputEscape] {
            let command = try? #require(commands(of: editor).first { $0.input == input })
            _ = editor.textView.perform(Selector(("completionKeyCommand:")), with: command)
        }

        #expect(host.taken == [.down, .up, .accept, .accept, .dismiss])
        #expect(editor.document.text == Self.note)
        #expect(self.caret(of: editor) == caret)
    }

    /// Return and Tab as they reach an iOS text view — typed text, through its
    /// delegate, from a hardware keyboard and the software one alike: with a
    /// row chosen the list takes them and nothing is typed, and with none
    /// chosen they are typed.
    @Test func returnAndTabArriveAsTextAndAreTheListsWhenItWantsThem() {
        let (editor, host, caret) = editorInALink()
        let at = NSRange(location: caret, length: 0)

        #expect(editor.coordinator.textView(editor.textView, shouldChangeTextIn: at, replacementText: "\t"),
                "Tab was kept from the text with no list wanting it")
        #expect(host.taken.isEmpty && host.asked >= 1)

        host.wanted = [.accept]
        #expect(!editor.coordinator.textView(editor.textView, shouldChangeTextIn: at, replacementText: "\n"))
        #expect(!editor.coordinator.textView(editor.textView, shouldChangeTextIn: at, replacementText: "\t"))
        #expect(host.taken == [.accept, .accept])
        // Anything else typed is typed.
        #expect(editor.coordinator.textView(editor.textView, shouldChangeTextIn: at, replacementText: "x"))
        #expect(editor.document.text == Self.note)
    }

    /// A command UIKit still holds from before the list went: called late, it
    /// does nothing.
    @Test func aKeyNoLongerWantedDoesNothing() {
        let (editor, host, _) = editorInALink()
        host.wanted = [.down]
        let stale = commands(of: editor).first
        host.wanted = []
        _ = editor.textView.perform(Selector(("completionKeyCommand:")), with: stale)
        #expect(host.taken.isEmpty)
    }

    /// With no host there is no list, and no key is taken.
    @Test func withNoHostNothingIsOffered() {
        let (editor, _, _) = editorInALink()
        editor.textView.completionKeys = nil
        #expect(commands(of: editor).isEmpty)
    }

    #endif
}

private extension NSRange {
    var upperBound: Int { location + length }
}
