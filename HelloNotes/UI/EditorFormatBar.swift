//
//  EditorFormatBar.swift
//  HelloNotes
//
//  The formatting bar — bold, italic, lists, headings, undo, redo — as the
//  app's own chrome.
//
//  ## Why it is not an `inputAccessoryView` any more
//
//  It used to be one, hung off the editor's `UITextView`. That tied its
//  visibility to **first-responder state**, which is not a rule anybody can
//  state or predict:
//
//    * switching to Edit mode did *not* show it — you had to tap into the text
//      as well, because only that made the text view first responder;
//    * tapping the sidebar, or anything else that took focus, hid it again
//      while the editor was still in Edit mode;
//    * in Preview it was absent only because nothing happened to be focused,
//      not because Preview says it should be;
//    * and with a hardware keyboard iOS docks an accessory at the bottom of the
//      screen, where it drew over the app's own bottom bar.
//
//  "Sometimes there, sometimes not" was an accurate description of the rule.
//
//  The rule now is the one a person would expect: **visible in Edit, invisible
//  in Preview**, and nothing else changes it. `NoteEditorView` renders this
//  inside the same bottom safe-area inset as the word count, under
//  `if mode == .edit`, so the two bars are one stack and cannot overlap.
//
//  ## How the buttons reach the text
//
//  Through the same notification bus the Mac's Format menu uses
//  (`FormatAction` / `hnFormat`), addressed to the note's path. App chrome
//  holds no reference to a text view, and it should not: undo especially could
//  not be left to the responder chain, because UIKit resolves `undoManager` up
//  that chain and a button outside the editor would find the *window's* stack
//  rather than the document's — undoing into text that is not there.
//

import SwiftUI

struct EditorFormatBar: View {
    /// The document these commands are addressed to.
    let documentId: String

    /// Bar height, matched to the bottom status row so the two read as one
    /// piece of chrome rather than two stacked strips.
    static let height: CGFloat = 40

    private struct Command: Identifiable {
        let id: String
        let symbol: String
        let label: String
        let action: FormatAction
    }

    private let commands: [Command] = [
        .init(id: "bold", symbol: "bold", label: "Bold", action: .bold),
        .init(id: "italic", symbol: "italic", label: "Italic", action: .italic),
        .init(id: "strikethrough", symbol: "strikethrough",
              label: "Strikethrough", action: .strikethrough),
        .init(id: "highlight", symbol: "highlighter", label: "Highlight", action: .highlight),
        .init(id: "code", symbol: "chevron.left.forwardslash.chevron.right",
              label: "Code", action: .inlineCode),
        .init(id: "quote", symbol: "text.quote", label: "Blockquote", action: .blockquote),
        .init(id: "ul", symbol: "list.bullet", label: "Bulleted List", action: .unorderedList),
        .init(id: "ol", symbol: "list.number", label: "Numbered List", action: .orderedList),
        .init(id: "h1", symbol: "1.square", label: "Heading 1", action: .heading(1)),
        .init(id: "h2", symbol: "2.square", label: "Heading 2", action: .heading(2)),
        .init(id: "h3", symbol: "3.square", label: "Heading 3", action: .heading(3)),
    ]

    var body: some View {
        HStack(spacing: 0) {
            // Scrolls rather than truncates. The same rule the status bar
            // follows: a command nobody can reach is a command that does not
            // exist, and eleven fixed-width buttons do not fit an iPhone.
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(commands) { command in
                        button(command.symbol, command.label) { post(command.action) }
                    }
                }
                .padding(.horizontal, 4)
            }
            .scrollIndicators(.hidden)

            Divider().frame(height: 20).padding(.horizontal, 4)

            button("arrow.uturn.backward", "Undo") { post(named: "hnEditorUndo") }
            button("arrow.uturn.forward", "Redo") { post(named: "hnEditorRedo") }
            button("keyboard.chevron.compact.down", "Hide Keyboard") {
                post(named: "hnEditorEndEditing")
            }
        }
        .frame(height: Self.height)
        .background(.bar)
    }

    private func button(_ symbol: String, _ label: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 34, height: 30)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Named, not just drawn: `testEveryReachableControlHasAName` rejects a
        // control whose only label is an SF Symbol name.
        .accessibilityLabel(label)
        .help(label)
    }

    private func post(_ action: FormatAction) {
        NotificationCenter.default.post(
            name: .hnFormat(action.kind, documentId: documentId),
            object: nil, userInfo: action.userInfo)
    }

    private func post(named name: String) {
        NotificationCenter.default.post(
            name: Notification.Name("\(name).\(documentId)"), object: nil)
    }
}
