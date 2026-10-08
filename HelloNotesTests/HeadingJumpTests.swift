//
//  HeadingJumpTests.swift
//  HelloNotesTests
//
//  A jump to a heading ends where it lands, and waits for its editor.
//
//  It used to clear a highlight 1.2s after the post. There was no highlight —
//  a jump leaves a caret at the heading — so what the clear did was collapse
//  whatever selection there was by then and drop the find bar's query: a word
//  selected in the second after a jump was deselected under the pointer. And
//  following `[[Note#Heading]]` waited a fixed 350ms for the new tab before
//  jumping, which a tab that took longer missed. The editor's own surfaces are
//  held to waiting in the package (`HeadingJumpTests` there); this holds the
//  app's half.
//

import Foundation
import MarkdownEditor
import Testing
@testable import HelloNotes

@MainActor
@Suite struct HeadingJumpTests {

    @MainActor private final class Count { var value = 0 }

    @Test func aJumpClearsNothingAfterwards() async throws {
        let editor = "jump-\(UUID().uuidString)"
        let cleared = Count()
        let token = NotificationCenter.default.addObserver(
            forName: EditorBus.clearHighlights(editor: editor), object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { cleared.value += 1 } }
        defer { NotificationCenter.default.removeObserver(token) }

        hnJumpToHeading(ordinal: 1, title: "Two", editor: editor)
        // Past the old timer's 1.2s, with room.
        try await Task.sleep(for: .milliseconds(1_500))
        #expect(cleared.value == 0, "a jump cleared the selection and the find after it landed")
        // Nothing here can show it, so it is waiting for the editor.
        #expect(EditorBus.takePendingHeadingJump(editor: editor) == HeadingJump(ordinal: 1, title: "Two"))
    }
}
