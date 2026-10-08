//
//  EditorBusTests.swift
//  MarkdownEditorTests
//
//  The command bus reaches the editor a command is addressed to, and no other.
//
//  Written against the defect before the fix. The find bar's messages carried no
//  address, and every open editor answered them: with two windows on one note, a
//  find in one moved the other's selection, and — the part nobody would see —
//  Replace All in one rewrote the note open in the other. Each test below puts
//  two editors on the bus, as two windows do, addresses one, and checks that the
//  other did nothing; every one also checks that the addressed editor *did*
//  answer, so none can pass because nothing works. The last is the control: a
//  post with no address, the old way, must now reach nothing at all.
//
//  Both halves of the coordinator are held to it — AppKit here under
//  `swift test`, UIKit under the iOS `xcodebuild test` — because they are one
//  bus written twice, in two gates that cannot see each other.
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
@Suite struct EditorBusTests {
    static let sample = "# Organising\n\n## Folders\n\nFolders hold notes.\n"

    /// One editor on the bus: a document, its text view hosted in a window (the
    /// observers ignore a view that has none), and the coordinator that joined
    /// the bus as `id` — held here, because a coordinator removes its observers
    /// when it goes.
    @MainActor final class Editor {
        let id = "editor-\(UUID().uuidString)"
        let document: EditorDocument
        #if canImport(AppKit)
        let textView: MarkdownTextView
        let window: NSWindow
        let coordinator: MarkdownEditorView.Coordinator
        #else
        let textView: MarkdownUITextView
        let window: UIWindow
        let coordinator: MarkdownEditorRepresentable.Coordinator
        #endif

        init(text: String = EditorBusTests.sample) {
            document = EditorDocument(text: text)
            document.styleEverythingNow()
            #if canImport(AppKit)
            let (scrollView, textView) = MarkdownTextView.scrollableEditor(document: document)
            scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(scrollView)
            window.layoutIfNeeded()
            self.textView = textView
            coordinator = MarkdownEditorView.Coordinator(document: document, onLinkTap: nil)
            coordinator.textView = textView
            coordinator.subscribeToBus(editorID: id)
            #else
            textView = MarkdownUITextView.make(document: document)
            textView.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
            window = UIWindow(frame: textView.frame)
            window.addSubview(textView)
            window.isHidden = false
            textView.layoutIfNeeded()
            coordinator = MarkdownEditorRepresentable.Coordinator(document: document)
            coordinator.subscribe(editorID: id, view: textView)
            #endif
        }

        var selection: NSRange {
            #if canImport(AppKit)
            textView.selectedRange()
            #else
            textView.selectedRange
            #endif
        }

        var selected: String { (document.text as NSString).substring(with: selection) }

        func close() {
            #if canImport(AppKit)
            window.contentView = nil
            #else
            textView.removeFromSuperview()
            window.isHidden = true
            #endif
        }
    }

    private func post(_ name: Notification.Name, _ info: [String: Any] = [:]) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: info)
    }

    private func find(_ query: String, in editor: Editor) {
        post(EditorBus.findQuery(editor: editor.id), ["query": query, "currentIndex": 0])
    }

    @Test("A find selects in the editor it is addressed to, and nowhere else")
    func aFindReachesOnlyItsEditor() {
        let a = Editor(), b = Editor()
        defer { a.close(); b.close() }
        find("Folders", in: a)
        #expect(a.selected == "Folders", "the addressed editor did not answer its find")
        #expect(b.selection.length == 0, "a find addressed to one editor selected text in another")
    }

    @Test("The match count goes back to the find bar that asked")
    func theMatchCountIsAddressedToo() {
        let a = Editor(), b = Editor()
        defer { a.close(); b.close() }
        final class Counts: @unchecked Sendable { var byEditor: [String: Int] = [:] }
        let counts = Counts()
        let tokens = [a.id, b.id].map { id in
            NotificationCenter.default.addObserver(forName: EditorBus.findResults(editor: id),
                                                   object: nil, queue: nil) { note in
                counts.byEditor[id] = note.userInfo?["count"] as? Int
            }
        }
        defer { tokens.forEach(NotificationCenter.default.removeObserver) }
        find("Folders", in: a)
        #expect(counts.byEditor[a.id] == 2, "the addressed editor's count did not come back to it")
        #expect(counts.byEditor[b.id] == nil, "one editor's match count reached another's find bar")
    }

    @Test("Replace All rewrites the addressed editor's note and no other")
    func replaceAllReachesOnlyItsEditor() {
        let a = Editor(), b = Editor()
        defer { a.close(); b.close() }
        // Both have a find running, each its own — the state in which the other
        // editor used to answer: its query was set, so it rewrote its matches.
        find("Folders", in: a)
        find("Folders", in: b)
        post(EditorBus.replaceAll(editor: a.id), ["replacement": "Directories"])
        #expect(a.document.text == Self.sample.replacingOccurrences(of: "Folders", with: "Directories"),
                "the addressed editor did not replace its matches")
        #expect(b.document.text == Self.sample, "Replace All in one editor rewrote another editor's note")
    }

    @Test("Replace replaces the addressed editor's selection and no other")
    func replaceCurrentReachesOnlyItsEditor() {
        let a = Editor(), b = Editor()
        defer { a.close(); b.close() }
        find("Folders", in: a)
        find("Folders", in: b)
        post(EditorBus.replaceCurrent(editor: a.id), ["replacement": "Directories"])
        #expect(a.document.text.contains("Directories"), "the addressed editor did not replace its match")
        #expect(b.document.text == Self.sample, "Replace in one editor replaced another editor's selection")
    }

    @Test("Clearing a find clears only the addressed editor")
    func clearingReachesOnlyItsEditor() {
        let a = Editor(), b = Editor()
        defer { a.close(); b.close() }
        find("Folders", in: a)
        find("Folders", in: b)
        post(EditorBus.clearHighlights(editor: a.id))
        #expect(a.selection.length == 0, "the addressed editor kept its match selected")
        #expect(b.selected == "Folders", "clearing one editor's find cleared another's")
    }

    @Test("A heading jump moves only the addressed editor")
    func aHeadingJumpReachesOnlyItsEditor() {
        let a = Editor(), b = Editor()
        defer { a.close(); b.close() }
        let heading = (Self.sample as NSString).range(of: "## Folders").location
        let before = b.selection
        post(EditorBus.jumpToHeading(editor: a.id), ["ordinal": 1, "title": "Folders"])
        #expect(a.selection == NSRange(location: heading, length: 0),
                "the addressed editor did not go to its heading")
        #expect(b.selection == before, "a heading jump addressed to one editor moved another")
    }

    /// The control. This is how every one of these was posted before: no
    /// address. Both editors answered — the find selected in both, and the
    /// Replace All rewrote both notes. Nothing may answer it now.
    @Test("A post with no address reaches no editor")
    func anUnaddressedPostReachesNothing() {
        let a = Editor(), b = Editor()
        defer { a.close(); b.close() }
        // One expectation per editor: `&&` stops at the first false, and the
        // point is that *each* of them answered.
        post(Notification.Name("hn.editor.findQuery"), ["query": "Folders", "currentIndex": 0])
        #expect(a.selection.length == 0, "an unaddressed find still selects in an editor")
        #expect(b.selection.length == 0, "an unaddressed find still selects in the other editor too")
        post(Notification.Name("hn.editor.replaceAll"), ["replacement": "Directories"])
        #expect(a.document.text == Self.sample, "an unaddressed Replace All still rewrites a note")
        #expect(b.document.text == Self.sample, "an unaddressed Replace All still rewrites the other note too")
    }
}
