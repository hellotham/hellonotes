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

    /// The note with a conflict still to be chosen that stops a rename or a
    /// move of `url` — that note, or one inside that folder — if there is one.
    /// The flush before a rename or a move cannot write a conflicted buffer,
    /// so its tab would keep the old path, and Keep Mine would later write
    /// mine there: the ghost file the flush exists to prevent.
    private func conflictBlocking(_ url: URL) -> Note? {
        let path = url.standardizedFileURL.path
        return tabs.editors.first { editor in
            guard editor.hasConflict, let open = editor.note?.fileURL.standardizedFileURL.path else { return false }
            return open == path || open.hasPrefix(path + "/")
        }?.note
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
        if let blocked = conflictBlocking(note.fileURL) {
            collection.report("“\(blocked.title)” changed on disk while you were editing it. Choose Keep Mine or Reload before renaming it.")
            return
        }
        Task {
            await tabs.flushAll(lettingGo: false)
            // Its tab follows it where it is (`EditorModel.itemMoved`), and
            // the window shows it only if it was showing it: a rename made the
            // renamed note the active one, whichever it had been.
            let wasSelected = selection.wrappedValue == note.id
            if let renamed = await collection.renameNote(note, to: title), wasSelected {
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
    ///
    /// - Returns: `nil` when the text is not available, rather than `""`.
    ///   Every caller of this is an export, and an export that quietly
    ///   substitutes an empty document writes a blank PDF named after the note
    ///   and tells the user nothing. Two ways that happened: a coordinated read
    ///   that threw (a dataless File Provider note while offline), and a
    ///   direct-API mirror note that has not been downloaded — those are real
    ///   zero-byte placeholders on disk, so the read *succeeded* and returned
    ///   nothing at all.
    func text(of note: Note) -> String? {
        if let editor = tabs.editor(withID: note.id), editor.note?.fileURL == note.fileURL {
            return editor.text
        }
        guard let text = try? FileIO.readString(at: note.fileURL) else { return nil }
        // A zero-byte file for a note the collection knows is online-only is a
        // placeholder, not an empty note.
        if text.isEmpty && note.isOnlineOnly { return nil }
        return text
    }

    /// The note's text, downloading it first if the collection keeps it in a
    /// remote mirror.
    ///
    /// The synchronous `text(of:)` cannot do this — hydration is async — which
    /// is why exporting a cloud note that was never opened used to produce an
    /// empty document. `hydrateIfNeeded` is cheap and safe for local
    /// collections and for anything already downloaded.
    func exportText(of note: Note) async -> String? {
        if let editor = tabs.editor(withID: note.id), editor.note?.fileURL == note.fileURL {
            return editor.text
        }
        await library.collection(containing: note.fileURL)?.hydrateIfNeeded(note.fileURL)
        return text(of: note)
    }

    /// Fetch a note that is not on this device.
    ///
    /// Routed through the collection because only it knows whether the note is
    /// a File-Provider placeholder or an entry in a direct-API mirror, and the
    /// two need different calls. Going straight to `FileIO.download` — which is
    /// `startDownloadingUbiquitousItem` — silently did nothing for the second.
    func download(_ note: Note) {
        guard let collection = library.collection(containing: note.fileURL) else { return }
        Task { await collection.download(note.fileURL) }
    }

    /// Which rendering of a note an export produces.
    enum ExportKind { case html, pdf, print }

    /// Export or print `note`, downloading it first if need be, and say so when
    /// there is nothing to export.
    ///
    /// One place, because the three-way `exportHTML` / `exportPDF` / `printNote`
    /// fan-out was written out twice — in the sidebar's menu and in the note
    /// menu — and both handed `EditorExport` whatever `text(of:)` returned
    /// without looking at it.
    func export(_ note: Note, as kind: ExportKind) {
        Task {
            guard let markdown = await exportText(of: note), !markdown.isEmpty else {
                library.collection(containing: note.fileURL)?
                    .report("Couldn't read “\(note.title)” to export it.")
                return
            }
            switch kind {
            case .html: EditorExport.exportHTML(markdown: markdown, title: note.title)
            case .pdf: EditorExport.exportPDF(markdown: markdown, title: note.title)
            case .print: EditorExport.printNote(markdown: markdown, title: note.title)
            }
        }
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
            editor.applyEdit { $0 + ($0.isEmpty ? "" : "\n") + expanded }
        }
    }

    /// Re-check the selection after the note set changed underneath it.
    ///
    /// **Deliberately conservative, and this is the point of it.** A selection
    /// that still resolves is left exactly as it is, and one that no longer
    /// resolves is *kept* rather than cleared: clearing it would close the note
    /// someone is reading on the strength of a scan, which is the rule the
    /// architecture states outright — no other operation may close the current
    /// file. Only the editor's content is refreshed.
    ///
    /// The two shells had this under one name and it was two different
    /// functions. The Mac's cleared a selection that no longer resolved and
    /// fell back to the last open tab — so a rescan that momentarily dropped a
    /// note took the reader off it, which is the vanished-note report. The
    /// iPad's kept the selection and reconciled the buffer, and carried the
    /// paragraph explaining why. One name, opposite behaviours, and each
    /// platform was missing what the other did.
    func revalidateSelection() {
        Self.revalidate(selection, in: library, tabs: tabs)
    }

    /// `revalidateSelection`, from its parts — for a window's change handler,
    /// which must not hold the window (`ContentView.observeExternalChanges`).
    /// The note is looked up, not searched for: this runs for every open window
    /// at every change on disk.
    static func revalidate(_ selection: Binding<Note.ID?>, in library: Library, tabs: EditorTabs) {
        guard let id = selection.wrappedValue, library.note(id: id) != nil else { return }
        Task { await tabs.editor(withID: id)?.reconcileWithDisk() }
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

    /// The folder New Note goes into — the one you are looking at. While the
    /// band is on screen, the container it shows; in a column, whose sidebar
    /// selects notes and never folders (a folder row only opens and closes),
    /// the selected note's folder. Either only when it is a folder of an open
    /// collection — otherwise none, which is the collection's root.
    ///
    /// The container outlived the band: a window that was once tall — an iPad
    /// rotated, a Mac window resized — kept the folder last chosen there, and
    /// New Note in its column landed in that folder; and with Recents chosen,
    /// which is a place and not a folder, it was written into the open
    /// folders, so the tree showed Recents open (primary.md §12, item 14;
    /// implemented.md §51.36). And a column had no folder at all: New Note on
    /// the Mac went to the root from a note three folders down (§51.37).
    nonisolated static func newNoteFolder(band containerID: String?, bandShowing: Bool,
                              selected: URL?, collectionIDs: [String]) -> String? {
        let folder = bandShowing ? containerID : selected?.deletingLastPathComponent().path
        guard let folder,
              collectionIDs.contains(where: { folder == $0 || folder.hasPrefix($0 + "/") })
        else { return nil }
        return folder
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

    /// Close a collection — **every route**: the row's menu, the unavailable
    /// collection's Remove, the Cloud Collections manager. Two of them called
    /// `library.close` themselves, and so kept a selected note's tab, unsaved
    /// changes and all, showing a note in a collection no longer open
    /// (tabs.md §2.5, item 15; implemented.md §51.36).
    func closeCollection(_ collection: Collection) {
        // Clear a selection that lives in the collection being closed, or the
        // editor keeps showing a note from a library that is no longer open.
        if let selected = selection.wrappedValue,
           library.collection(containing: selected)?.id == collection.id {
            selection.wrappedValue = nil
        }
        // What its tabs hold is written before the folder is given up:
        // closing gives up its security scope, and a save after that fails.
        let holding = tabs.editors.filter { editor in
            editor.note.map { library.collection(containing: $0.fileURL)?.id == collection.id } ?? false
        }
        guard !holding.isEmpty else { return library.close(collection) }
        Task {
            for editor in holding { await editor.flush() }
            library.close(collection)
        }
    }

    /// Move dropped items into a folder. Plural because a drop can carry
    /// several.
    @discardableResult
    func move(_ urls: [URL], intoFolderWithID folderID: String) -> Bool {
        guard let collection = collection(forFolderID: folderID) else { return false }
        let folder = URL(fileURLWithPath: folderID, isDirectory: true)
        let sources = urls.filter { library.collection(containing: $0)?.id == collection.id }
        guard !sources.isEmpty else { return false }
        if let blocked = sources.lazy.compactMap(conflictBlocking).first {
            collection.report("“\(blocked.title)” changed on disk while you were editing it. Choose Keep Mine or Reload before moving it.")
            return false
        }
        Task {
            await tabs.flushAll(lettingGo: false)
            for source in sources {
                let selected = selection.wrappedValue
                guard let destination = await collection.moveItem(at: source, into: folder),
                      let selected else { continue }
                // The note shown, moved — itself, or with the folder it is in.
                let from = source.standardizedFileURL.path
                let path = selected.standardizedFileURL.path
                if path == from {
                    selection.wrappedValue = destination
                } else if path.hasPrefix(from + "/") {
                    selection.wrappedValue = URL(fileURLWithPath: destination.standardizedFileURL.path
                                                 + path.dropFirst(from.count))
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
            export: { note, kind in export(note, as: kind) },
            download: { note in download(note) },
            removeDownload: { note in try? FileIO.evict(at: note.fileURL) },
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
