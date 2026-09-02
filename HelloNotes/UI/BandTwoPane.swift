//
//  BandTwoPane.swift
//  HelloNotes
//
//  The tall shell's navigation band, as two panes: where you are on the left,
//  what is there on the right (`docs/shell-chrome.md` D2a).
//
//  ## Why the band, and only the band
//
//  D2 says the sidebar is a *single tree* — Recents and Bookmarks pinned above
//  one root per open collection — and in a sidebar **column** that is still
//  right. A column is 220–340pt (`ShellMetrics.sidebarCap`): there is room for
//  one list and no more, and splitting it is what produced the rail-plus-tree
//  shape whose sidebar toggle could never be placed (`ShellMetrics.sidebarIdeal`
//  records that in full).
//
//  The band is a different shape and the argument does not carry. On an iPad in
//  portrait it is 834pt wide and 320pt tall — very wide, very short — so one
//  tree in it spends its width on nothing and runs out of height immediately: a
//  row for a collection, a row for each folder, then the notes, all in a list
//  eight rows deep. Two panes scroll independently, so the same 320pt shows the
//  folders *and* the notes at once.
//
//  Crucially the structural objection does not apply here either. The band is a
//  `NavigationStack` inside a `VStack` (`AdaptiveShell.tallShell`), not column
//  one of a `NavigationSplitView`, so there is no platform-placed sidebar toggle
//  to lose by putting two things side by side.
//
//  ## One tree, seen twice
//
//  Both panes come from `SidebarTree.roots` — the left through
//  `SidebarTree.containers`, the right through `SidebarTree.leaves(of:)`. They
//  are not two constructions that have to be kept in agreement; a collection
//  that is in one and not the other is not a reachable state.
//

import SwiftUI

struct BandTwoPane: View {

    @Environment(\.shell) private var shell

    var roots: [NoteOutlineItem]
    /// The container whose contents the right pane shows.
    @Binding var containerID: String?
    /// The open note — the right pane's selection, and the shell's.
    @Binding var selection: URL?
    @Binding var expandedFolders: Set<String>
    @Binding var collapsedCollections: Set<Collection.ID>
    /// Which collection the rest of the window is acting on — the semibold row.
    /// Threaded rather than defaulted because `CollectionRowContent` also
    /// carries the unreadable-folder warning, and a collection that cannot be
    /// read has to *look* unreadable: it keeps its notes listed, so without the
    /// warning a stale list reads as a current one.
    var focusedCollectionID: Collection.ID?
    var accent: Color
    var actions: SidebarMenu.Actions = SidebarMenu.Actions()
    var onCloseCollection: (Collection) -> Void = { _ in }
    /// What a note row says — the shell's, exactly as the one-tree sidebar
    /// gets it, so the band cannot grow a row of its own.
    var row: (Note, String?) -> AnyView
    var onDropIntoFolder: (String, [URL]) -> Bool

    /// The band is short, so a row is the unit that matters. A finger needs
    /// 44pt; a pointer does not, and on a Mac that difference is nearly half
    /// the rows the band can show.
    private var rowHeight: CGFloat {
        shell.prefersTouch ? ShellMetrics.noteRowTouchMinimum
                           : ShellMetrics.noteRowPointerMinimum
    }

    private var containers: [NoteOutlineItem] { SidebarTree.containers(roots) }
    private var selectedContainer: NoteOutlineItem? {
        containerID.flatMap { SidebarTree.node(id: $0, in: roots) }
    }

    var body: some View {
        HStack(spacing: 0) {
            ContainerPane(
                nodes: containers,
                rowHeight: rowHeight,
                selection: $containerID,
                expandedFolders: $expandedFolders,
                collapsedCollections: $collapsedCollections,
                focusedCollectionID: focusedCollectionID,
                actions: actions,
                onCloseCollection: onCloseCollection,
                onDropIntoFolder: onDropIntoFolder)
                .frame(width: ShellMetrics.bandContainerPane)

            Divider()

            ContentsPane(
                container: selectedContainer,
                rowHeight: rowHeight,
                selection: $selection,
                actions: actions,
                row: row)
                .frame(maxWidth: .infinity)
        }
        .tint(accent)
        // Opening the app onto an empty right pane reads as an empty library,
        // so a container is chosen before one is clicked.
        .task(id: roots.map(\.id).joined()) {
            if containerID == nil || SidebarTree.node(id: containerID!, in: roots) == nil {
                containerID = SidebarTree.firstNonEmptyContainer(in: roots)
            }
        }
    }
}

// MARK: - Left: where you are

private struct ContainerPane: View {
    var nodes: [NoteOutlineItem]
    var rowHeight: CGFloat
    @Binding var selection: String?
    @Binding var expandedFolders: Set<String>
    @Binding var collapsedCollections: Set<Collection.ID>
    var focusedCollectionID: Collection.ID?
    var actions: SidebarMenu.Actions
    var onCloseCollection: (Collection) -> Void
    var onDropIntoFolder: (String, [URL]) -> Bool

    var body: some View {
        List(selection: $selection) {
            ForEach(nodes, id: \.id) { node in
                ContainerRow(node: node, depth: 0, selection: $selection,
                             expandedFolders: $expandedFolders,
                             collapsedCollections: $collapsedCollections,
                             focusedCollectionID: focusedCollectionID,
                             actions: actions,
                             onCloseCollection: onCloseCollection,
                             onDropIntoFolder: onDropIntoFolder)
            }
        }
        .environment(\.defaultMinListRowHeight, rowHeight)
        // The container pane carries names and nothing else — no dates, no
        // snippets — so it does not need body size to be legible, and every
        // point it gives back is a point of list.
        .font(.subheadline)
    }
}

private struct ContainerRow: View {
    let node: NoteOutlineItem
    /// How deep this row sits, so the row can state its own indent.
    ///
    /// The List's default insets are what put the pane 4pt over the 44pt touch
    /// floor — the height is `max(floor, content + insets)`, and the insets were
    /// the part nobody had chosen. Taking them means taking the *indent* too,
    /// because that is the leading inset: hence a depth rather than a constant.
    /// SwiftUI's own step is around 28pt, which in a 260pt pane is a quarter of
    /// the name gone by the second level.
    let depth: Int
    @Binding var selection: String?
    @Binding var expandedFolders: Set<String>
    @Binding var collapsedCollections: Set<Collection.ID>
    var focusedCollectionID: Collection.ID?
    var actions: SidebarMenu.Actions
    var onCloseCollection: (Collection) -> Void
    var onDropIntoFolder: (String, [URL]) -> Bool

    /// Per level. Enough to read as nesting, and no more.
    private static let indent: CGFloat = 14

    private var subContainers: [NoteOutlineItem] {
        node.children.filter { child in
            switch child.kind {
            case .collection, .place, .folder: return true
            case .note, .file: return false
            }
        }
    }

    var body: some View {
        Group {
            if subContainers.isEmpty {
                label.tag(node.id)
            } else {
                DisclosureGroup(isExpanded: expansion) {
                    ForEach(subContainers, id: \.id) { child in
                        ContainerRow(node: child, depth: depth + 1, selection: $selection,
                                     expandedFolders: $expandedFolders,
                                     collapsedCollections: $collapsedCollections,
                                     focusedCollectionID: focusedCollectionID,
                                     actions: actions,
                                     onCloseCollection: onCloseCollection,
                                     onDropIntoFolder: onDropIntoFolder)
                    }
                } label: {
                    // **The label is the selection, not just a disclosure
                    // handle.** A folder that can be opened is also a folder
                    // whose notes you want to see, and a `DisclosureGroup` label
                    // that is not tagged swallows the tap.
                    label.tag(node.id)
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 3, leading: 8 + CGFloat(depth) * Self.indent,
                                  bottom: 3, trailing: 8))
        .contextMenu { SidebarMenuItems(items: SidebarMenu.items(for: node, actions: actions)) }
        .dropDestination(for: URL.self) { urls, _ in
            node.isPlace ? false : onDropIntoFolder(node.id, urls)
        }
    }

    @ViewBuilder
    private var label: some View {
        switch node.kind {
        case .collection(let collection):
            let content = CollectionRowContent.make(collection, focusedID: focusedCollectionID)
            Label(content.name, systemImage: content.symbol)
                .fontWeight(content.isFocused ? .semibold : .regular)
                .foregroundStyle(content.unavailable == nil ? .primary : .secondary)
                .symbolRenderingMode(content.unavailable == nil ? .monochrome : .multicolor)
        case .place(let name, let symbol):
            Label(name, systemImage: symbol)
        case .folder(let name):
            Label(name, systemImage: "folder")
        case .note, .file:
            // Unreachable: `SidebarTree.containers` removed these. Stated
            // rather than defaulted so a leaf that ever does arrive here is a
            // visible wrong row and not an invisible blank one.
            Label("—", systemImage: "questionmark")
        }
    }

    private var expansion: Binding<Bool> {
        if case .collection(let collection) = node.kind {
            return Binding(get: { !collapsedCollections.contains(collection.id) },
                           set: { open in
                               if open { collapsedCollections.remove(collection.id) }
                               else { collapsedCollections.insert(collection.id) }
                           })
        }
        return Binding(get: { expandedFolders.contains(node.id) },
                       set: { open in
                           if open { expandedFolders.insert(node.id) }
                           else { expandedFolders.remove(node.id) }
                       })
    }
}

// MARK: - Right: what is there

private struct ContentsPane: View {
    var container: NoteOutlineItem?
    var rowHeight: CGFloat
    @Binding var selection: URL?
    var actions: SidebarMenu.Actions
    var row: (Note, String?) -> AnyView

    /// Chosen rather than inherited, for the same reason the container pane
    /// chooses its own: the row height is `max(floor, content + insets)`, and
    /// the List's defaults put it over the 44pt floor by four points. There is
    /// no nesting here, so unlike the left pane the leading inset is a constant.
    private static let insets = EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12)

    private var items: [NoteOutlineItem] {
        container.map { SidebarTree.leaves(of: $0) } ?? []
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(items, id: \.id) { item in
                switch item.kind {
                case .note(let note, let snippet):
                    row(note, snippet)
                        .listRowInsets(Self.insets)
                        .contextMenu {
                            SidebarMenuItems(items: SidebarMenu.items(for: item, actions: actions))
                        }
                case .file(let file):
                    Label(file.name, systemImage: file.kind.symbol)
                        .tag(file.url)
                        .listRowInsets(Self.insets)
                        .contextMenu {
                            SidebarMenuItems(items: SidebarMenu.items(for: item, actions: actions))
                        }
                case .collection, .place, .folder:
                    EmptyView()
                }
            }
        }
        .environment(\.defaultMinListRowHeight, rowHeight)
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(
                    container == nil ? "Nothing Selected" : "No Notes Here",
                    systemImage: container == nil ? "sidebar.left" : "tray",
                    description: Text(container == nil
                        ? "Choose a collection or folder on the left."
                        : "This folder has no notes of its own."))
            }
        }
    }
}

// MARK: - Choosing between them

/// Picks a sidebar layout from the shell the sidebar is *placed in*.
///
/// This has to be a view of its own, and the reason is the whole bug it fixes.
/// `@Environment` resolves at the position of the view that declares it, and
/// `ContentView` sits **above** `AdaptiveShell` — it is what supplies the
/// shell's `sidebar:` slot, not something inside it. So a
/// `@Environment(\.shell)` read there is always the default `.wide`, whatever
/// window it is in, and the band branch was simply never taken: the first
/// build looked exactly like no change at all.
///
/// A child struct evaluated inside the closure resolves the environment where
/// the closure's result is *placed*, which is inside the shell, where the
/// context is real.
struct SidebarLayout<Column: View, Band: View>: View {
    @Environment(\.shell) private var shell
    @ViewBuilder var column: () -> Column
    @ViewBuilder var band: () -> Band

    var body: some View {
        if shell.kind == .tall { band() } else { column() }
    }
}
