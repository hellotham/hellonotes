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
//  Crucially the structural objection does not apply here either. The band is
//  the top half of a `VStack` (`AdaptiveShell.tallShell`), and its toggle is the
//  bar's own sidebar button — the same one the column shells use — so there is
//  no platform-placed toggle to lose by putting two things side by side.
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

    /// How wide the band's left pane is, as dragged. Stored like the right
    /// panel's width, and clamped at use (`ResizableDivider`).
    @AppStorage("bandContainerPaneWidth") private var containerPaneWidth
        = Double(ShellMetrics.bandContainerPane)

    /// What the left pane may be: enough for a folder name, and never so wide
    /// that the notes beside it have less than a list's worth of room.
    private var paneRange: ClosedRange<CGFloat> {
        let upper = max(180, shell.size.width - 260)
        return 180...upper
    }

    private var paneWidth: CGFloat {
        min(max(CGFloat(containerPaneWidth), paneRange.lowerBound), paneRange.upperBound)
    }

    private var containers: [NoteOutlineItem] { SidebarTree.containers(roots) }
    private var selectedContainer: NoteOutlineItem? {
        containerID.flatMap { SidebarTree.node(id: $0, in: roots) }
    }

    var body: some View {
        HStack(spacing: 0) {
            ContainerPane(
                nodes: containers,
                accent: accent,
                selection: $containerID,
                expandedFolders: $expandedFolders,
                collapsedCollections: $collapsedCollections,
                focusedCollectionID: focusedCollectionID,
                actions: actions,
                onCloseCollection: onCloseCollection,
                onDropIntoFolder: onDropIntoFolder)
                .frame(width: paneWidth)

            ResizableDivider(width: $containerPaneWidth, range: paneRange, edge: .leading,
                             label: "Folder list width")

            ContentsPane(
                container: selectedContainer,
                accent: accent,
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

/// Collections, places and folders — the containers — drawn with the same rows
/// as the sidebar tree. It was a `List` of `DisclosureGroup`s in `.subheadline`,
/// which the OS draws at its own size on each platform; now it is the Mac
/// outline's 11–12pt rows at 22–24pt, on both.
private struct ContainerPane: View {
    var nodes: [NoteOutlineItem]
    var accent: Color
    @Binding var selection: String?
    @Binding var expandedFolders: Set<String>
    @Binding var collapsedCollections: Set<Collection.ID>
    var focusedCollectionID: Collection.ID?
    var actions: SidebarMenu.Actions
    var onCloseCollection: (Collection) -> Void
    var onDropIntoFolder: (String, [URL]) -> Bool

    var body: some View {
        let lines = ChromeTree.lines(nodes, expanded: expandedFolders,
                                     collapsed: collapsedCollections,
                                     include: { $0.isContainer })
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(lines) { line in row(line) }
            }
            .padding(.vertical, 4)
        }
        .viewport()
        .background(Chrome.Colour.chrome)
    }

    @ViewBuilder
    private func row(_ line: ChromeTreeLine) -> some View {
        let node = line.item
        // Once: a folder's list stats the disk, and two menus read it.
        let items = SidebarMenu.items(for: node, actions: actions)
        ChromeRowFrame(height: ChromeTree.height(node), depth: line.depth,
                       isSelected: selection == node.id, accent: accent) {
            ChromeDisclosure(isExpandable: line.isExpandable, isExpanded: line.isExpanded) {
                toggle(node)
            }
            switch node.kind {
            case .collection(let collection):
                ChromeCollectionRow(content: CollectionRowContent.make(collection,
                                                                      focusedID: focusedCollectionID))
                Spacer(minLength: 4)
                RowActionsMenu(name: collection.name, items: items)
            case .place(let name, let symbol):
                ChromeLabelRow(systemImage: symbol, title: name, titleSize: 11,
                               titleColour: Chrome.Colour.secondaryLabel)
                Spacer(minLength: 4)
            case .folder(let name):
                ChromeLabelRow(systemImage: "folder", title: name)
                Spacer(minLength: 4)
                RowActionsMenu(name: name, items: items)
            case .note, .file:
                // Unreachable: only containers are included. Stated so a leaf
                // that ever arrives here is a visible wrong row, not a blank one.
                ChromeLabelRow(systemImage: "questionmark", title: "—")
            }
        }
        .id(node.id)
        // **The row is the selection, not a disclosure handle**: a folder that
        // can be opened is also a folder whose notes you want to see. The
        // triangle opens it.
        .onTapGesture { selection = node.id }
        .contextMenu { SidebarMenuItems(items: items) }
        // Recents and Bookmarks hold no files, so they refuse a drop — as
        // `isEnabled`, which declines before the row lights up.
        .dropDestination(for: URL.self, isEnabled: !node.isPlace) { urls, _ in
            _ = onDropIntoFolder(node.id, urls)
        }
    }

    private func toggle(_ node: NoteOutlineItem) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if case .collection(let collection) = node.kind {
                if collapsedCollections.contains(collection.id) { collapsedCollections.remove(collection.id) }
                else { collapsedCollections.insert(collection.id) }
            } else {
                if expandedFolders.contains(node.id) { expandedFolders.remove(node.id) }
                else { expandedFolders.insert(node.id) }
            }
        }
    }
}

// MARK: - Right: what is there

/// The chosen container's notes and files, in the same rows as the tree.
private struct ContentsPane: View {
    var container: NoteOutlineItem?
    var accent: Color
    @Binding var selection: URL?
    var actions: SidebarMenu.Actions
    var row: (Note, String?) -> AnyView

    private var items: [NoteOutlineItem] {
        container.map { SidebarTree.leaves(of: $0) } ?? []
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(items, id: \.id) { item in
                    ChromeRowFrame(height: ChromeTree.height(item),
                                   isSelected: item.url != nil && item.url == selection,
                                   accent: accent) {
                        switch item.kind {
                        case .note(let note, let snippet):
                            row(note, snippet)
                        case .file(let file):
                            ChromeLabelRow(systemImage: file.kind.symbol, title: file.name)
                                .draggable(file.url)
                        case .collection, .place, .folder:
                            EmptyView()
                        }
                    }
                    .onTapGesture { if let url = item.url { selection = url } }
                    .contextMenu {
                        SidebarMenuItems(items: SidebarMenu.items(for: item, actions: actions))
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .viewport()
        .background(Chrome.Colour.content)
        .overlay {
            if items.isEmpty {
                // Not `ContentUnavailableView`, which is drawn at each OS's own
                // sizes.
                VStack(spacing: 6) {
                    Image(systemName: container == nil ? "sidebar.left" : "tray")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Chrome.Colour.tertiaryLabel)
                    Text(container == nil ? "Nothing Selected" : "No Notes Here")
                        .font(Chrome.Typeface.title)
                        .foregroundStyle(Chrome.Colour.label)
                    Text(container == nil ? "Choose a collection or folder on the left."
                                          : "This folder has no notes of its own.")
                        .font(Chrome.Typeface.secondary)
                        .foregroundStyle(Chrome.Colour.secondaryLabel)
                }
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
