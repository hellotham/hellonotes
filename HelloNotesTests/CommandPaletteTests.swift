//
//  CommandPaletteTests.swift
//  HelloNotesTests
//
//  Created by Chris Tham on 16/8/2026.
//

import Testing
import Foundation
@testable import HelloNotes

/// The palette's contract with the menu bar.
///
/// The palette exists so that a command you can name is a command you can run.
/// That promise decays silently: a new menu item that reaches the menu bar by
/// some route other than `AppActions` — a notification post, an `openWindow`
/// call — still works, still appears in the menu, and is simply absent from the
/// palette. Nothing breaks, nothing warns, and the feature is a little less true
/// than it was. A fact-check found eight commands that had drifted out that way,
/// which is the whole reason this file exists.
///
/// So the invariant is checked from the other end: **every action on
/// `AppActions` must produce a palette entry.** The menu itself is SwiftUI and
/// cannot be enumerated, but both surfaces are built from this one value, and
/// pinning it there catches the drift at the point it is introduced.
@MainActor
struct CommandPaletteTests {

    /// Every command available at once — a window with a collection, a note, a
    /// provider and several tabs open.
    private func fullActions() -> AppActions {
        AppActions(
            canNewNote: true, newNote: {}, todaysNote: {}, openLauncher: {},
            canOpenQuickly: true, openQuickly: {},
            canGraph: true, graphView: {},
            canAsk: true, askLibrary: {}, assistant: {},
            canCloseTab: true, closeTab: {},
            format: { _ in },
            note: NoteMenuActions(
                isBookmarked: false, rename: {}, duplicate: {}, toggleBookmark: {},
                copyWikiLink: {}, revealInFinder: {}, openInNewWindow: {},
                exportHTML: {}, exportPDF: {}, printNote: {}, moveToTrash: {}),
            rescan: {},
            showsNonNoteFiles: false, setShowsNonNoteFiles: { _ in },
            openCloudFolder: {}, refreshCloudCollection: {},
            commandPalette: {},
            ai: AIActions(providerName: "Test", summarize: {}, suggestTags: {},
                          suggestLinks: {}, rewriteNote: {}),
            reviewLinks: {}, composeNote: {},
            newWindow: {}, find: {}, searchAllCollections: {},
            connectOverWeb: { _ in },
            editorMode: .edit, setEditorMode: { _ in })
    }

    /// Ids the palette must offer when everything is available.
    ///
    /// Listed explicitly rather than counted: a count tells you *that* something
    /// changed, this tells you *what*, and the failure message is then the fix.
    private let required: Set<String> = [
        // File
        "new-note", "compose-note", "todays-note", "open-quickly", "launcher",
        "open-cloud", "refresh-cloud", "rescan", "new-main-window", "close-tab",
        "connect-remoteBrowser", "connect-remoteBrowserBox",
        "connect-remoteBrowserGDrive", "connect-remoteBrowserOneDrive",
        // Edit
        "find", "search-all",
        // View
        "graph", "toggle-files",
        // Assistant
        "ask-library", "assistant",
        // Note
        "ai-summarize", "ai-tags", "ai-links", "ai-rewrite", "review-links",
        "rename", "duplicate", "bookmark", "copy-link", "reveal", "new-window",
        "export-html", "export-pdf", "print", "trash",
        // Format
        "format-bold", "format-italic", "format-strikethrough", "format-highlight",
        "format-code", "format-quote", "format-ul", "format-ol",
        "format-h1", "format-h2", "format-h3",
    ]

    @Test func everyCommandIsInThePalette() {
        let ids = Set(fullActions().paletteCommands.map(\.id))
        let missing = required.subtracting(ids)
        #expect(missing.isEmpty, "Commands missing from the palette: \(missing.sorted())")
    }

    /// The palette must not offer to open itself — the one row that can only
    /// ever be a no-op, since you are already looking at it.
    @Test func thePaletteDoesNotOfferToOpenItself() {
        let titles = fullActions().paletteCommands.map(\.title)
        #expect(!titles.contains { $0.localizedCaseInsensitiveContains("command palette") })
    }

    /// The list is a `List(selection:)`, so a duplicate id silently breaks
    /// keyboard selection for both rows that share it.
    @Test func idsAreUnique() {
        let ids = fullActions().paletteCommands.map(\.id)
        #expect(ids.count == Set(ids).count)
    }

    /// The mode you are already in is not a command. Offering "Edit Mode" while
    /// in Edit mode is a row that does nothing, and the palette's whole claim is
    /// that anything you can find, you can run.
    @Test func theCurrentEditorModeIsNotOffered() {
        var actions = fullActions()
        actions.editorMode = .preview
        let ids = Set(actions.paletteCommands.map(\.id))
        #expect(!ids.contains("mode-preview"))
        #expect(ids.contains("mode-edit"))
        #expect(ids.contains("mode-markdown"))
        #expect(ids.contains("mode-split"))
    }

    /// Formatting is routed to the editor over a notification bus that only
    /// `MarkdownTextView` installs — and that view is mounted in Edit mode
    /// alone. In Preview, Markdown and Split nothing is listening, so a
    /// "Bold" row would appear and silently do nothing. The menu had always
    /// checked the mode; the palette had not, and the first version of this
    /// suite could not see it because `fullActions()` pins `.edit`.
    @Test func formattingIsOfferedOnlyInEditMode() {
        var actions = fullActions()
        #expect(actions.paletteCommands.contains { $0.id == "format-bold" })

        for mode in [EditorMode.preview, .markdown, .split] {
            actions.editorMode = mode
            let ids = Set(actions.paletteCommands.map(\.id))
            #expect(!ids.contains("format-bold"), "format commands leak in \(mode.label) mode")
            #expect(!ids.contains("format-h1"), "heading commands leak in \(mode.label) mode")
        }
    }

    /// The palette is not a macOS surface — `iOSContentView` presents the same
    /// sheet — so its mode rows have to come from the platform's list. It read
    /// `EditorMode.macCases` while the View menu read `platformCases`, which is
    /// harmless only for as long as the two lists stay equal, and the point of
    /// a shared registry is that nobody has to remember that.
    @Test func editorModeRowsFollowThePlatformList() {
        var actions = fullActions()
        actions.editorMode = .preview
        let ids = Set(actions.paletteCommands.map(\.id))
        let expected = Set(EditorMode.platformCases
            .filter { $0 != .preview }
            .map { "mode-\($0.rawValue)" })
        #expect(Set(ids.filter { $0.hasPrefix("mode-") }) == expected)
    }

    /// The five rows that a trailing-closure literal smuggled past `add`'s
    /// `guard let run`.
    ///
    /// Most entries hand their optional action straight through — `run:
    /// note.revealInFinder` — so a nil action omits the row. "New Window" and
    /// the four "Connect … Over the Web…" rows wrapped theirs in `{ newWindow?()
    /// }` instead, and a closure literal is never nil: the rows were appended
    /// unconditionally. On iPad both actions *are* nil, so the palette listed
    /// five commands that dismissed it and did nothing. Everything else in this
    /// suite passes non-nil actions, which is exactly why none of it saw this.
    @Test func nilOptionalActionsProduceNoRows() {
        let noWindowsNoWeb = AppActions(
            canNewNote: true, newNote: {}, todaysNote: {}, openLauncher: {},
            canOpenQuickly: true, openQuickly: {},
            canGraph: true, graphView: {},
            canAsk: true, askLibrary: {}, assistant: {},
            canCloseTab: true, closeTab: {},
            searchAllCollections: {},
            editorMode: .edit, setEditorMode: { _ in })
        let ids = Set(noWindowsNoWeb.paletteCommands.map(\.id))

        #expect(!ids.contains("new-main-window"), "New Window survived a nil newWindow")
        for provider in CloudBrowser.allCases {
            #expect(!ids.contains("connect-\(provider.rawValue)"),
                    "connect-\(provider.rawValue) survived a nil connectOverWeb")
        }
        // The window's other commands are untouched — this is about the two
        // optional actions, not about emptying the palette.
        #expect(ids.contains("new-note"))
        #expect(ids.contains("close-tab"))
    }

    /// Commands that need a note, a collection or a provider must disappear
    /// rather than appear and fail — the palette greys nothing out, so an
    /// unavailable command has to be absent.
    @Test func unavailableCommandsAreAbsentRatherThanBroken() {
        let bare = AppActions(
            canNewNote: false, newNote: {}, todaysNote: {}, openLauncher: {},
            canOpenQuickly: false, openQuickly: {},
            canGraph: false, graphView: {},
            canAsk: false, askLibrary: {}, assistant: {},
            canCloseTab: false, closeTab: {},
            newWindow: {}, searchAllCollections: {}, connectOverWeb: { _ in },
            editorMode: .edit, setEditorMode: { _ in })
        let ids = Set(bare.paletteCommands.map(\.id))

        for absent in ["new-note", "todays-note", "open-quickly", "graph", "ask-library", "close-tab",
                       "rescan", "refresh-cloud", "find", "review-links", "compose-note",
                       "ai-summarize", "rename", "print", "format-bold"] {
            #expect(!ids.contains(absent), "\(absent) should be absent with nothing open")
        }
        // These need nothing at all, so they must survive.
        #expect(ids.contains("new-main-window"))
        #expect(ids.contains("search-all"))
        #expect(ids.contains("launcher"))
    }
}
