//
//  CommandPalette.swift
//  HelloNotes
//
//  Created by Chris Tham on 15/8/2026.
//
//  Every command in the app, findable by typing its name (⌘⇧P).
//
//  The app had grown surfaces faster than it had grown ways to reach them —
//  most visibly the AI features, which sat in a panel organised by the fact that
//  a model was involved rather than by what they act on, and so went unnoticed.
//  A palette does not fix organisation, but it does mean nothing is *lost*: if
//  you can name it, you can run it.
//
//  Built from `AppActions` — the same value the menu bar is built from — on
//  purpose. A palette with its own hand-maintained command list is a second
//  source of truth that drifts the first time someone adds a menu item and
//  forgets, and the failure is silent: the command still works, it is just
//  unfindable, which is precisely the problem being solved.
//

#if os(macOS)
import SwiftUI

/// One runnable command.
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    /// Where it lives, so the list reads as a map of the app rather than a heap.
    let group: String
    let symbol: String
    /// Shown right-aligned when the command also has a shortcut worth learning.
    var shortcut: String?
    let run: () -> Void
}

struct CommandPaletteView: View {
    let commands: [PaletteCommand]

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: PaletteCommand.ID?
    @FocusState private var fieldFocused: Bool

    /// Ranked matches. Scored against `"Group Title"` so "note new" finds
    /// **Note ▸ New Note** — people remember where a command lives at least as
    /// often as they remember its exact name.
    private var results: [PaletteCommand] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return commands }
        return commands
            .compactMap { command -> (PaletteCommand, Int)? in
                guard let score = FuzzyMatch.score(query: q,
                                                   candidate: "\(command.group) \(command.title)")
                else { return nil }
                return (command, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Run a command…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($fieldFocused)
                .onSubmit(runSelected)

            Divider()

            if results.isEmpty {
                ContentUnavailableView("No matching command", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results, selection: $selection) { command in
                    row(command)
                        .tag(command.id)
                        .contentShape(.rect)
                        .onTapGesture { run(command) }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 540, height: 420)
        // Escape must dismiss even when the field has lost first responder —
        // the same reason Open Quickly does not rely on the sheet's cancel action.
        .onExitCommand { dismiss() }
        .onAppear { fieldFocused = true; selection = commands.first?.id }
        .onChange(of: query) { _, _ in
            // Keep a valid top selection as the query narrows, so Return always
            // has something to run.
            let matches = results
            if selection == nil || !matches.contains(where: { $0.id == selection }) {
                selection = matches.first?.id
            }
        }
    }

    private func row(_ command: PaletteCommand) -> some View {
        HStack(spacing: 8) {
            Image(systemName: command.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                Text(command.group)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let shortcut = command.shortcut {
                Text(shortcut)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func runSelected() {
        guard let command = results.first(where: { $0.id == selection }) ?? results.first else { return }
        run(command)
    }

    /// Dismiss *before* running: several commands present sheets of their own,
    /// and a sheet raised from inside a dismissing sheet is how the Open Quickly
    /// palette used to wedge.
    private func run(_ command: PaletteCommand) {
        dismiss()
        DispatchQueue.main.async(execute: command.run)
    }
}

// MARK: - Building the list from AppActions

extension AppActions {
    /// Every command the menus offer, as palette entries.
    ///
    /// Disabled commands are **omitted rather than greyed**: a menu shows you
    /// what exists in a fixed place you can learn, while a search result you
    /// cannot act on is just a dead end.
    var paletteCommands: [PaletteCommand] {
        var commands: [PaletteCommand] = []

        func add(_ id: String, _ group: String, _ title: String, _ symbol: String,
                 shortcut: String? = nil, enabled: Bool = true, run: (() -> Void)?) {
            guard enabled, let run else { return }
            commands.append(PaletteCommand(id: id, title: title, group: group,
                                           symbol: symbol, shortcut: shortcut, run: run))
        }

        // File
        add("new-note", "File", "New Note", "square.and.pencil",
            shortcut: "⌘N", enabled: canNewNote, run: newNote)
        add("todays-note", "File", "Today's Note", "calendar",
            enabled: canNewNote, run: todaysNote)
        add("compose-note", "File", "New Note from a Prompt…", "sparkles.square.filled.on.square",
            shortcut: "⌃⌘N", run: composeNote)
        add("open-quickly", "File", "Open Quickly", "magnifyingglass",
            shortcut: "⌘O", enabled: canOpenQuickly, run: openQuickly)
        add("launcher", "File", "Open Collection", "folder", run: openLauncher)
        add("open-cloud", "File", "Open Cloud Folder", "cloud", run: openCloudFolder)
        add("refresh-cloud", "File", "Refresh Cloud Collection", "arrow.clockwise",
            run: refreshCloudCollection)
        add("rescan", "File", "Rescan Collection", "arrow.triangle.2.circlepath", run: rescan)
        add("new-main-window", "File", "New Window", "macwindow",
            shortcut: "⌥⌘N") { newWindow?() }
        add("close-tab", "File", "Close Tab", "xmark.square",
            enabled: canCloseTab, run: closeTab)
        for provider in CloudBrowser.allCases {
            add("connect-\(provider.rawValue)", "File",
                "Connect \(provider.displayName) Over the Web…", "cloud") {
                connectOverWeb?(provider)
            }
        }
        // Deliberately no entry for the palette itself: a command that opens the
        // thing you are already looking at is the one row nobody can want.

        // Edit
        add("find", "Edit", "Find in Note", "magnifyingglass", shortcut: "⌘F", run: find)
        add("search-all", "Edit", "Search All Collections", "sparkle.magnifyingglass",
            shortcut: "⌥⌘F", run: searchAllCollections)
        if DictationController.shared.isSupported {
            let recording = DictationController.shared.isRecording
            add("dictate", "Edit", recording ? "Stop Dictation" : "Dictate to Daily Note",
                recording ? "mic.slash" : "mic", shortcut: "⌃⌘D") {
                DictationController.shared.toggle()
            }
        }

        // View
        for mode in EditorMode.macCases where mode != editorMode {
            add("mode-\(mode.rawValue)", "View", "\(mode.label) Mode", mode.symbol) {
                setEditorMode(mode)
            }
        }
        add("graph", "View", "Graph View", "point.3.connected.trianglepath.dotted",
            shortcut: "⌘⇧G", enabled: canGraph, run: graphView)
        if let showsNonNoteFiles, let setShowsNonNoteFiles {
            add("toggle-files", "View",
                showsNonNoteFiles ? "Hide Non-Note Files" : "Show Non-Note Files",
                showsNonNoteFiles ? "eye.slash" : "eye") { setShowsNonNoteFiles(!showsNonNoteFiles) }
        }

        // Assistant
        add("ask-library", "Assistant", "Ask Your Library", "sparkles.rectangle.stack",
            shortcut: "⌘⇧J", enabled: canAsk, run: askLibrary)
        add("assistant", "Assistant", "Assistant", "sparkles",
            shortcut: "⌘⇧A", run: assistant)

        // AI on the open note. Grouped under "Note" rather than under a heading
        // of their own: someone hunting for a way to summarise is thinking
        // about the note, not about which subsystem answers.
        if let ai {
            add("ai-summarize", "Note", "Summarise Note", "text.append", run: ai.summarize)
            add("ai-tags", "Note", "Suggest Tags", "number", run: ai.suggestTags)
            add("ai-links", "Note", "Suggest Links", "link.badge.plus", run: ai.suggestLinks)
            add("ai-rewrite", "Note", "Rewrite or Expand Note…", "wand.and.stars", run: ai.rewriteNote)
        }

        add("review-links", "Note", "Review Links…", "link.badge.plus",
            shortcut: "⌘⇧L", run: reviewLinks)

        // Note — only when one is selected, which is exactly when they mean anything.
        if let note {
            add("rename", "Note", "Rename Note", "pencil", run: note.rename)
            add("duplicate", "Note", "Duplicate Note", "plus.square.on.square", run: note.duplicate)
            add("bookmark", "Note",
                note.isBookmarked ? "Remove Bookmark" : "Bookmark Note",
                note.isBookmarked ? "bookmark.slash" : "bookmark", run: note.toggleBookmark)
            add("copy-link", "Note", "Copy Wiki Link", "link", run: note.copyWikiLink)
            add("reveal", "Note", "Reveal in Finder", "folder", run: note.revealInFinder)
            add("new-window", "Note", "Open in New Window", "macwindow", run: note.openInNewWindow)
            add("export-html", "Note", "Export as HTML…", "doc.richtext", run: note.exportHTML)
            add("export-pdf", "Note", "Export as PDF…", "doc.richtext", run: note.exportPDF)
            add("print", "Note", "Print…", "printer", shortcut: "⌘P", run: note.printNote)
            add("trash", "Note", "Move to Trash", "trash", run: note.moveToTrash)
        }

        // Format — an editable note focused, **and the editor actually on
        // screen**. The formatting bus is installed by `MarkdownTextView` via
        // `.commandBus(documentId:)`, and that view is only mounted in Edit
        // mode: in Preview, Markdown and Split there is nothing listening, so
        // "Bold" would appear and silently do nothing. The menu has always
        // checked the mode; the palette did not, which is the same promise
        // broken in the surface that makes the promise.
        if let format, editorMode == .edit {
            let actions: [(String, String, String, FormatAction)] = [
                ("bold", "Bold", "bold", .bold),
                ("italic", "Italic", "italic", .italic),
                ("strikethrough", "Strikethrough", "strikethrough", .strikethrough),
                ("highlight", "Highlight", "highlighter", .highlight),
                ("code", "Inline Code", "chevron.left.forwardslash.chevron.right", .inlineCode),
                ("quote", "Blockquote", "text.quote", .blockquote),
                ("ul", "Bulleted List", "list.bullet", .unorderedList),
                ("ol", "Numbered List", "list.number", .orderedList),
            ]
            for (id, title, symbol, action) in actions {
                add("format-\(id)", "Format", title, symbol) { format(action) }
            }
            for level in 1...3 {
                add("format-h\(level)", "Format", "Heading \(level)", "textformat.size") {
                    format(.heading(level))
                }
            }
        }

        return commands
    }
}
#endif
