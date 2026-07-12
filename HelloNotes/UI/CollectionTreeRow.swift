//
//  CollectionTreeRow.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(macOS)
import SwiftUI
import AppKit

/// One row of the folder tree — recursively renders folders (as disclosure
/// groups), notes, and attachment files (as selectable leaves). Selection is
/// drawn with an accent-tinted background (not the system-blue List highlight)
/// so it follows the app accent.
struct CollectionTreeRow: View {
    let node: CollectionTreeNode
    /// The currently selected item's URL (a note or attachment).
    var selection: URL?
    /// The accent colour used for the selected-row background.
    var accent: Color
    var onSelect: (URL) -> Void
    let onDelete: (Note) -> Void
    let onOpenInNewWindow: (Note) -> Void
    let isBookmarked: (Note) -> Bool
    let onToggleBookmark: (Note) -> Void

    var body: some View {
        if let file = node.file {
            fileRow(file)
        } else if let note = node.note {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title)
                    .font(.headline)
                Text(note.lastModified, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture { onSelect(note.id) }
            .accentSelectionRow(isSelected: selection == note.id, accent: accent)
            .contextMenu {
                let on = isBookmarked(note)
                Button {
                    onToggleBookmark(note)
                } label: {
                    Label(on ? "Remove Bookmark" : "Add Bookmark",
                          systemImage: on ? "bookmark.slash" : "bookmark")
                }
                Button {
                    onOpenInNewWindow(note)
                } label: {
                    Label("Open in New Window", systemImage: "macwindow.badge.plus")
                }
                Divider()
                Button(role: .destructive) {
                    onDelete(note)
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
            }
        } else {
            DisclosureGroup {
                ForEach(node.children ?? []) { child in
                    CollectionTreeRow(node: child, selection: selection, accent: accent, onSelect: onSelect,
                                 onDelete: onDelete, onOpenInNewWindow: onOpenInNewWindow,
                                 isBookmarked: isBookmarked, onToggleBookmark: onToggleBookmark)
                }
            } label: {
                Label(node.name, systemImage: "folder")
                    .font(.subheadline)
            }
        }
    }

    /// An attachment file leaf (PDF, image, CSV, …). Selecting it opens the
    /// in-app viewer; the context menu offers external open / reveal.
    private func fileRow(_ file: CollectionFile) -> some View {
        Label(file.name, systemImage: file.kind.symbol)
            .font(.subheadline)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture { onSelect(file.url) }
            .accentSelectionRow(isSelected: selection == file.url, accent: accent)
            .contextMenu {
                Button {
                    NSWorkspace.shared.open(file.url)
                } label: { Label("Open in Default App", systemImage: "arrow.up.forward.app") }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                } label: { Label("Reveal in Finder", systemImage: "folder") }
            }
    }
}

extension View {
    /// Draw a list row's selected state as an accent-tinted rounded background,
    /// replacing the system-blue List highlight so selection follows the app
    /// accent.
    func accentSelectionRow(isSelected: Bool, accent: Color) -> some View {
        listRowBackground(
            RoundedRectangle(cornerRadius: 6)
                .fill(accent.opacity(isSelected ? 0.28 : 0))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
        )
    }
}
#endif
