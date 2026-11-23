//
//  DeferredRewriteUndoTests.swift
//  MarkdownEditorTests
//
//  Undo after a deferred rewrite — a picture's description, a pasted link's
//  title — on iOS.
//
//  A `UITextView` keeps its undo stack on UIKit's manager, by offsets. The
//  rewrite went straight into the document's storage, which UIKit never saw.
//  In the same event, the stack's next undo — the insertion the rewrite came
//  after — cut the range it remembered from a text that had since grown:
//  `Start ![a cat](p.png)` undid to `Start.png)`, measured. In a later event,
//  as a description from Vision comes, there was nothing left to undo at all:
//  the picture could not be taken back (this test's control, run against the
//  old write). The rewrite goes through UIKit's own editing now
//  (`EditorProxy.replaceFirst`), and every undo lands on a text the note
//  really held.
//

#if canImport(UIKit) && !canImport(AppKit)
import UIKit
import Testing
@testable import MarkdownEditor

@MainActor
@Suite struct DeferredRewriteUndoTests {
    private func hosted(_ document: EditorDocument) -> (MarkdownUITextView, UIWindow) {
        let tv = MarkdownUITextView.make(document: document)
        tv.frame = CGRect(x: 0, y: 0, width: 700, height: 900)
        let window = UIWindow(frame: tv.frame)
        window.addSubview(tv)
        window.makeKeyAndVisible()
        tv.layoutIfNeeded()
        return (tv, window)
    }

    /// A turn of the run loop, which closes the event's undo group — as
    /// the description, which comes from Vision a moment later, does in the
    /// app. `undo()` with a group still open is an exception.
    private func turn() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    @Test func undoAfterADescriptionArrivesLeavesATextTheNoteHeld() throws {
        let original = "Start\nEnd\n"
        let document = EditorDocument(text: original)
        document.styleEverythingNow()
        let (tv, window) = hosted(document)
        defer { window.isHidden = true }
        #expect(tv.becomeFirstResponder())
        let undo = try #require(tv.undoManager, "no undo manager on the responder chain")
        undo.removeAllActions()

        tv.selectedRange = NSRange(location: 5, length: 0)
        #expect(tv.performEdit(replacing: NSRange(location: 5, length: 0), with: " ![](p.png)"))
        turn()
        let inserted = document.text
        let proxy = EditorProxy()
        proxy.textView = tv
        #expect(proxy.replaceFirst("![](p.png)", with: "![a cat](p.png)", in: document))
        turn()
        #expect(document.text == "Start ![a cat](p.png)\nEnd\n")
        // The caret stays after the link, where it was in the text.
        #expect(tv.selectedRange == NSRange(location: 21, length: 0))

        // Every undo lands on a text the note held — the description taken
        // back, then the picture — and never on a cut through the link.
        let held: Set<String> = [inserted, original]
        var steps = 0
        while undo.canUndo, undo.groupingLevel == 0, steps < 4 {
            undo.undo()
            turn()
            steps += 1
            #expect(held.contains(document.text), "undo \(steps) left \(document.text.debugDescription)")
        }
        #expect(steps > 0, "nothing was undone")
        #expect(document.text == original)
    }
}
#endif
