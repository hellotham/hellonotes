//
//  EditorToolbarContractTests.swift
//  HelloNotesTests
//
//  Where the formatting commands live, as a test.
//
//  They belong in **the system's own editor affordance**: on iPad the floating
//  shortcuts pill that carries the language selector (`EN AU`) and the dictation
//  mic, and on iPhone — which has no such bar — an `inputAccessoryView`. That is
//  where a person looks for "make this bold", it costs the app no screen space,
//  and it cannot overlap the app's own status row.
//
//  Two wrong answers were shipped on the way here, and both are worth naming
//  because each looked reasonable:
//
//    1. A hand-rolled `inputAccessoryView` on every idiom. iOS docks an
//       accessory at the *bottom of the screen* when a hardware keyboard is
//       attached, so on an iPad with a Magic Keyboard it drew straight over the
//       word count and the mode picker.
//    2. A bar of the app's own, in the bottom chrome, gated on the mode. That
//       fixed the overlap and made visibility predictable — but it spent 40pt
//       of every editing screen re-implementing a control the system already
//       provides, and the system one appears with a hardware keyboard too.
//
//  `inputAssistantItem` was never evaluated until it was measured on a
//  simulator with a hardware keyboard attached, which is the configuration that
//  decides the question.
//

import Foundation
import Testing
@testable import HelloNotes

struct EditorToolbarContractTests {

    /// The commands go to the system, not into chrome of our own.
    ///
    /// A bar in the app's bottom inset is the regression this guards: it is a
    /// reasonable-looking change that quietly costs a row of every editing
    /// screen and duplicates a native control.
    @Test func formattingLivesInTheSystemAffordance() throws {
        let installer = try Self.packageSource("MarkdownEditor/EditorCommands.swift")
        #expect(installer.contains("inputAssistantItem.leadingBarButtonGroups"),
                "iPad formatting belongs in the shortcuts bar")
        #expect(installer.contains("UIDevice.current.userInterfaceIdiom == .pad"),
                "iPhone has no shortcuts bar, so the idiom has to be checked at runtime")
        #expect(installer.contains("inputAccessoryView = bar"),
                "iPhone still needs an accessory — it has no shortcuts bar to put these in")

        let editorColumn = try Self.source("UI/NoteEditorView.swift")
        #expect(!editorColumn.contains("EditorFormatBar"),
                "the app must not carry a formatting bar of its own")
    }

    /// Both editors install it.
    ///
    /// Edit is drawn by the live editor; Markdown and Split are drawn by
    /// `SourceEditor`, a different view entirely. Wiring only the first is the
    /// mistake that gives you formatting in one of the three editable modes and
    /// nothing in the other two.
    @Test func everyEditableViewInstallsIt() throws {
        let live = try Self.packageSource("MarkdownEditor/MarkdownEditorView.swift")
        #expect(live.contains("tv.installFormattingAssistant()"),
                "the live editor must install the formatting affordance")

        let source = try Self.source("UI/SourceEditor.swift")
        #expect(source.contains("installFormattingAssistant()"),
                "the raw-source editor (Markdown and Split) must install it too")
        #expect(source.contains("MarkdownFormatting"),
                "and must be able to accept the commands")
    }

    /// The Mac's Format menu still reaches every editable mode.
    ///
    /// The shortcuts-bar buttons act on the text view directly, but a menu item
    /// is addressed to the *note*, so the bus is the other half — and the
    /// raw-source editor had no subscription to it at all until the toolbar
    /// work forced the question.
    @Test func theSourceEditorAnswersTheCommandBus() throws {
        let source = try Self.source("UI/SourceEditor.swift")
        #expect(source.contains(".hnFormat("),
                "the raw-source editor must subscribe to the formatting bus")
        for command in ["hnEditorUndo", "hnEditorRedo", "hnEditorEndEditing"] {
            #expect(source.contains(command), "the source editor ignores \(command)")
        }
    }

    /// Every button carries a name. An SF Symbol is not a label, and
    /// `testEveryReachableControlHasAName` cannot see into a system bar.
    @Test func everyFormattingButtonIsNamed() throws {
        let installer = try Self.packageSource("MarkdownEditor/EditorCommands.swift")
        for label in ["Bold", "Italic", "Strikethrough", "Highlight", "Code",
                      "Blockquote", "Bulleted List", "Numbered List",
                      "Text Style", "Lists", "Headings"] {
            #expect(installer.contains("\"\(label)\""), "no accessibility label for \(label)")
        }
        // Headings are built in a loop, so their labels are interpolated.
        #expect(installer.contains("\"Heading \\($0)\""))
    }

    /// Every `.popover` states what it becomes at a compact width.
    ///
    /// SwiftUI turns a popover into a **sheet** when the width is compact, and
    /// a sheet hands its content the whole height. Every panel in the editor's
    /// bottom bar is content-sized (`referencesPopover` is
    /// `.frame(width: 320).frame(maxHeight: 360)`), so on an iPhone each drew
    /// as a small island floating in the middle of a full-height sheet — no
    /// title, no grabber, no Done button. `showGitPane` had
    /// `.presentationCompactAdaptation(.popover)` and looked right; its three
    /// neighbours did not, and the difference is invisible on the Mac and on an
    /// iPad, which are the only places this bar was ever looked at.
    ///
    /// The rule is *state it*, not *always adapt*: a future panel may well want
    /// to be a real sheet on a phone. What it may not do is inherit an
    /// adaptation nobody chose. Anything opting into the sheet must say so with
    /// `.presentationCompactAdaptation(.sheet)`, which this accepts.
    @Test func everyPopoverStatesItsCompactAdaptation() throws {
        for file in ["UI/NoteEditorView.swift", "ContentView.swift"] {
            // **Code only.** The first run of this counted 4 popovers against 5
            // adaptations and failed — the fifth was the sentence above
            // `bottomBar` explaining the rule, which names the modifier. A scan
            // that reads its own documentation as source is measuring the wrong
            // thing, and it fails in the direction that looks like a real bug.
            let text = try Self.source(file)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            let popovers = text.components(separatedBy: ".popover(").count - 1
            let stated = text.components(separatedBy: ".presentationCompactAdaptation(").count - 1
            // One string literal, not a `+` chain: `#expect`'s comment is a
            // `Comment`, which is `ExpressibleByStringLiteral` — a concatenation
            // is an expression and does not convert.
            #expect(popovers == stated,
                    "\(file): \(popovers) popover(s) but \(stated) with a stated compact adaptation — an unstated one silently becomes a full-height sheet on iPhone, centring its content with no title bar")
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
