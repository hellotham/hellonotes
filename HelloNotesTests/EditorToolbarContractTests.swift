//
//  EditorToolbarContractTests.swift
//  HelloNotesTests
//
//  The formatting toolbar's visibility rule, as a test.
//
//  The rule is meant to be sayable in one sentence: **it is visible in every
//  editable mode and invisible in Preview.** For a long time the real rule was
//  something nobody could have said, because the bar was the editor's
//  `inputAccessoryView` and therefore keyed on *first-responder state*:
//
//    * entering Edit mode did not show it — you had to tap into the text too;
//    * anything that took focus hid it again mid-edit;
//    * in Preview it was absent only because nothing happened to be focused;
//    * and with a hardware keyboard iOS docked it at the bottom of the screen,
//      on top of the app's own status row.
//
//  These assertions are cheap and they are all about *rules*, not rendering —
//  the four modes were checked by eye on an iPad simulator, which is the only
//  thing that can see a screen. What a test can do is stop the rule quietly
//  becoming a different rule again.
//

import Foundation
import Testing
@testable import HelloNotes

struct EditorToolbarContractTests {

    /// Three of the four modes are editing. Only Preview is read-only — it is
    /// documented as "the note as it reads, with no caret".
    @Test func everyModeButPreviewIsEditable() {
        #expect(EditorMode.edit.isEditable)
        #expect(EditorMode.markdown.isEditable)
        #expect(EditorMode.split.isEditable)
        #expect(!EditorMode.preview.isEditable)
        // If a fifth mode is ever added, it has to make a decision here rather
        // than inherit one by accident.
        #expect(EditorMode.allCases.count == 4)
    }

    /// The bar is gated on the mode, and on nothing else.
    ///
    /// `mode == .edit` was the first version of this and it was wrong for the
    /// same reason the accessory was: Markdown and Split are editing too, and a
    /// toolbar that disappears when you switch to raw source is the same
    /// "sometimes there" complaint in a new place.
    @Test func theToolbarIsGatedOnTheModeBeingEditable() throws {
        let source = try Self.source("UI/NoteEditorView.swift")
        #expect(source.contains("if mode.isEditable"),
                "the toolbar's visibility must be the mode's `isEditable`, not a list of cases")
        #expect(source.contains("EditorFormatBar(documentId:"),
                "the toolbar must be the app's own chrome")
    }

    /// Nothing may re-attach the bar to the keyboard.
    ///
    /// This is the regression that would restore every symptom at once, and it
    /// is a one-line change, so it gets a one-line guard.
    @Test func nothingAttachesAnInputAccessoryView() throws {
        for file in ["UI/NoteEditorView.swift", "UI/EditorFormatBar.swift", "UI/SourceEditor.swift"] {
            let source = try Self.source(file)
            #expect(!source.contains("inputAccessoryView ="),
                    "\(file) attaches an input accessory view; the bar is app chrome")
        }
        let editor = try Self.packageSource("MarkdownEditor/MarkdownEditorView.swift")
        #expect(!editor.contains("tv.inputAccessoryView = "),
                "the editor must not attach an accessory: visibility would key on focus again")
    }

    /// A visible button that does nothing is worse than no button.
    ///
    /// The bar is shown in Markdown and Split, which are drawn by `SourceEditor`
    /// — a different view from the live editor, with its own coordinator. It
    /// therefore has to subscribe to the same command bus, or the toolbar is
    /// decoration in two of the three modes that show it.
    @Test func theSourceEditorAnswersTheSameCommandBus() throws {
        let source = try Self.source("UI/SourceEditor.swift")
        #expect(source.contains("MarkdownFormatting"),
                "the raw-source editor must accept the formatting commands")
        #expect(source.contains(".hnFormat("),
                "the raw-source editor must subscribe to the formatting bus")
        for command in ["hnEditorUndo", "hnEditorRedo", "hnEditorEndEditing"] {
            #expect(source.contains(command), "the source editor ignores \(command)")
        }
    }

    // MARK: -

    private static func source(_ name: String) throws -> String {
        try String(contentsOf: repoRoot.appending(path: "HelloNotes").appending(path: name),
                   encoding: .utf8)
    }

    private static func packageSource(_ name: String) throws -> String {
        try String(contentsOf: repoRoot
            .appending(path: "Packages/NotesEditor/Sources").appending(path: name),
                   encoding: .utf8)
    }

    private static var repoRoot: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
}
