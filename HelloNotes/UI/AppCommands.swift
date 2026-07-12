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

/// File / Note / View menu commands.
struct HelloNotesCommands: Commands {
    @FocusedValue(\.appActions) private var actions

    /// The editor view mode, shared with the editor's bottom-bar picker.
    @AppStorage("editorViewMode") private var editorMode = EditorMode.edit.rawValue

    var body: some Commands {
        // MARK: File — creation and opening. Replaces "New Window" so ⌘N
        // makes a note (the app's primary object), not a duplicate window.
        CommandGroup(replacing: .newItem) {
            Button("New Note") { actions?.newNote() }
                .keyboardShortcut("n")
                .disabled(!(actions?.canNewNote ?? false))
            Button("Today's Note") { actions?.todaysNote() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!(actions?.canNewNote ?? false))

            Divider()

            Button("Open…") { actions?.openLauncher() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button("Open Quickly…") { actions?.openQuickly() }
                .keyboardShortcut("o")
                .disabled(!(actions?.canOpenQuickly ?? false))
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
    }
}
#endif
