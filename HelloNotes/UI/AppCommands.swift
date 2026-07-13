//
//  AppCommands.swift
//  HelloNotes
//
//  Created by Chris Tham on 13/7/2026.
//
//  The macOS menu bar. The main window publishes its actions through a focused
//  scene value (`AppActions`), so every command below targets whichever window
//  is frontmost and greys out when it doesn't apply. This is the app's primary
//  discoverability surface: every major feature lives here with its shortcut.
//

#if os(macOS)
import SwiftUI
import AppKit

/// A Markdown formatting command the Format menu can send to the focused
/// editor (routed to MarkdownEngine through its notification bus).
enum FormatAction {
    case bold, italic, strikethrough, highlight, inlineCode
    case blockquote, unorderedList, orderedList
    case heading(Int)
}

/// The actions a HelloNotes window offers to the menu bar.
struct AppActions {
    var canNewNote: Bool
    var newNote: () -> Void
    var todaysNote: () -> Void
    var openLauncher: () -> Void
    var canOpenQuickly: Bool
    var openQuickly: () -> Void
    var canGraph: Bool
    var graphView: () -> Void
    var canAsk: Bool
    var askLibrary: () -> Void
    var assistant: () -> Void
    /// Close the active editor tab. Enabled only when more than one tab is
    /// open, so ⌘W falls through to the standard window Close otherwise.
    var canCloseTab: Bool
    var closeTab: () -> Void
    /// Send a Markdown formatting command to the active editor. `nil` when no
    /// editable note is focused (Format menu greys out).
    var format: ((FormatAction) -> Void)?
    /// Actions on the selected note; `nil` when no note is selected.
    var note: NoteMenuActions?
}

/// Menu actions that act on the selected note.
struct NoteMenuActions {
    var isBookmarked: Bool
    var rename: () -> Void
    var duplicate: () -> Void
    var toggleBookmark: () -> Void
    var copyWikiLink: () -> Void
    var revealInFinder: () -> Void
    var openInNewWindow: () -> Void
    var exportHTML: () -> Void
    var exportPDF: () -> Void
    var moveToTrash: () -> Void
}

extension FocusedValues {
    @Entry var appActions: AppActions?
}

/// File / Note / Format / View menu commands.
struct HelloNotesCommands: Commands {
    @FocusedValue(\.appActions) private var actions
    @Environment(\.openWindow) private var openWindow

    /// The editor view mode, shared with the editor's bottom-bar picker.
    @AppStorage("editorViewMode") private var editorMode = EditorMode.edit.rawValue

    /// Formatting applies only in the live-editing mode with a note focused.
    private var canFormat: Bool {
        actions?.format != nil && actions?.note != nil && editorMode == EditorMode.edit.rawValue
    }

    var body: some Commands {
        // MARK: App — About shows the splash (it carries the version, build,
        // and credits), staying up until clicked.
        CommandGroup(replacing: .appInfo) {
            Button("About HelloNotes") { SplashWindow.show(autoDismiss: false) }
        }

        // MARK: File — creation and opening. ⌘N makes a note (the app's
        // primary object, the Mail convention); New Window moves to ⌥⌘N.
        CommandGroup(replacing: .newItem) {
            Button("New Note") { actions?.newNote() }
                .keyboardShortcut("n")
                .disabled(!(actions?.canNewNote ?? false))
            Button("New Window") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("Today's Note") { actions?.todaysNote() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!(actions?.canNewNote ?? false))

            Divider()

            // ⌘O opens things (the HIG-reserved meaning); Open Quickly takes
            // ⇧⌘O, the Xcode convention.
            Button("Open…") { actions?.openLauncher() }
                .keyboardShortcut("o")
                .disabled(actions == nil)
            Button("Open Quickly…") { actions?.openQuickly() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(!(actions?.canOpenQuickly ?? false))

            Divider()

            // Deliberately no ⌘W here: SwiftUI won't reliably attach a key
            // equivalent that the standard Close item already owns. The main
            // window intercepts ⌘W itself while several tabs are open (view
            // shortcuts beat menu items), so ⌘W closes the tab then and the
            // window otherwise — the Safari/Xcode convention. This item is the
            // discoverable, clickable counterpart.
            Button("Close Tab") { actions?.closeTab() }
                .disabled(!(actions?.canCloseTab ?? false))
        }

        // MARK: File — export lives where macOS users expect it.
        CommandGroup(after: .importExport) {
            Button("Export as HTML…") { actions?.note?.exportHTML() }
                .disabled(actions?.note == nil)
            Button("Export as PDF…") { actions?.note?.exportPDF() }
                .disabled(actions?.note == nil)
        }

        // MARK: Note — everything that acts on the selected note.
        CommandMenu("Note") {
            Button("Rename…") { actions?.note?.rename() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(actions?.note == nil)
            Button("Duplicate") { actions?.note?.duplicate() }
                .disabled(actions?.note == nil)
            Button((actions?.note?.isBookmarked ?? false) ? "Remove Bookmark" : "Add Bookmark") {
                actions?.note?.toggleBookmark()
            }
            .keyboardShortcut("d")
            .disabled(actions?.note == nil)

            Divider()

            Button("Copy Wiki Link") { actions?.note?.copyWikiLink() }
                .disabled(actions?.note == nil)
            Button("Reveal in Finder") { actions?.note?.revealInFinder() }
                .disabled(actions?.note == nil)
            Button("Open in New Window") { actions?.note?.openInNewWindow() }
                .disabled(actions?.note == nil)

            Divider()

            Button("Move to Trash") { actions?.note?.moveToTrash() }
                .keyboardShortcut(.delete)
                .disabled(actions?.note == nil)
        }

        // MARK: Format — Markdown styling for the live editor.
        CommandMenu("Format") {
            Button("Bold") { actions?.format?(.bold) }
                .keyboardShortcut("b")
                .disabled(!canFormat)
            Button("Italic") { actions?.format?(.italic) }
                .keyboardShortcut("i")
                .disabled(!canFormat)
            Button("Strikethrough") { actions?.format?(.strikethrough) }
                .disabled(!canFormat)
            Button("Highlight") { actions?.format?(.highlight) }
                .disabled(!canFormat)
            Button("Inline Code") { actions?.format?(.inlineCode) }
                .disabled(!canFormat)

            Divider()

            // ⌥⌘1–3, the Apple Notes heading convention.
            ForEach(1...3, id: \.self) { level in
                Button("Heading \(level)") { actions?.format?(.heading(level)) }
                    .keyboardShortcut(KeyEquivalent(Character("\(level)")), modifiers: [.command, .option])
                    .disabled(!canFormat)
            }

            Divider()

            Button("Blockquote") { actions?.format?(.blockquote) }
                .disabled(!canFormat)
            // ⇧⌘7 / ⇧⌘9, the Apple Notes list shortcuts.
            Button("Bulleted List") { actions?.format?(.unorderedList) }
                .keyboardShortcut("7", modifiers: [.command, .shift])
                .disabled(!canFormat)
            Button("Numbered List") { actions?.format?(.orderedList) }
                .keyboardShortcut("9", modifiers: [.command, .shift])
                .disabled(!canFormat)
        }

        // MARK: View — editor presentation and the app's overview surfaces.
        CommandGroup(before: .toolbar) {
            ForEach(Array(EditorMode.macCases.enumerated()), id: \.element) { index, mode in
                Toggle(mode.label, isOn: Binding(
                    get: { editorMode == mode.rawValue },
                    set: { if $0 { editorMode = mode.rawValue } }
                ))
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }

            Divider()

            Button("Graph View") { actions?.graphView() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!(actions?.canGraph ?? false))
            Button("Ask Library") { actions?.askLibrary() }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(!(actions?.canAsk ?? false))
            Button("Assistant") { actions?.assistant() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(actions == nil)

            Divider()
        }

        // MARK: Help — point the stock stub somewhere real.
        CommandGroup(replacing: .help) {
            Button("HelloNotes Help") {
                NSWorkspace.shared.open(URL(string: "https://github.com/hellotham/hellonotes")!)
            }
        }
    }
}

// MARK: - Formatting bus names

extension Notification.Name {
    /// The per-document notification name for a formatting request. Scoped by
    /// `documentId` so a Format command reaches only the focused editor, never
    /// the same note open in another window.
    static func hnFormat(_ kind: String, documentId: String) -> Notification.Name {
        Notification.Name("hnEditorFormat.\(kind).\(documentId)")
    }
}

extension FormatAction {
    /// The bus-name suffix and optional userInfo for this action.
    var kind: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .strikethrough: "strikethrough"
        case .highlight: "highlight"
        case .inlineCode: "inlineCode"
        case .blockquote: "blockquote"
        case .unorderedList: "unorderedList"
        case .orderedList: "orderedList"
        case .heading: "heading"
        }
    }

    var userInfo: [String: Any]? {
        if case .heading(let level) = self { return ["level": level] }
        return nil
    }
}
#endif
