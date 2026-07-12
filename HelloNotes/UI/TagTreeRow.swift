//
//  TagTreeRow.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(macOS)
import SwiftUI

/// One row of the sidebar tag tree. Leaf tags are a plain clickable label;
/// tags with nested children render as a disclosure group whose label is still
/// clickable to filter by that parent (which matches all descendants).
struct TagTreeRow: View {
    let node: TagNode
    let selectedTag: String?
    let onSelect: (String) -> Void

    var body: some View {
        if node.children.isEmpty {
            tagButton
        } else {
            DisclosureGroup {
                ForEach(node.children) { child in
                    TagTreeRow(node: child, selectedTag: selectedTag, onSelect: onSelect)
                }
            } label: {
                tagButton
            }
        }
    }

    private var tagButton: some View {
        Button {
            onSelect(node.fullPath)
        } label: {
            Label("#\(node.name)", systemImage: "number")
                .foregroundStyle(selectedTag == node.fullPath ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .fontWeight(selectedTag == node.fullPath ? .semibold : .regular)
        }
        .buttonStyle(.plain)
    }
}
#endif
