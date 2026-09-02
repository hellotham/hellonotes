//
//  SidebarMenu.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  What right-clicking (or long-pressing) a sidebar row offers — decided once,
//  built twice.
//
//  `NoteOutlineList` was already one API over two widgets, but its two branches
//  took *disjoint* parameter sets: the AppKit branch assembled its own `NSMenu`
//  inside the coordinator, and the SwiftUI branch asked the shell for a
//  `@ViewBuilder`. Each declared the other's parameters with defaults, so both
//  compiled while neither ran the other's code. Two command lists for one
//  control, which had drifted exactly as far as that arrangement allows:
//
//    · a note on the Mac had no Review Links and no Export ▸ HTML/PDF/Print
//    · a collection on the Mac had no Show Non-Note Files, no Rescan and no
//      Refresh Cloud Collection
//    · a collection on iPad had no Reveal, and neither did a folder
//    · an attachment on iPad had no menu at all — not Open, not Reveal
//    · the Mac said "New Folder" where iPad said "New Folder…", for the same
//      command, which prompts
//
//  None of those is a platform difference. They are the difference between two
//  people writing the same list twice.
//
//  So the list moves here as data — title, symbol, destructiveness, action —
//  and each widget renders it in its own idiom. An `NSMenu` and a SwiftUI
//  `Menu` are genuinely different objects; *which items are in them* is not.
//

import Foundation
import SwiftUI

@MainActor
enum SidebarMenu {

    /// One entry. A separator is an item with no title and no action, so a menu
    /// is a flat array and the two renderers walk it the same way.
    struct Item: Identifiable {
        let id: Int
        var title: String = ""
        var symbol: String = ""
        var destructive: Bool = false
        /// A submenu (Export ▸). `nil` for a leaf.
        var children: [Item]? = nil
        var run: (() -> Void)? = nil

        var isSeparator: Bool { title.isEmpty && children == nil }
    }

    /// Everything a menu item needs to *do*, supplied by the shell that owns
    /// the selection, the editor and the library.
    ///
    /// Closures rather than a reference to the shell: a modifier holding the
    /// host struct would be looking at a copy of its state.
    struct Actions {
        var isBookmarked: (Note) -> Bool = { _ in false }
        var toggleBookmark: (Note) -> Void = { _ in }
        var rename: (Note) -> Void = { _ in }
        var duplicate: (Note) -> Void = { _ in }
        var openInNewWindow: (Note) -> Void = { _ in }
        var delete: (Note) -> Void = { _ in }
        /// Whether this note is the one the editor has open. Review Links reads
        /// the live buffer and its proposals are offsets into *that* text, so
        /// running it against another note would apply ranges to the wrong
        /// document.
        var isOpenInEditor: (Note) -> Bool = { _ in false }
        var reviewLinks: (Note) -> Void = { _ in }
        /// Export or print the note. Prefers the editor's buffer when it is
        /// open — exporting the file while the editor holds unsaved edits
        /// exports the wrong thing — and downloads a cloud note that is not.
        var export: (Note, ShellActions.ExportKind) -> Void = { _, _ in }

        /// Fetch a note that is not on this device, whether it is a
        /// File-Provider placeholder or a direct-API mirror entry.
        var download: (Note) -> Void = { _ in }
        /// Give back the space a downloaded note is using.
        var removeDownload: (Note) -> Void = { _ in }

        var newNote: (Collection?, String?) -> Void = { _, _ in }
        var newFolder: (Collection?, String?) -> Void = { _, _ in }
        var deleteFolder: (String) -> Void = { _ in }
        var focusCollection: (Collection) -> Void = { _ in }
        var closeCollection: (Collection) -> Void = { _ in }
        /// Called before creating inside a folder, so the new item is not
        /// created into a folder that is closed — a selection you cannot see.
        var expandFolder: (String) -> Void = { _ in }
    }

    /// The menu for one sidebar row.
    static func items(for item: NoteOutlineItem, actions: Actions) -> [Item] {
        var ids = 0
        func next() -> Int { ids += 1; return ids }
        func separator() -> Item { Item(id: next()) }
        func entry(_ title: String, _ symbol: String,
                   destructive: Bool = false,
                   run: @escaping () -> Void) -> Item {
            Item(id: next(), title: title, symbol: symbol,
                 destructive: destructive, run: run)
        }

        if let note = item.note {
            var menu: [Item] = [
                entry("Rename…", "pencil") { actions.rename(note) },
                entry("Duplicate", "plus.square.on.square") { actions.duplicate(note) },
                entry(actions.isBookmarked(note) ? "Remove Bookmark" : "Add Bookmark",
                      actions.isBookmarked(note) ? "bookmark.slash" : "bookmark") {
                    actions.toggleBookmark(note)
                },
                separator(),
                entry("Copy Wiki Link", "link") { Clipboard.copy(note.wikiLink) },
                entry("Open in New Window", "macwindow") { actions.openInNewWindow(note) },
            ]
            // Unconditional, deliberately. `canReveal` is
            // `FileManager.fileExists(atPath:)` — a **syscall**, and this
            // function is called from `SidebarItemRow`'s body, so it ran once
            // per visible row every time the sidebar rebuilt. While typing,
            // that is a stat storm behind the editor. The note came from a
            // scan, so it existed a moment ago; and `FileReveal.reveal` checks
            // again before acting, which is where a check costs nothing because
            // a person just asked for it.
            menu.append(entry(FileReveal.revealTitle, "folder") {
                FileReveal.reveal(note.fileURL)
            })
            // Cloud (File Provider) download controls, only for notes that live
            // in a cloud folder.
            // `isOnlineOnly` implies cloud-backed, so the `||` only ever
            // mattered for a *downloaded* cloud file — which is the one case
            // that still needs asking.
            if note.isOnlineOnly || isCloudBacked(note.fileURL) {
                menu.append(separator())
                if note.isOnlineOnly {
                    menu.append(entry("Download", "arrow.down.circle") {
                        actions.download(note)
                    })
                } else {
                    menu.append(entry("Remove Download", "icloud.slash") {
                        actions.removeDownload(note)
                    })
                }
            }
            if actions.isOpenInEditor(note) {
                menu.append(separator())
                menu.append(entry("Review Links…", "link.badge.plus") {
                    actions.reviewLinks(note)
                })
            }
            menu.append(separator())
            menu.append(Item(id: next(), title: "Export", symbol: "square.and.arrow.up",
                             children: [
                                Item(id: next(), title: "Export as HTML…", symbol: "doc.richtext",
                                     run: { actions.export(note, .html) }),
                                Item(id: next(), title: "Export as PDF…", symbol: "doc.text",
                                     run: { actions.export(note, .pdf) }),
                                Item(id: next(), title: "Print…", symbol: "printer",
                                     run: { actions.export(note, .print) }),
                             ]))
            menu.append(separator())
            menu.append(entry("Move to Trash", "trash", destructive: true) {
                actions.delete(note)
            })
            return menu
        }

        if let file = item.file {
            var menu = [entry(FileReveal.openInDefaultAppTitle, "arrow.up.forward.app") {
                FileReveal.openInDefaultApp(file.url)
            }]
            if FileReveal.canReveal(file.url) {
                menu.append(entry(FileReveal.revealTitle, "folder") {
                    FileReveal.reveal(file.url)
                })
            }
            return menu
        }

        if let collection = item.collection {
            var menu: [Item] = [
                // The contract's one exception to "no command in the sidebar"
                // is an action whose entire subject *is* the sidebar's content,
                // and New Note / New Folder at a named root is exactly that —
                // it is also the only way to aim either at a particular
                // collection when several are open.
                entry("New Note", "square.and.pencil") { actions.newNote(collection, nil) },
                entry("New Folder…", "folder.badge.plus") { actions.newFolder(collection, nil) },
                separator(),
                entry(collection.showsNonNoteFiles ? "Hide Non-Note Files" : "Show Non-Note Files",
                      collection.showsNonNoteFiles ? "eye.slash" : "eye") {
                    collection.showsNonNoteFiles.toggle()
                },
                entry("Rescan Collection", "arrow.clockwise") { collection.rescan() },
            ]
            if collection.isRemote {
                menu.append(entry("Refresh Cloud Collection", "cloud") {
                    Task { await collection.refreshFromProvider() }
                })
            }
            menu.append(separator())
            menu.append(entry("Focus Collection", "scope") { actions.focusCollection(collection) })
            if FileReveal.canReveal(collection.rootURL) {
                menu.append(entry(FileReveal.revealTitle, "folder") {
                    FileReveal.reveal(collection.rootURL)
                })
            }
            menu.append(entry("Close Collection", "xmark.circle") {
                actions.closeCollection(collection)
            })
            return menu
        }

        if case .folder = item.kind {
            // The item id *is* the folder's absolute path, which is also the
            // key the expansion set uses — so opening the folder needs no node.
            let folderID = item.id
            let url = URL(fileURLWithPath: folderID, isDirectory: true)
            var menu: [Item] = [
                entry("New Note Here", "square.and.pencil") {
                    actions.expandFolder(folderID)
                    actions.newNote(nil, folderID)
                },
                entry("New Folder Here…", "folder.badge.plus") {
                    actions.expandFolder(folderID)
                    actions.newFolder(nil, folderID)
                },
            ]
            if FileReveal.canReveal(url) {
                menu.append(separator())
                menu.append(entry(FileReveal.revealTitle, "folder") { FileReveal.reveal(url) })
            }
            menu.append(separator())
            menu.append(entry("Move to Trash", "trash", destructive: true) {
                actions.deleteFolder(folderID)
            })
            return menu
        }

        // A pinned place owns no folder on disk, so there is nothing to do to it.
        return []
    }

    /// The menu for empty space below the rows, where the click names no node.
    /// Offered only when the whole outline belongs to one collection, because
    /// otherwise "New Note" has no answer to "in which".
    static func emptySpace(in collection: Collection?, actions: Actions) -> [Item] {
        guard let collection else { return [] }
        return [
            Item(id: 1, title: "New Note", symbol: "square.and.pencil",
                 run: { actions.newNote(collection, nil) }),
            Item(id: 2, title: "New Folder…", symbol: "folder.badge.plus",
                 run: { actions.newFolder(collection, nil) }),
        ]
    }

    /// Whether a file lives in a File Provider (iCloud Drive, Dropbox, …), and
    /// so has download controls at all.
    /// Whether `url` lives in a cloud (File Provider) folder.
    ///
    /// **Memoised per directory, because this is called from a view body.**
    /// `resourceValues(forKeys:)` is a syscall — and on a File Provider URL it
    /// can be a round trip to the provider — and `SidebarMenu.items(for:)` runs
    /// once per visible row every time the sidebar rebuilds. Measured on an
    /// iPad, it appeared on the main thread *while typing*, inside
    /// `SidebarItemRow.content`.
    ///
    /// Cloud-ness is a property of the folder, not the file: every note in a
    /// cloud folder is cloud-backed and no note in a local one is. So the cache
    /// is keyed on the parent directory, which turns one syscall per row per
    /// rebuild into one syscall per folder per launch. It is never invalidated
    /// because a directory does not move in and out of a File Provider domain
    /// while the app is running; if one somehow did, the cost is a menu item
    /// that is wrongly present or absent until relaunch.
    private static var cloudBackedCache: [String: Bool] = [:]

    private static func isCloudBacked(_ url: URL) -> Bool {
        let directory = url.deletingLastPathComponent().path
        if let known = cloudBackedCache[directory] { return known }
        let value = (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?
            .isUbiquitousItem == true
        cloudBackedCache[directory] = value
        return value
    }
}

/// One `SidebarMenu.Item` list, as SwiftUI buttons. The Mac walks the same
/// array into an `NSMenu`; this is the only other renderer.
///
/// It lived inside `NoteOutlineList.swift`'s `#else` half, which made it
/// iOS-only for no reason of its own — there is nothing platform-shaped in it.
/// The tall shell is chosen by the *axis of abundance*, so a narrow, tall Mac
/// window gets the two-pane band too, and `BandTwoPane` could not compile there
/// while this was on one side of a platform gate. It belongs beside the menu
/// model it renders.
struct SidebarMenuItems: View {
    let items: [SidebarMenu.Item]
    var body: some View {
        ForEach(items) { item in
            if item.isSeparator {
                Divider()
            } else if let children = item.children {
                Menu {
                    SidebarMenuItems(items: children)
                } label: {
                    Label(item.title, systemImage: item.symbol)
                }
            } else {
                Button(role: item.destructive ? .destructive : nil) {
                    item.run?()
                } label: {
                    Label(item.title, systemImage: item.symbol)
                }
            }
        }
    }
}
