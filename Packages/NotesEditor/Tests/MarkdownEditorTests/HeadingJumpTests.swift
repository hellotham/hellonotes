//
//  HeadingJumpTests.swift
//  MarkdownEditorTests
//
//  A jump to a heading waits for a surface of its editor that can show it.
//
//  Following `[[Note#Heading]]` opens the note and jumps in one go, and the new
//  tab's text view is not in a window yet. The jump was a post and nothing
//  more, so the host waited a fixed 350ms and posted anyway, and a tab that
//  took longer to come up scrolled nowhere. It is kept for its editor now
//  (`EditorBus.requestHeadingJump`) and shown by whichever surface of that
//  editor is ready first — at once, or when it arrives (`HeadingJumpListener`).
//

import Foundation
import Testing
@testable import MarkdownCore
@testable import MarkdownEditor
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@MainActor
@Suite struct HeadingJumpTests {

    static let note = "# One\n\nIntro text.\n\n## Two\n\nBody.\n\n## Three\n\nMore."
    static var two: Int { (note as NSString).range(of: "## Two").location }

    private static func editorID() -> String { "jump-\(UUID().uuidString)" }

    /// Nobody can show it: it is kept, for its editor alone, and taken once.
    @Test func aJumpNobodyCanShowIsKeptForItsEditor() {
        let editor = Self.editorID(), other = Self.editorID()
        EditorBus.requestHeadingJump(HeadingJump(ordinal: 1, title: "Two"), editor: editor)
        #expect(EditorBus.takePendingHeadingJump(editor: other) == nil, "kept for another editor")
        #expect(EditorBus.takePendingHeadingJump(editor: editor) == HeadingJump(ordinal: 1, title: "Two"))
        #expect(EditorBus.takePendingHeadingJump(editor: editor) == nil, "taken twice")
        // A newer jump replaces an older one.
        EditorBus.requestHeadingJump(HeadingJump(ordinal: 0, title: "One"), editor: editor)
        EditorBus.requestHeadingJump(HeadingJump(ordinal: 2, title: "Three"), editor: editor)
        #expect(EditorBus.takePendingHeadingJump(editor: editor)?.title == "Three")
    }

    /// The tab's view is not in a window when the jump is asked for; it shows
    /// the jump when it gets there, and takes it.
    @Test func aViewArrivingInAWindowShowsTheJumpWaitingForIt() throws {
        let editor = Self.editorID()
        let surface = Surface(editor: editor)
        EditorBus.requestHeadingJump(HeadingJump(ordinal: 1, title: "Two"), editor: editor)
        #expect(surface.caret != Self.two, "a view in no window showed the jump")
        surface.arrive()
        defer { surface.leave() }
        #expect(surface.caret == Self.two)
        #expect(EditorBus.takePendingHeadingJump(editor: editor) == nil, "the view showed it and left it waiting")
    }

    /// A view already up answers the post itself.
    @Test func aViewAlreadyUpShowsTheJumpAtOnce() {
        let editor = Self.editorID()
        let surface = Surface(editor: editor)
        surface.arrive()
        defer { surface.leave() }
        EditorBus.requestHeadingJump(HeadingJump(ordinal: 2, title: "Three"), editor: editor)
        #expect(surface.caret == (Self.note as NSString).range(of: "## Three").location)
        #expect(EditorBus.takePendingHeadingJump(editor: editor) == nil)
    }

    /// Split's two panes are one editor and both jump; a surface of another
    /// editor does not.
    @Test func everySurfaceOfTheEditorAnswersAndNoOther() {
        let editor = Self.editorID()
        let first = Surface(editor: editor), second = Surface(editor: editor)
        let elsewhere = Surface(editor: Self.editorID())
        for surface in [first, second, elsewhere] { surface.arrive() }
        defer { for surface in [first, second, elsewhere] { surface.leave() } }
        EditorBus.requestHeadingJump(HeadingJump(ordinal: 1, title: "Two"), editor: editor)
        #expect(first.caret == Self.two && second.caret == Self.two)
        #expect(elsewhere.caret != Self.two, "a jump reached another editor")
    }

    /// The editor's own text view, on this platform, in and out of a window.
    @MainActor private final class Surface {
        /// Kept here because the view holds its document weakly — the host
        /// owns it in the app.
        let document = EditorDocument(text: HeadingJumpTests.note)
        #if canImport(AppKit)
        let scrollView: NSScrollView
        let textView: MarkdownTextView
        private var window: NSWindow?

        init(editor: String) {
            (scrollView, textView) = MarkdownTextView.scrollableEditor(document: document)
            scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.headingJumps.editorID = editor
        }
        var caret: Int { textView.selectedRange().location }
        func arrive() {
            let window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(scrollView)
            self.window = window
        }
        func leave() { scrollView.removeFromSuperview(); window = nil }
        #else
        let textView: MarkdownUITextView
        private var window: UIWindow?

        init(editor: String) {
            textView = MarkdownUITextView.make(document: document)
            textView.frame = CGRect(x: 0, y: 0, width: 600, height: 300)
            textView.selectedRange = NSRange(location: 0, length: 0)
            textView.headingJumps.editorID = editor
        }
        var caret: Int { textView.selectedRange.location }
        func arrive() {
            let window = UIWindow(frame: textView.frame)
            window.addSubview(textView)
            window.isHidden = false
            self.window = window
        }
        func leave() { textView.removeFromSuperview(); window?.isHidden = true; window = nil }
        #endif
    }
}
