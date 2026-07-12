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

#if os(macOS)
import SwiftUI
import AppKit

// MARK: - Item model

/// A node in the outline. A reference type so NSOutlineView can track it; a
/// stable `id` (path) survives rebuilds so expansion/selection can be restored.
final class NoteOutlineItem {
    enum Kind {
        case collection(Collection)
        case folder(String)
        case note(Note, snippet: String?)
        case file(CollectionFile)
    }

    let id: String
    let kind: Kind
    let children: [NoteOutlineItem]

    init(id: String, kind: Kind, children: [NoteOutlineItem] = []) {
        self.id = id
        self.kind = kind
        self.children = children
    }

    var url: URL? {
        switch kind {
        case .note(let note, _): return note.fileURL
        case .file(let file): return file.url
        default: return nil
        }
    }
    var note: Note? { if case .note(let n, _) = kind { return n }; return nil }
    var file: CollectionFile? { if case .file(let f) = kind { return f }; return nil }
    var collection: Collection? { if case .collection(let c) = kind { return c }; return nil }
    var isGroup: Bool { if case .collection = kind { return true }; return false }
    var isSelectable: Bool { url != nil }
    var isExpandable: Bool { !children.isEmpty }
}

// MARK: - Representable

struct NoteOutlineList: NSViewRepresentable {
    var roots: [NoteOutlineItem]
    /// Changes only when the *structure* (or text scale) changes, so we reload
    /// the outline only when needed (not on every unrelated SwiftUI update).
    var signature: String
    @Binding var selection: URL?
    var focusedCollectionID: Collection.ID?
    var accent: Color
    /// Multiplies the row fonts and heights with the app's text-size setting.
    var fontScale: CGFloat = 1

    var isBookmarked: (Note) -> Bool
    var onToggleBookmark: (Note) -> Void
    var onDelete: (Note) -> Void
    var onOpenInNewWindow: (Note) -> Void
    var onCloseCollection: (Collection) -> Void
    var onFocusCollection: (Collection) -> Void

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

        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu

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
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var parent: NoteOutlineList
        weak var outlineView: NSOutlineView?
        var accentColor: NSColor
        var focusedCollectionID: Collection.ID?

        private var roots: [NoteOutlineItem] = []
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
            // Default-expand any newly-seen collection group.
            for root in roots where root.isGroup && !knownGroupIDs.contains(root.id) {
                knownGroupIDs.insert(root.id)
                expandedIDs.insert(root.id)
            }
            guard signature != lastSignature else {
                self.roots = roots            // keep references fresh for actions
                return
            }
            lastSignature = signature
            self.roots = roots
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
            guard let url, let item = item(forURL: url, in: roots) else {
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

        private func item(forURL url: URL, in items: [NoteOutlineItem]) -> NoteOutlineItem? {
            for node in items {
                if node.url == url { return node }
                if let found = item(forURL: url, in: node.children) { return found }
            }
            return nil
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

        private func groupCell(_ collection: Collection) -> NSView {
            let container = NSTableCellView()
            let icon = symbolIcon("books.vertical")
            let name = label(collection.name, font: .systemFont(ofSize: 11 * parent.fontScale,
                weight: collection.id == focusedCollectionID ? .semibold : .regular), color: .secondaryLabelColor)

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

            if collection.git.status.isRepository {
                let dot = NSView()
                dot.wantsLayer = true
                dot.layer?.backgroundColor = (collection.git.status.isClean ? NSColor.tertiaryLabelColor : NSColor.systemOrange).cgColor
                dot.layer?.cornerRadius = 3
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
            let subtitleText = snippet ?? Self.dateFormatter.string(from: note.lastModified)
            let subtitle = label(subtitleText, font: .systemFont(ofSize: 11 * parent.fontScale), color: .secondaryLabelColor)
            subtitle.lineBreakMode = .byTruncatingTail
            let stack = NSStackView(views: [title, subtitle])
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

        private static let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            return f
        }()

        // MARK: Actions

        @objc private func closeClicked(_ sender: NSButton) {
            guard let outline = outlineView else { return }
            let row = outline.row(for: sender)
            guard row >= 0, let node = outline.item(atRow: row) as? NoteOutlineItem,
                  let collection = node.collection else { return }
            parent.onCloseCollection(collection)
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline = outlineView, outline.clickedRow >= 0,
                  let node = outline.item(atRow: outline.clickedRow) as? NoteOutlineItem else { return }

            if let note = node.note {
                let on = parent.isBookmarked(note)
                addItem(menu, on ? "Remove Bookmark" : "Add Bookmark") { self.parent.onToggleBookmark(note) }
                addItem(menu, "Open in New Window") { self.parent.onOpenInNewWindow(note) }
                menu.addItem(.separator())
                addItem(menu, "Move to Trash") { self.parent.onDelete(note) }
            } else if let file = node.file {
                addItem(menu, "Open in Default App") { NSWorkspace.shared.open(file.url) }
                addItem(menu, "Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
            } else if let collection = node.collection {
                addItem(menu, "Focus Collection") { self.parent.onFocusCollection(collection) }
                addItem(menu, "Close Collection") { self.parent.onCloseCollection(collection) }
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
#endif
