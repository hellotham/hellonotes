//
//  ShellActions.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  What the sidebar's commands actually do — one implementation.
//
//  `SidebarMenu` made the two platforms offer the same commands. This makes
//  them *do* the same thing, which is the other half: the two shells each had
//  their own rename, delete, duplicate, move and create, under names that
//  differed just enough to hide that they were the same function.
//
//    · `performRename()` / `renameNote(_:to:)` — same body, and only one of
//      them carried the comment explaining why it must flush every tab
//    · `moveItem(at:into:)` / `moveItems(_:into:of:)` — singular and plural of
//      one operation; the Mac's drop delivered one URL and the iPad's many,
//      which is a difference between two drag APIs, not between two features
//    · `delete(_:in:)` / an inline closure that did the same three lines
//    · new-note-in-a-folder, written twice with different fallbacks for "which
//      collection when the row names none"
//
//  Every one of those is shell state plus a `Collection` call. Neither is
//  platform-shaped, so neither belongs in a file that only one platform can
//  see. The shell keeps the state (a `@State` note being renamed is genuinely
//  the view's); this owns what happens to it.
//

import SwiftUI

@MainActor
struct ShellActions {
    let library: Library
    let tabs: EditorTabs
    let selection: Binding<URL?>
    /// The collection a command lands in when the row it came from names none —
    /// the sidebar's selection, falling back to the focused collection.
    let scope: Collection?

    let renameTarget: Binding<Note?>
    let renameText: Binding<String>
    let newFolderCollection: Binding<Collection?>
    let newFolderParent: Binding<URL?>
    let newFolderName: Binding<String>
    let pendingFolderDelete: Binding<URL?>
    let expandedFolders: Binding<Set<String>>

    /// Open a note in a second scene. Both platforms have one; the call is
    /// `openWindow(value:)` on each, but the shell owns the environment action.
    let openNoteWindow: (Note) -> Void
    /// Start the link-review flow against the open note.
    let reviewLinks: () -> Void

    /// The editor showing the selected note, if any.
    var activeEditor: EditorModel? { tabs.editor(withID: selection.wrappedValue) }

    // MARK: Notes

    func beginRename(_ note: Note) {
        renameText.wrappedValue = note.title
        renameTarget.wrappedValue = note
    }

    /// Commit the rename in progress.
    ///
    /// **Every** tab is flushed, not just the front one: a rename raised from
    /// the sidebar is usually aimed at a note other than the selected one.
    /// Renaming moves the file, and an in-flight autosave would be writing to
    /// the old path — `EditorTabs.prune` deliberately keeps a dirty editor, and
    /// that editor holds the pre-rename URL, so its next save would resurrect a
    /// ghost file at the old name while the renamed file never received the
    /// edits.
    func commitRename() {
        guard let note = renameTarget.wrappedValue else { return }
        let title = renameText.wrappedValue
        renameTarget.wrappedValue = nil
        rename(note, to: title)
    }

    /// Rename directly, for the paths that already have both values — the
    /// editor's inline title, and anything scripted. Separate from
    /// `commitRename()` because writing `@State` and reading it back inside one
    /// call sees the old value.
    func rename(_ note: Note, to title: String) {
        guard let collection = library.collection(containing: note.fileURL) else { return }
        Task {
            await tabs.flushAll()
            if let renamed = await collection.renameNote(note, to: title) {
                selection.wrappedValue = renamed.id
            }
        }
    }

    /// Duplicate, and select the copy — leaving you looking at the original
    /// with a duplicate somewhere in the tree reads as "nothing happened".
    func duplicate(_ note: Note) {
        guard let collection = library.collection(containing: note.fileURL) else { return }
        Task {
            if let copy = await collection.duplicateNote(note) {
                selection.wrappedValue = copy.id
            }
        }
    }

    func delete(_ note: Note) {
        guard let collection = library.collection(containing: note.fileURL) else { return }
        if selection.wrappedValue == note.id { selection.wrappedValue = nil }
        Task { await collection.deleteNote(note) }
    }

    /// The note's current text: the editor's buffer when it holds this note,
    /// the file otherwise. Exporting the file while an editor holds unsaved
    /// edits exports the wrong thing.
    func text(of note: Note) -> String {
        if let editor = tabs.editor(withID: note.id), editor.note?.fileURL == note.fileURL {
            return editor.text
        }
        return (try? FileIO.readString(at: note.fileURL)) ?? ""
    }

    /// Append an expanded template to the open note.
    ///
    /// Appended, not replacing: a template is something you add to what you are
    /// writing. The read happens off-main (`Templates.expanded`), so a template
    /// on a cloud provider cannot stall the editor.
    func insertTemplate(_ template: TemplateRef) {
        guard let editor = activeEditor else { return }
        let title = editor.note?.title ?? ""
        Task {
            guard let expanded = await Templates.expanded(template, noteTitle: title)
            else { return }
            editor.text += (editor.text.isEmpty ? "" : "\n") + expanded
        }
    }

    func isBookmarked(_ note: Note) -> Bool {
        library.collection(containing: note.fileURL)?.bookmarks.isBookmarked(note) ?? false
    }

    func isOpenInEditor(_ note: Note) -> Bool {
        activeEditor?.note?.fileURL == note.fileURL
    }

    // MARK: Folders and collections

    /// The collection an outline-item id belongs to. A folder id is the
    /// folder's absolute path, which begins with its collection's root path.
    func collection(forFolderID id: String) -> Collection? {
        library.collections.first { id == $0.id || id.hasPrefix($0.id + "/") }
    }

    /// Open a folder in the sidebar, so something created inside it is not
    /// created into a folder that is closed — a selection you cannot see.
    func expand(_ folderID: String) {
        var open = expandedFolders.wrappedValue
        open.insert(folderID)
        expandedFolders.wrappedValue = open
    }

    func createNote(in collection: Collection?, folderID: String?) {
        if let folderID, let owner = self.collection(forFolderID: folderID) {
            let folder = URL(fileURLWithPath: folderID, isDirectory: true)
            Task {
                if let note = await owner.createNote(in: folder) {
                    selection.wrappedValue = note.id
                }
            }
        } else if let owner = collection ?? scope {
            Task {
                if let note = await owner.createNote() { selection.wrappedValue = note.id }
            }
        }
    }

    func beginNewFolder(in collection: Collection?, folderID: String?) {
        if let folderID, let owner = self.collection(forFolderID: folderID) {
            newFolderParent.wrappedValue = URL(fileURLWithPath: folderID, isDirectory: true)
            newFolderCollection.wrappedValue = owner
        } else if let owner = collection ?? scope {
            newFolderParent.wrappedValue = nil
            newFolderCollection.wrappedValue = owner
        }
        newFolderName.wrappedValue = ""
    }

    func closeCollection(_ collection: Collection) {
        // Clear a selection that lives in the collection being closed, or the
        // editor keeps showing a note from a library that is no longer open.
        if let selected = selection.wrappedValue,
           library.collection(containing: selected)?.id == collection.id {
            selection.wrappedValue = nil
        }
        library.close(collection)
    }

    /// Move dropped items into a folder. Plural because a drop can carry
    /// several; the Mac's `NSOutlineView` drop happens to deliver one.
    @discardableResult
    func move(_ urls: [URL], intoFolderWithID folderID: String) -> Bool {
        guard let collection = collection(forFolderID: folderID) else { return false }
        let folder = URL(fileURLWithPath: folderID, isDirectory: true)
        let sources = urls.filter { library.collection(containing: $0)?.id == collection.id }
        guard !sources.isEmpty else { return false }
        Task {
            await tabs.flushAll()
            for source in sources {
                let wasSelected = selection.wrappedValue == source
                if let destination = await collection.moveItem(at: source, into: folder),
                   wasSelected {
                    selection.wrappedValue = destination
                }
            }
        }
        return true
    }

    // MARK: The sidebar's menu

    /// Bound to `SidebarMenu`, which decides *which* commands there are.
    var sidebarMenu: SidebarMenu.Actions {
        SidebarMenu.Actions(
            isBookmarked: { isBookmarked($0) },
            toggleBookmark: { note in
                library.collection(containing: note.fileURL)?.bookmarks.toggle(note)
            },
            rename: { beginRename($0) },
            duplicate: { duplicate($0) },
            openInNewWindow: { openNoteWindow($0) },
            delete: { delete($0) },
            isOpenInEditor: { isOpenInEditor($0) },
            reviewLinks: { _ in reviewLinks() },
            text: { text(of: $0) },
            newNote: { createNote(in: $0, folderID: $1) },
            newFolder: { beginNewFolder(in: $0, folderID: $1) },
            deleteFolder: { folderID in
                // Trashing a folder trashes everything inside it — confirm first.
                pendingFolderDelete.wrappedValue =
                    URL(fileURLWithPath: folderID, isDirectory: true)
            },
            focusCollection: { library.focus($0) },
            closeCollection: { closeCollection($0) },
            expandFolder: { expand($0) })
    }
}

/// Sidebar folder expansion, persisted.
///
/// It was `@SceneStorage` on iPad and plain `@State` on the Mac, so reopening
/// the app restored your open folders on one platform and collapsed the whole
/// tree on the other. Per-scene, not `UserDefaults`: two Mac windows are two
/// scenes and may reasonably be looking at different parts of the tree.
enum ExpandedFolders {
    static func binding(_ stored: Binding<String>) -> Binding<Set<String>> {
        Binding(
            get: { Set(stored.wrappedValue.split(separator: "\n").map(String.init)) },
            set: { stored.wrappedValue = $0.sorted().joined(separator: "\n") })
    }
}
