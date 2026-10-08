//
//  NoteOutlineList.swift
//  HelloNotes
//
//  Created by Chris Tham on 13/7/2026.
//
//  The sidebar tree — collections, their folders, notes and attachments, and
//  the pinned places — **one implementation, drawn by the app**.
//
//  It was two. The Mac's was an `NSOutlineView` (700 lines of AppKit cells and
//  a custom row view), kept because "SwiftUI's List forces the system-blue
//  highlight"; the iPad's was a SwiftUI `List` of `DisclosureGroup`s. Two
//  drawing engines are two pictures: a different disclosure triangle, row
//  inset, font, selection colour and row height on each — so the Mac and the
//  iPad could never look the same whatever either side was told.
//
//  This draws the `NSOutlineView`'s own look — its fonts, row heights, 14pt
//  indent and accent-at-30% selection — as flat rows in a `LazyVStack`
//  (`ChromeRows`), and keeps what the outline gave for free: disclosure,
//  selection of notes and attachments, dragging a note out, dropping one onto
//  a folder or collection (same collection only, never a no-op, as before),
//  the arrow keys, and scrolling a newly added collection into view.
//

import SwiftUI

struct NoteOutlineList: View {
    var roots: [NoteOutlineItem]
    /// Kept so the call site is one call site. The AppKit outline reloaded on
    /// it; a SwiftUI list follows its data on its own.
    var signature: String
    @Binding var selection: URL?
    /// An item to open to and scroll into view, without touching the note
    /// selection — a collection just added is appended last, below the fold.
    /// Cleared once applied.
    @Binding var revealID: String?
    /// Open places and folders, shared with the rest of the shell so the state
    /// survives rebuilds.
    @Binding var expandedFolders: Set<String>
    /// Collections folded away. A *collapsed* set, so a collection just opened
    /// starts open.
    @Binding var collapsedCollections: Set<Collection.ID>
    var focusedCollectionID: Collection.ID?
    var accent: Color
    /// The app's Text Size, applied to the rows' fonts and heights — on both
    /// platforms now; the iOS list used to ignore it.
    var fontScale: CGFloat = 1
    /// The collection a tag filter's bare note rows belong to — which a drop
    /// on one of those rows is checked against. `nil` when every note hangs
    /// under its collection.
    var scopedCollectionID: Collection.ID? = nil

    /// What the shell's commands do. Which commands there are is `SidebarMenu`.
    var actions: SidebarMenu.Actions = SidebarMenu.Actions()
    /// The collection the empty space below the rows offers commands for.
    var scopedCollection: Collection? = nil
    var onCloseCollection: (Collection) -> Void = { _ in }
    /// A note's row. The shell supplies it: what a row says is
    /// `NoteRowContent`, and what it does — drag — is the shell's.
    var row: (Note, String?) -> AnyView = { _, _ in AnyView(EmptyView()) }
    /// Move every URL into the folder whose absolute path is the item id.
    var onDropIntoFolder: (String, [URL]) -> Bool = { _, _ in false }

    @FocusState private var hasKeyboardFocus: Bool

    private var lines: [ChromeTreeLine] {
        ChromeTree.lines(roots, expanded: expandedFolders, collapsed: collapsedCollections)
    }

    var body: some View {
        let lines = self.lines
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(lines) { line in
                        self.line(line)
                    }
                    // The empty space below the rows: its own menu. It takes
                    // no drops.
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .contentShape(.rect)
                        .contextMenu {
                            SidebarMenuItems(items: SidebarMenu.emptySpace(in: scopedCollection,
                                                                            actions: actions))
                        }
                }
                .padding(.vertical, 4)
            }
            .viewport()
            .scrollIndicators(.automatic)
            .background(Chrome.Colour.chrome)
            .environment(\.chromeScale, fontScale)
            .focusable()
            .focused($hasKeyboardFocus)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(by: 1, in: lines, proxy: proxy); return .handled }
            .onKeyPress(.upArrow) { move(by: -1, in: lines, proxy: proxy); return .handled }
            .onChange(of: revealID) { _, id in
                guard let id else { return }
                reveal(id, with: proxy)
            }
            .onAppear { if let id = revealID { reveal(id, with: proxy) } }
        }
    }

    // MARK: - A row

    @ViewBuilder
    private func line(_ line: ChromeTreeLine) -> some View {
        let item = line.item
        // Once: a folder's menu stats the disk, and two menus read it.
        let items = SidebarMenu.items(for: item, actions: actions)
        let isSelected = item.url != nil && item.url == selection
        ChromeRowFrame(height: ChromeTree.height(item, scale: fontScale),
                       depth: line.depth, isSelected: isSelected, accent: accent) {
            ChromeDisclosure(isExpandable: line.isExpandable, isExpanded: line.isExpanded) {
                toggle(line)
            }
            content(item)
            Spacer(minLength: 4)
            if item.collection != nil || isFolder(item) {
                RowActionsMenu(name: name(of: item), items: items)
            }
        }
        .id(item.id)
        .onTapGesture { activate(line) }
        .contextMenu { SidebarMenuItems(items: items) }
        .modifier(DropIntoFolder(target: dropTarget(for: item), onDrop: onDropIntoFolder))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private func content(_ item: NoteOutlineItem) -> some View {
        switch item.kind {
        case .collection(let collection):
            ChromeCollectionRow(content: CollectionRowContent.make(collection,
                                                                  focusedID: focusedCollectionID))
        case .place(let title, let symbol):
            ChromeLabelRow(systemImage: symbol, title: title, titleSize: 11,
                           titleColour: Chrome.Colour.secondaryLabel)
        case .folder(let name):
            ChromeLabelRow(systemImage: "folder", title: name)
        case .note(let note, let snippet):
            row(note, snippet)
        case .file(let file):
            ChromeLabelRow(systemImage: file.kind.symbol, title: file.name)
                .draggable(file.url)
        }
    }

    // MARK: - Acting on a row

    /// A note or an attachment is selected; anything that holds rows opens or
    /// closes — the whole row, not just its triangle.
    private func activate(_ line: ChromeTreeLine) {
        hasKeyboardFocus = true
        if let url = line.item.url {
            if selection != url { selection = url }
        } else if line.isExpandable {
            toggle(line)
        }
    }

    private func toggle(_ line: ChromeTreeLine) {
        let id = line.item.id
        withAnimation(.easeInOut(duration: 0.15)) {
            if case .collection = line.item.kind {
                if collapsedCollections.contains(id) { collapsedCollections.remove(id) }
                else { collapsedCollections.insert(id) }
            } else {
                if expandedFolders.contains(id) { expandedFolders.remove(id) }
                else { expandedFolders.insert(id) }
            }
        }
    }

    /// The arrow keys, over the rows that can be selected.
    private func move(by step: Int, in lines: [ChromeTreeLine], proxy: ScrollViewProxy) {
        let selectable = lines.filter { $0.item.url != nil }
        guard !selectable.isEmpty else { return }
        let current = selectable.firstIndex { $0.item.url == selection }
        let next: Int
        if let current {
            next = min(max(current + step, 0), selectable.count - 1)
        } else {
            next = step > 0 ? 0 : selectable.count - 1
        }
        let target = selectable[next]
        selection = target.item.url
        proxy.scrollTo(target.id)
    }

    /// Open whatever hides `id`, then scroll to it. Folder ids are absolute
    /// paths, so an ancestor is a path prefix.
    private func reveal(_ id: String, with proxy: ScrollViewProxy) {
        collapsedCollections.remove(id)
        for root in roots where id.hasPrefix(root.id) {
            collapsedCollections.remove(root.id)
        }
        if id.contains("/") {
            var path = id
            while let slash = path.lastIndex(of: "/") {
                path = String(path[path.startIndex..<slash])
                expandedFolders.insert(path)
            }
        }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(id, anchor: .center) }
            revealID = nil
        }
    }

    // MARK: - Drops

    /// The folder a drop on `item` means: a folder is itself the target (its
    /// id is its absolute path); a collection means its root. Anything else
    /// is not a drop target.
    private func dropTarget(for item: NoteOutlineItem) -> DropTarget? {
        if let collection = item.collection {
            return DropTarget(folderURL: collection.rootURL, collectionID: collection.id)
        }
        if isFolder(item), let root = owningCollectionID(of: item.id) {
            return DropTarget(folderURL: URL(fileURLWithPath: item.id, isDirectory: true),
                              collectionID: root)
        }
        return nil
    }

    private func owningCollectionID(of id: String) -> String? {
        var found: String?
        func walk(_ items: [NoteOutlineItem]) {
            for item in items where found == nil {
                if let c = item.collection, id == c.id || id.hasPrefix(c.id + "/") {
                    found = c.id
                    return
                }
                walk(item.children.filter { $0.isGroup })
            }
        }
        walk(roots)
        return found ?? scopedCollectionID.flatMap { id.hasPrefix($0) ? $0 : nil }
    }

    private func isFolder(_ item: NoteOutlineItem) -> Bool {
        if case .folder = item.kind { return true }
        return false
    }

    private func name(of item: NoteOutlineItem) -> String {
        switch item.kind {
        case .collection(let c): return c.name
        case .folder(let name): return name
        case .place(let title, _): return title
        case .note(let note, _): return note.title
        case .file(let file): return file.name
        }
    }
}

/// Where a drop on a row goes.
struct DropTarget: Equatable {
    let folderURL: URL
    let collectionID: String

    /// The Mac outline's rule: the same collection only, and never a move to
    /// where the file already is.
    func accepts(_ source: URL) -> Bool {
        let folder = folderURL.standardizedFileURL
        return folder.path.hasPrefix(collectionID)
            && source.standardizedFileURL.path.hasPrefix(collectionID)
            && source.deletingLastPathComponent().standardizedFileURL != folder
    }
}

/// A row that takes dropped notes, or declines before it lights up — the
/// refusal is `isEnabled`, never a `false` returned from the action (see
/// AGENTS.md on `dropDestination`).
private struct DropIntoFolder: ViewModifier {
    let target: DropTarget?
    let onDrop: (String, [URL]) -> Bool

    func body(content: Content) -> some View {
        content.dropDestination(for: URL.self, isEnabled: target != nil) { urls, _ in
            guard let target else { return }
            let accepted = urls.filter(target.accepts)
            if !accepted.isEmpty { _ = onDrop(target.folderURL.path, accepted) }
        }
    }
}
