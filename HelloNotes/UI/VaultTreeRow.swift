//
//  VaultTreeRow.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(macOS)
import SwiftUI

/// One row of the folder tree — recursively renders folders (as disclosure
/// groups) and notes (as selectable leaves tagged by their note id).
struct VaultTreeRow: View {
    let node: VaultTreeNode
    let onDelete: (Note) -> Void
    let onOpenInNewWindow: (Note) -> Void
    let isBookmarked: (Note) -> Bool
    let onToggleBookmark: (Note) -> Void

    var body: some View {
        if let note = node.note {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title)
                    .font(.headline)
                Text(note.lastModified, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .tag(note.id)
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
                    VaultTreeRow(node: child, onDelete: onDelete, onOpenInNewWindow: onOpenInNewWindow,
                                 isBookmarked: isBookmarked, onToggleBookmark: onToggleBookmark)
                }
            } label: {
                Label(node.name, systemImage: "folder")
                    .font(.subheadline)
            }
        }
    }
}
#endif
