//
//  NoteOutlineList.swift
//  HelloNotes
//
//  Created by Chris Tham on 13/7/2026.
//
//  The note list (column 2), backed by a native NSOutlineView so it keeps
//  keyboard arrow-key navigation and folder disclosure while drawing selection
//  in the app accent colour (SwiftUI's List forces the system-blue highlight).
//  Collections are group rows; folders expand; notes and attachments are the
//  selectable leaves.
//

import SwiftUI
#if os(macOS)
import MarkdownEditor
import AppKit

// MARK: - Item model


// MARK: - Representable

struct NoteOutlineList: NSViewRepresentable {
    var roots: [NoteOutlineItem]
    /// Changes only when the *structure* (or text scale) changes, so we reload
    /// the outline only when needed (not on every unrelated SwiftUI update).
    var signature: String
    @Binding var selection: URL?
    /// An outline-item id to expand and scroll into view, *without* touching the
    /// note selection. Collection rows carry no URL, so `applySelection` can't
    /// reach them — and a newly added collection is appended last, which on a
    /// library of any size puts it below the fold. Cleared once applied.
    @Binding var revealID: String?
    /// Accepted so the call site is one call site. `NSOutlineView` owns its own
    /// expansion and restores it across a reload, so these are not read here —
    /// the SwiftUI branch has no such memory and needs the shell to hold it.
    @Binding var expandedFolders: Set<String>
    @Binding var collapsedCollections: Set<Collection.ID>
    var focusedCollectionID: Collection.ID?
    var accent: Color
    /// Multiplies the row fonts and heights with the app's text-size setting.
    var fontScale: CGFloat = 1

    /// The collection the whole outline belongs to, when the library rail has
    /// scoped it to one (the ordinary case — the rail replaced the tree's
    /// collection level). `nil` while searching, where the roots are collection
    /// group rows and each subtree names its own collection.
    var scopedCollectionID: Collection.ID? = nil

    /// What the shell's commands *do*. The menu itself — which items, in which
    /// order, with which titles — is `SidebarMenu`, shared, so neither widget
    /// owns a command list of its own. See `SidebarMenu.swift` for the five
    /// divergences that arrangement had already produced.
    var actions: SidebarMenu.Actions = SidebarMenu.Actions()
    /// The collection the whole outline belongs to, for the empty-space menu.
    var scopedCollection: Collection? = nil
    /// Close a collection from the row's own button (not the menu).
    var onCloseCollection: (Collection) -> Void = { _ in }
    /// Accepted so the call site is one call site. AppKit builds its own cells
    /// from `NoteOutlineItem`; the SwiftUI branch asks the shell, because a
    /// SwiftUI row *is* a view. Both draw `NoteRowContent`, which is what keeps
    /// them agreeing about what a row says.
    var row: (Note, String?) -> AnyView = { _, _ in AnyView(EmptyView()) }
    /// A note/attachment was dropped on a folder or collection row: move every
    /// URL into the folder whose absolute path is the outline-item id.
    var onDropIntoFolder: (String, [URL]) -> Bool = { _, _ in false }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        outline.headerView = nil
        outline.rowSizeStyle = .custom
        outline.indentationPerLevel = 14 * fontScale
        outline.selectionHighlightStyle = .regular
        outline.floatsGroupRows = false
        outline.usesAutomaticRowHeights = false
        outline.style = .inset
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = false

        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator

        // A click anywhere on a folder row opens or closes it. Folders are not
        // selectable (see `shouldSelectItem`), so until now the only target was
        // the disclosure triangle — roughly 12pt of a 26pt row whose name you
        // are already pointing at.
        outline.target = context.coordinator
        outline.action = #selector(Coordinator.rowClicked(_:))

        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu

        // Drag & drop: notes/attachments can be dragged onto folder or
        // collection rows to move them (within their own collection).
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)

        context.coordinator.outlineView = outline
        context.coordinator.reload(roots: roots, signature: signature)
        context.coordinator.applySelection(selection)

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        coord.accentColor = NSColor(accent)
        coord.focusedCollectionID = focusedCollectionID
        (scroll.documentView as? NSOutlineView)?.indentationPerLevel = 14 * fontScale
        // `signature` includes the text scale, so a scale change reloads the
        // outline (re-querying cell fonts and row heights).
        coord.reload(roots: roots, signature: signature)
        coord.refreshAccent()
        coord.applySelection(selection)
        if let id = revealID, coord.reveal(id: id) {
            // Clearing a binding during `updateNSView` would mutate state inside
            // a view update; defer it to the next runloop turn.
            DispatchQueue.main.async { revealID = nil }
        }
    }

    /// Viewport sizing (S1). This one matters as much as the editor: an
    /// outline of a 2,000-note vault has a fitting height of tens of
    /// thousands of points, and `NSSplitView` sizes itself to its TALLEST
    /// column — so without this the note list alone inflates the whole shell.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView,
                      context: Context) -> CGSize? { viewportSizeThatFits(proposal) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var parent: NoteOutlineList
        weak var outlineView: NSOutlineView?
        var accentColor: NSColor
        var focusedCollectionID: Collection.ID?

        private var roots: [NoteOutlineItem] = []
        private var itemsByURL: [URL: NoteOutlineItem] = [:]
        private var lastSignature: String?
        private var expandedIDs: Set<String> = []
        private var knownGroupIDs: Set<String> = []
        private var applyingSelection = false

        init(_ parent: NoteOutlineList) {
            self.parent = parent
            self.accentColor = NSColor(parent.accent)
            self.focusedCollectionID = parent.focusedCollectionID
        }

        // MARK: Reload

        func reload(roots: [NoteOutlineItem], signature: String) {
            // Default-expand any newly-seen collection group. Pinned places
            // start *collapsed*: they are a shortcut, not the thing you came
            // for, and expanding them by default pushes the collections — which
            // are the reason the sidebar exists — below the fold.
            for root in roots where root.isGroup && !root.isPlace
                                 && !knownGroupIDs.contains(root.id) {
                knownGroupIDs.insert(root.id)
                expandedIDs.insert(root.id)
            }
            guard signature != lastSignature else {
                self.roots = roots            // keep references fresh for actions
                return
            }
            lastSignature = signature
            self.roots = roots
            itemsByURL = Self.indexByURL(roots)   // for O(1) selection lookup
            guard let outline = outlineView else { return }
            outline.reloadData()
            // Restore expansion by stable id.
            func expandTracked(_ items: [NoteOutlineItem]) {
                for item in items where item.isExpandable {
                    if expandedIDs.contains(item.id) { outline.expandItem(item) }
                    expandTracked(item.children)
                }
            }
            expandTracked(roots)
        }

        func refreshAccent() {
            guard let outline = outlineView else { return }
            for row in 0..<outline.numberOfRows {
                (outline.rowView(atRow: row, makeIfNecessary: false) as? AccentRowView)?.accentColor = accentColor
                outline.rowView(atRow: row, makeIfNecessary: false)?.needsDisplay = true
            }
        }

        func applySelection(_ url: URL?) {
            guard let outline = outlineView else { return }
            guard let url, let item = itemsByURL[url] else {
                if url == nil { applyingSelection = true; outline.deselectAll(nil); applyingSelection = false }
                return
            }
            let row = outline.row(forItem: item)
            guard row >= 0, outline.selectedRow != row else { return }
            applyingSelection = true
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
            applyingSelection = false
        }

        /// Expand `id`'s row and scroll it into view. Returns false when the id
        /// isn't in the tree yet, so the caller keeps the request pending until
        /// a reload brings the row in rather than dropping it on the floor.
        @discardableResult
        func reveal(id: String) -> Bool {
            guard let outline = outlineView,
                  let item = Self.find(id: id, in: roots) else { return false }
            if item.isExpandable {
                expandedIDs.insert(item.id)
                outline.expandItem(item)
            }
            let row = outline.row(forItem: item)
            guard row >= 0 else { return false }
            outline.scrollRowToVisible(row)
            return true
        }

        private static func find(id: String, in items: [NoteOutlineItem]) -> NoteOutlineItem? {
            for item in items {
                if item.id == id { return item }
                if let hit = find(id: id, in: item.children) { return hit }
            }
            return nil
        }

        /// Flatten the tree into a URL→item map so selection lookup is O(1)
        /// instead of a recursive O(N) walk on every SwiftUI update.
        ///
        /// A note can appear twice — once in its folder, once under Recents or
        /// Bookmarks — and **the copy in the tree must win**. `applySelection`
        /// resolves a URL to one item and calls `row(forItem:)`, which returns
        /// -1 for anything inside a collapsed parent. Places start collapsed, so
        /// indexing the place's copy would make selecting a note (from Open
        /// Quickly, or after creating one) silently highlight nothing.
        private static func indexByURL(_ items: [NoteOutlineItem]) -> [URL: NoteOutlineItem] {
            var map: [URL: NoteOutlineItem] = [:]
            func walk(_ items: [NoteOutlineItem], insidePlace: Bool) {
                for item in items {
                    let place = insidePlace || item.isPlace
                    if let url = item.url, !(place && map[url] != nil) { map[url] = item }
                    walk(item.children, insidePlace: place)
                }
            }
            // Two passes so order in `roots` cannot decide the winner: the tree
            // claims every URL it owns, then places fill only what is left.
            walk(items.filter { !$0.isPlace }, insidePlace: false)
            walk(items.filter(\.isPlace), insidePlace: true)
            return map
        }

        // MARK: DataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? NoteOutlineItem)?.children.count ?? roots.count
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? NoteOutlineItem)?.children[index] ?? roots[index]
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? NoteOutlineItem)?.isExpandable ?? false
        }

        // MARK: Drag & drop (move notes/attachments between folders)

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            // Only leaves (notes / attachment files) are draggable.
            guard let node = item as? NoteOutlineItem, let url = node.url else { return nil }
            return url as NSURL
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard let source = draggedURL(from: info),
                  let target = dropTarget(for: item) else { return [] }
            // Same collection only, and never a no-op (already in that folder).
            guard target.folderURL.standardizedFileURL.path.hasPrefix(target.collectionID),
                  source.standardizedFileURL.path.hasPrefix(target.collectionID),
                  source.deletingLastPathComponent().standardizedFileURL != target.folderURL.standardizedFileURL
            else { return [] }
            // Retarget the drop onto the row itself (not between rows).
            outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                         item: Any?, childIndex index: Int) -> Bool {
            guard let source = draggedURL(from: info),
                  let target = dropTarget(for: item) else { return false }
            return parent.onDropIntoFolder(target.folderURL.path, [source])
        }

        private func draggedURL(from info: NSDraggingInfo) -> URL? {
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
            return urls?.first
        }

        /// The folder a drop on `item` means: a folder row is itself the target
        /// (its id is the folder's absolute path); a collection row is its root.
        private func dropTarget(for item: Any?) -> (folderURL: URL, collectionID: String)? {
            guard let node = item as? NoteOutlineItem else {
                // Dropped below the rows: the scoped collection's root, which
                // used to be reachable by dropping on its group row.
                guard let id = parent.scopedCollectionID else { return nil }
                return (URL(fileURLWithPath: id, isDirectory: true), id)
            }
            if let collection = node.collection {
                return (collection.rootURL, collection.id)
            }
            if case .folder = node.kind {
                // Folder ids are "<collection.id><relative path>".
                guard let root = rootID(containing: node) else { return nil }
                return (URL(fileURLWithPath: node.id, isDirectory: true), root)
            }
            return nil
        }

        /// The collection id owning `node` (folder ids are prefixed with it).
        ///
        /// In search results the roots are collection group rows, so the owner
        /// is the group this node hangs under. Everywhere else the roots are
        /// *folders* of one collection — matching a node against them would
        /// return a folder path as if it were a collection id, and a drop from
        /// one top-level folder into another would then be rejected as
        /// cross-collection. There the rail already knows the answer.
        private func rootID(containing node: NoteOutlineItem) -> String? {
            if let group = roots.first(where: {
                // Places are excluded: a note listed under Recents lives in
                // whichever collection owns it, not in "Recents", and treating
                // the place as its root would reject every drag out of it.
                $0.isGroup && !$0.isPlace && (node.id == $0.id || node.id.hasPrefix($0.id + "/"))
            }) {
                return group.id
            }
            return parent.scopedCollectionID
        }

        // MARK: Delegate — rows & cells

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let row = AccentRowView()
            row.accentColor = accentColor
            row.isGroupRowStyle = (item as? NoteOutlineItem)?.isGroup ?? false
            return row
        }

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            (item as? NoteOutlineItem)?.isGroup ?? false
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            (item as? NoteOutlineItem)?.isSelectable ?? false
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            let scale = parent.fontScale
            guard let node = item as? NoteOutlineItem else { return 24 * scale }
            if case .note = node.kind { return 42 * scale }
            return 26 * scale
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? NoteOutlineItem else { return nil }
            switch node.kind {
            case .collection(let collection): return groupCell(collection)
            case .place(let title, let symbol): return placeCell(title, symbol: symbol)
            case .folder(let name): return labelCell(name, symbol: "folder", secondary: false)
            case .note(let note, let snippet): return noteCell(note, snippet: snippet)
            case .file(let file): return labelCell(file.name, symbol: file.kind.symbol, secondary: true)
            }
        }

        // MARK: Selection changes

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let outline = outlineView else { return }
            guard let node = outline.item(atRow: outline.selectedRow) as? NoteOutlineItem,
                  let url = node.url else { return }
            if parent.selection != url { parent.selection = url }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            if let node = notification.userInfo?["NSObject"] as? NoteOutlineItem { expandedIDs.insert(node.id) }
        }
        func outlineViewItemDidCollapse(_ notification: Notification) {
            if let node = notification.userInfo?["NSObject"] as? NoteOutlineItem { expandedIDs.remove(node.id) }
        }

        // MARK: Cells

        private func symbolIcon(_ name: String) -> NSImageView {
            let icon = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = .secondaryLabelColor
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12 * parent.fontScale, weight: .regular)
            return icon
        }

        /// A pinned place: icon and title, and nothing else. A collection group
        /// row carries a close button and a git dot because a collection can be
        /// closed and can be dirty; Recents can be neither.
        private func placeCell(_ title: String, symbol: String) -> NSView {
            let container = NSTableCellView()
            let row = NSStackView(views: [
                symbolIcon(symbol),
                label(title, font: .systemFont(ofSize: 11 * parent.fontScale, weight: .regular),
                      color: .secondaryLabelColor),
            ])
            row.spacing = 5
            row.orientation = .horizontal
            row.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                row.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
                row.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
            return container
        }

        private func groupCell(_ collection: Collection) -> NSView {
            let container = NSTableCellView()
            // An unreadable collection has to *look* unreadable. It keeps its
            // notes listed — they are the last true picture of the folder — so
            // without this the row is indistinguishable from a healthy one and
            // the stale contents read as current.
            let content = CollectionRowContent.make(collection,
                                                    focusedID: parent.focusedCollectionID)
            let unavailable = content.unavailable
            let icon = symbolIcon(content.symbol)
            if content.isDimmed { icon.contentTintColor = .systemOrange }
            // A long scan is visible on the row itself, not only in the status
            // bar: the sidebar is where you notice a collection is still filling
            // in. Indeterminate and self-animating, so it costs no redraws — the
            // live counts stay in the status bar, where they can change without
            // rebuilding the outline.
            let spinner: NSProgressIndicator? = content.isScanning ? {
                let indicator = NSProgressIndicator()
                indicator.style = .spinning
                indicator.controlSize = .small
                indicator.isIndeterminate = true
                indicator.startAnimation(nil)
                indicator.setAccessibilityLabel(content.scanningLabel)
                indicator.translatesAutoresizingMaskIntoConstraints = false
                indicator.widthAnchor.constraint(equalToConstant: 12).isActive = true
                indicator.heightAnchor.constraint(equalToConstant: 12).isActive = true
                return indicator
            }() : nil
            let name = label(content.name, font: .systemFont(ofSize: 11 * parent.fontScale,
                weight: content.isFocused ? .semibold : .regular),
                color: content.isDimmed ? .tertiaryLabelColor : .secondaryLabelColor)
            if let help = content.help {
                name.toolTip = help
            } else if collection.hasIncompleteIndex {
                name.toolTip = "Re-indexing — search results may be incomplete until it finishes."
            }

            let close = HoverButton()
            close.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Close")
            close.isBordered = false
            close.imagePosition = .imageOnly
            close.target = self
            close.action = #selector(closeClicked(_:))
            close.contentTintColor = .tertiaryLabelColor
            close.setAccessibilityLabel("Close “\(collection.name)”")
            close.toolTip = "Close “\(collection.name)”"

            let stack = NSStackView(views: [icon, name])
            stack.spacing = 5
            stack.orientation = .horizontal
            if let spinner { stack.addArrangedSubview(spinner) }

            if let clean = content.gitIsClean {
                let dot = NSView()
                dot.wantsLayer = true
                dot.layer?.backgroundColor = (clean ? NSColor.tertiaryLabelColor : NSColor.systemOrange).cgColor
                dot.layer?.cornerRadius = 3
                // The colour alone signals git state; label it for VoiceOver.
                dot.setAccessibilityElement(true)
                dot.setAccessibilityRole(.image)
                dot.setAccessibilityLabel(content.gitLabel ?? "")
                dot.translatesAutoresizingMaskIntoConstraints = false
                dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
                dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
                stack.addArrangedSubview(dot)
            }

            let row = NSStackView(views: [stack, NSView(), close])
            row.orientation = .horizontal
            row.distribution = .fill
            row.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
                row.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
            return container
        }

        private func noteCell(_ note: Note, snippet: String?) -> NSView {
            let container = NSTableCellView()
            let title = label(note.title, font: .systemFont(ofSize: 13 * parent.fontScale, weight: .semibold), color: .labelColor)
            // Title row: title, plus a cloud badge when the note is online-only
            // (in a cloud folder but not downloaded locally).
            let titleRow: NSView
            if note.isOnlineOnly {
                let cloud = symbolIcon("icloud.and.arrow.down")
                cloud.contentTintColor = .tertiaryLabelColor
                cloud.setContentHuggingPriority(.required, for: .horizontal)
                cloud.setAccessibilityLabel(NoteRowContent.onlineOnlyLabel)
                let row = NSStackView(views: [title, cloud])
                row.orientation = .horizontal
                row.spacing = 4
                row.alignment = .firstBaseline
                titleRow = row
            } else {
                titleRow = title
            }
            // Via `NoteRowContent`, shared with the iPad's sidebar — the two
            // rows drew from nothing in common, and the iPad's ended up with no
            // second line and no badge at all.
            // Stacked, always: `ShellMetrics.sidebarCap` (340) is below
            // `noteRowTwoColumn` (420), so a Mac sidebar never reaches the
            // width where a date can share the title's line.
            // `sidebarStaysBelowTheTwoColumnThreshold` fails if that stops
            // being true, rather than leaving this comment quietly wrong.
            let content = NoteRowContent.make(note, snippet: snippet)
            let subtitleText = content.snippet ?? content.date
            let subtitle = label(subtitleText, font: .systemFont(ofSize: 11 * parent.fontScale), color: .secondaryLabelColor)
            subtitle.lineBreakMode = .byTruncatingTail
            let stack = NSStackView(views: [titleRow, subtitle])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 1
            stack.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
                stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
            return container
        }

        private func labelCell(_ text: String, symbol: String, secondary: Bool) -> NSView {
            let container = NSTableCellView()
            let icon = symbolIcon(symbol)
            let name = label(text, font: .systemFont(ofSize: 12 * parent.fontScale), color: .labelColor)
            name.lineBreakMode = .byTruncatingTail
            let stack = NSStackView(views: [icon, name])
            stack.orientation = .horizontal
            stack.spacing = 5
            stack.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
                stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
            return container
        }

        private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = font
            field.textColor = color
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return field
        }

        // MARK: Actions

        @objc private func closeClicked(_ sender: NSButton) {
            guard let outline = outlineView else { return }
            let row = outline.row(for: sender)
            guard row >= 0, let node = outline.item(atRow: row) as? NoteOutlineItem,
                  let collection = node.collection else { return }
            parent.onCloseCollection(collection)
        }

        // MARK: Clicking a row

        /// Single click on a folder row toggles it.
        ///
        /// The disclosure triangle is deliberately excluded: AppKit has already
        /// expanded or collapsed the item by the time this action fires, so
        /// toggling again would undo it and the chevron would read as dead.
        /// `frameOfOutlineCell(atRow:)` is that triangle's rect.
        ///
        /// Notes fall through — they are selectable, and selection is what opens
        /// them; only folders, which have no other click meaning, are claimed.
        @objc func rowClicked(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            guard row >= 0,
                  let node = sender.item(atRow: row) as? NoteOutlineItem,
                  case .folder = node.kind
            else { return }

            let inWindow = NSApp.currentEvent?.locationInWindow
                ?? sender.window?.mouseLocationOutsideOfEventStream
                ?? .zero
            guard !sender.frameOfOutlineCell(atRow: row).contains(sender.convert(inWindow, from: nil))
            else { return }

            if sender.isItemExpanded(node) { sender.animator().collapseItem(node) }
            else { sender.animator().expandItem(node) }
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline = outlineView else { return }
            let items: [SidebarMenu.Item]
            if outline.clickedRow >= 0,
               let node = outline.item(atRow: outline.clickedRow) as? NoteOutlineItem {
                items = SidebarMenu.items(for: node, actions: parent.actions)
            } else {
                // Empty space below the rows, which names no node.
                items = SidebarMenu.emptySpace(in: parent.scopedCollection,
                                               actions: parent.actions)
            }
            add(items, to: menu)
        }

        private func add(_ items: [SidebarMenu.Item], to menu: NSMenu) {
            for item in items {
                if item.isSeparator {
                    menu.addItem(.separator())
                } else if let children = item.children {
                    let parentItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                    let submenu = NSMenu()
                    add(children, to: submenu)
                    parentItem.submenu = submenu
                    menu.addItem(parentItem)
                } else {
                    addItem(menu, item.title, action: item.run ?? {})
                }
            }
        }

        private func addItem(_ menu: NSMenu, _ title: String, action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuAction(run: action)
            menu.addItem(item)
        }
        @objc private func runMenuAction(_ sender: NSMenuItem) {
            (sender.representedObject as? MenuAction)?.run()
        }
        private final class MenuAction { let run: () -> Void; init(run: @escaping () -> Void) { self.run = run } }
    }
}

// MARK: - Accent-drawing row

/// A row view that draws its selection with the app accent colour instead of
/// the system-blue highlight.
final class AccentRowView: NSTableRowView {
    var accentColor: NSColor = .controlAccentColor { didSet { needsDisplay = true } }

    override var isEmphasized: Bool { get { false } set { } }   // avoid the vibrant system tint

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected, selectionHighlightStyle != .none else { return }
        let inset = bounds.insetBy(dx: 5, dy: 1)
        let path = NSBezierPath(roundedRect: inset, xRadius: 6, yRadius: 6)
        accentColor.withAlphaComponent(0.30).setFill()
        path.fill()
    }
}

/// A borderless button that only reveals its image on row hover would be ideal;
/// for simplicity it's always visible but faint.
final class HoverButton: NSButton {}

#else

/// The sidebar tree on iOS: the same `[NoteOutlineItem]`, drawn by SwiftUI.
///
/// The widget is the only thing left that differs. macOS keeps an
/// `NSOutlineView` — its header records why, a claim about `List` forcing the
/// system selection colour that is worth re-testing rather than trusting — and
/// iOS draws the identical items with `SidebarItemRow`. Same items, same rows,
/// same menus, same drop targets: `SidebarTree` decides what is in the tree and
/// `NoteRowContent` decides what a row says, on both.
///
/// The parameters mirror the AppKit one so a shell calls `NoteOutlineList` the
/// same way either side. Several are unused here — `signature`, `fontScale`,
/// `focusedCollectionID`, `scopedCollectionID` — because they exist to drive an
/// `NSOutlineView`'s reload and cell metrics, which SwiftUI derives on its own.
/// They are accepted rather than removed so the call site is one call site.
struct NoteOutlineList: View {
    var roots: [NoteOutlineItem]
    var signature: String
    @Binding var selection: URL?
    @Binding var revealID: String?
    @Binding var expandedFolders: Set<String>
    @Binding var collapsedCollections: Set<Collection.ID>
    var focusedCollectionID: Collection.ID?
    var accent: Color
    var fontScale: CGFloat = 1
    var scopedCollectionID: Collection.ID?

    /// What the shell's commands do. Which commands there are is
    /// `SidebarMenu` — the same list the Mac's `NSMenu` is built from.
    var actions: SidebarMenu.Actions = SidebarMenu.Actions()
    var scopedCollection: Collection? = nil
    var onCloseCollection: (Collection) -> Void = { _ in }

    /// A row for a note. The shell supplies it because what a row *says* is
    /// `NoteRowContent`'s and what it *does* — select, drag — belongs to the
    /// shell that owns the selection.
    var row: (Note, String?) -> AnyView
    var onDropIntoFolder: (String, [URL]) -> Bool

    var body: some View {
        // `ScrollViewReader`, because `revealID` was declared here and never
        // read: the Mac scrolled a newly-added collection into view and the
        // iPad silently did not, so on a library of any size "add this cloud
        // folder" appended a row below the fold and looked like nothing had
        // happened.
        ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(roots, id: \.id) { item in
                    SidebarItemRow(
                        item: item,
                        expandedFolders: $expandedFolders,
                        collapsedCollections: $collapsedCollections,
                        actions: actions,
                        focusedCollectionID: focusedCollectionID,
                        row: row,
                        onDropIntoFolder: onDropIntoFolder)
                }
            }
            .tint(accent)
            // The row's height is its content plus the List's insets, floored
            // here so a one-line note row is still a 44pt touch target.
            .environment(\.defaultMinListRowHeight, ShellMetrics.noteRowTouchMinimum)
            .onChange(of: revealID) { _, id in
                guard let id else { return }
                reveal(id, with: proxy)
            }
            // A reveal asked for before this list existed — the ordinary case,
            // since adding a collection is what asks.
            .onAppear { if let id = revealID { reveal(id, with: proxy) } }
        }
    }

    /// Open whatever hides `id`, then scroll to it.
    ///
    /// A row inside a closed disclosure group is not in the list at all, so
    /// scrolling to it does nothing until its ancestors are open. Folder ids
    /// are absolute paths, so an ancestor is a path prefix.
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
        // After the expansion has been applied, or the target is still not a
        // row and `scrollTo` has nothing to find.
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(id, anchor: .center) }
            revealID = nil
        }
    }
}

/// One `SidebarMenu.Item` list, as SwiftUI buttons. The Mac walks the same
/// array into an `NSMenu`; this is the only other renderer.
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

/// One sidebar item and everything under it.
///
/// Its own `View` because the renderer recurses, and a function returning
/// `some View` cannot: the opaque type would be defined in terms of itself.
/// The old `CollectionTreeRow` had the same shape over `CollectionTreeNode`;
/// this walks `NoteOutlineItem`, which is the model the Mac's outline walks.
struct SidebarItemRow: View {
    let item: NoteOutlineItem
    /// Open folders, shared by the whole tree so the state survives the rows
    /// being rebuilt (which happens on every rescan).
    @Binding var expandedFolders: Set<String>
    /// Collections the user has folded away. A *collapsed* set, so a newly
    /// opened collection starts open — which is what a collection you just
    /// opened should do.
    @Binding var collapsedCollections: Set<Collection.ID>

    let actions: SidebarMenu.Actions
    /// Which collection the rest of the window is acting on — the row draws it
    /// in semibold, as the AppKit cell does.
    let focusedCollectionID: Collection.ID?
    let row: (Note, String?) -> AnyView
    let onDropIntoFolder: (String, [URL]) -> Bool

    /// This row's menu, from the shared list.
    private var menuItems: [SidebarMenu.Item] {
        SidebarMenu.items(for: item, actions: actions)
    }

    var body: some View {
        content.id(item.id)
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .note(let note, let snippet):
            row(note, snippet)
                .contextMenu { SidebarMenuItems(items: menuItems) }

        case .file(let file):
            // An attachment had no menu at all here — not Open, not Reveal —
            // while the Mac's had both. Same list now.
            Label(file.name, systemImage: file.kind.symbol)
                .tag(file.url)
                .contextMenu { SidebarMenuItems(items: menuItems) }

        case .place(let name, let symbol):
            DisclosureGroup {
                children
            } label: {
                Label(name, systemImage: symbol)
            }

        case .collection(let collection):
            DisclosureGroup(isExpanded: Binding(
                get: { !collapsedCollections.contains(collection.id) },
                set: { open in
                    if open { collapsedCollections.remove(collection.id) }
                    else { collapsedCollections.insert(collection.id) }
                }
            )) {
                children
            } label: {
                // **Closing a collection has to be reachable here.** It was only
                // ever offered as a swipe on the compact shell's collections
                // list — a view the iPad never shows at regular width — so a
                // collection could be opened and never closed again. A *visible*
                // control, not just a long-press: the Mac can afford a hidden
                // right-click because that is where Mac users look.
                HStack {
                    // The same five things the AppKit cell draws, from the same
                    // decision — see `CollectionRowContent`. This was
                    // `Text(collection.name).font(.headline)`, so an unreadable
                    // collection looked healthy while listing stale notes, a
                    // running scan was invisible, and Git state and focus were
                    // not shown at all.
                    let content = CollectionRowContent.make(
                        collection, focusedID: focusedCollectionID)
                    Image(systemName: content.symbol)
                        .foregroundStyle(content.isDimmed ? AnyShapeStyle(.orange)
                                                          : AnyShapeStyle(.secondary))
                    Text(content.name)
                        .font(.headline)
                        .fontWeight(content.isFocused ? .semibold : .regular)
                        .foregroundStyle(content.isDimmed ? AnyShapeStyle(.tertiary)
                                                          : AnyShapeStyle(.primary))
                    if content.isScanning {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(content.scanningLabel)
                    }
                    if let clean = content.gitIsClean {
                        Circle()
                            .fill(clean ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.orange))
                            .frame(width: 6, height: 6)
                            .accessibilityLabel(content.gitLabel ?? "")
                    }
                    Spacer()
                    Menu {
                        SidebarMenuItems(items: menuItems)
                    } label: {
                        Image(systemName: "ellipsis.circle").imageScale(.large)
                    }
                    .accessibilityLabel("\(collection.name) actions")
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                }
                .contextMenu { SidebarMenuItems(items: menuItems) }
                .help(CollectionRowContent.make(collection,
                                                focusedID: focusedCollectionID).help ?? "")
            }

        case .folder(let name):
            DisclosureGroup(isExpanded: Binding(
                get: { expandedFolders.contains(item.id) },
                set: { open in
                    if open { expandedFolders.insert(item.id) }
                    else { expandedFolders.remove(item.id) }
                }
            )) {
                children
            } label: {
                // On the label, not the group: a menu on the group would claim
                // the long-press of every row nested inside it, and a drop on
                // the group would swallow drops meant for its children.
                //
                // The name is a `Button` because a `DisclosureGroup` only listens
                // to its chevron, and a folder row reads as one target — aiming
                // for a 12pt triangle to open something whose name you are
                // already pointing at is a precision tax for no reason. A real
                // Button rather than a tap gesture, so it carries the trait and
                // answers the keyboard and VoiceOver too.
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if expandedFolders.contains(item.id) { expandedFolders.remove(item.id) }
                        else { expandedFolders.insert(item.id) }
                    }
                } label: {
                    Label(name, systemImage: "folder")
                        // The whole row, not just the glyphs.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint(expandedFolders.contains(item.id) ? "Collapses the folder"
                                                                     : "Expands the folder")
                .contextMenu { SidebarMenuItems(items: menuItems) }
                .dropDestination(for: URL.self) { urls, _ in
                    onDropIntoFolder(item.id, urls)
                }
            }
        }
    }

    private var children: some View {
        ForEach(item.children, id: \.id) { child in
            SidebarItemRow(item: child,
                           expandedFolders: $expandedFolders,
                           collapsedCollections: $collapsedCollections,
                           actions: actions,
                           focusedCollectionID: focusedCollectionID,
                           row: row,
                           onDropIntoFolder: onDropIntoFolder)
        }
    }
}

#endif
