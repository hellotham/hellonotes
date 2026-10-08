//
//  ChromeRows.swift
//  HelloNotes
//
//  Created by Chris Tham on 23/9/2026.
//
//  The rows every list in the shell is built from — the sidebar tree, and the
//  band's two panes — drawn by the app at the Mac's metrics, on both platforms.
//
//  They were three `List`s: an `NSOutlineView` on the Mac, and on iOS a SwiftUI
//  `List` of `DisclosureGroup`s for the tree and two more for the band. A list
//  is the platform's drawing — its insets, its disclosure triangle, its
//  selection colour, its row height, its `.headline` — so the same items were
//  two different pictures. These are the `NSOutlineView`'s own numbers (13pt
//  semibold over 11pt for a note, 12pt for a folder, 14pt indent, the accent at
//  30% in a rounded rectangle inset 5×1) in views that draw the same on both.
//

import SwiftUI

// MARK: - Text size

/// The app's Text Size setting, as it applies to rows. The Mac's outline
/// scaled its rows by it and the iOS list ignored it — the same setting did
/// something on one platform only.
private struct ChromeScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }

extension EnvironmentValues {
    var chromeScale: CGFloat {
        get { self[ChromeScaleKey.self] }
        set { self[ChromeScaleKey.self] = newValue }
    }
}

/// A token font at the current row scale.
private func scaled(_ size: CGFloat, _ weight: Font.Weight = .regular, _ scale: CGFloat) -> Font {
    .system(size: size * scale, weight: weight)
}

// MARK: - The row's frame

/// A row's height, indent, selection and hover — the parts every row shares.
struct ChromeRowFrame<Content: View>: View {
    var height: CGFloat
    var depth: Int = 0
    var isSelected: Bool = false
    var accent: Color
    @ViewBuilder var content: () -> Content

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            content()
        }
        .padding(.leading, 8 + CGFloat(depth) * Chrome.Metric.indent)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Chrome.Metric.radius)
                .fill(isSelected ? Chrome.selection(accent)
                                 : hovering ? Chrome.Colour.hover : Color.clear)
                .padding(.horizontal, Chrome.Metric.selectionInsetX)
                .padding(.vertical, Chrome.Metric.selectionInsetY))
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}

/// The disclosure triangle: a 9pt chevron in a 14pt slot, turned when open.
/// A slot is always reserved, so a leaf lines up with its expandable siblings.
struct ChromeDisclosure: View {
    var isExpandable: Bool
    var isExpanded: Bool
    var toggle: () -> Void

    var body: some View {
        Group {
            if isExpandable {
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Chrome.Colour.tertiaryLabel)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: Chrome.Metric.indent, height: Chrome.Metric.indent)
                        .contentShape(.rect.inset(by: -8))
                }
                .buttonStyle(ChromePlainStyle())
                .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
            } else {
                Color.clear.frame(width: Chrome.Metric.indent, height: Chrome.Metric.indent)
            }
        }
        .padding(.trailing, 2)
    }
}

// MARK: - Row content

/// A place, folder or file: a 12pt glyph and a 12pt name.
struct ChromeLabelRow: View {
    var systemImage: String
    var title: String
    /// 12pt for a folder or file; a place is 11pt, as the Mac drew it.
    var titleSize: CGFloat = 12
    var titleColour: Color = Chrome.Colour.label

    @Environment(\.chromeScale) private var scale

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(scaled(12, .regular, scale))
                .foregroundStyle(Chrome.Colour.secondaryLabel)
                .frame(width: 16)
            ChromeLine(title, size: titleSize * scale, colour: titleColour)
        }
    }
}

/// A collection heading its group: the five things `CollectionRowContent`
/// decides, at the Mac's 11pt.
struct ChromeCollectionRow: View {
    var content: CollectionRowContent

    @Environment(\.chromeScale) private var scale

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: content.symbol)
                .font(scaled(12, .regular, scale))
                .foregroundStyle(content.isDimmed ? Chrome.Colour.orange : Chrome.Colour.secondaryLabel)
                .frame(width: 16)
            ChromeLine(content.name, size: 11 * scale, weight: content.isFocused ? .semibold : .regular,
                       colour: content.isDimmed ? Chrome.Colour.tertiaryLabel : Chrome.Colour.secondaryLabel)
            if content.isScanning {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel(content.scanningLabel)
            }
            if let clean = content.gitIsClean {
                Circle()
                    .fill(clean ? Chrome.Colour.tertiaryLabel : Chrome.Colour.orange)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel(content.gitLabel ?? "")
            }
        }
        .help(content.help ?? "")
    }
}

/// A note: a 13pt semibold title over an 11pt line — the snippet a search
/// found, or the date. `wide` puts the date on the title's line instead, for
/// a pane with the room (the band's right half).
struct ChromeNoteRow: View {
    var content: NoteRowContent
    var wide: Bool = false

    @Environment(\.chromeScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                ChromeLine(content.title, size: 13 * scale, weight: .semibold)
                if content.isOnlineOnly {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(scaled(11, .regular, scale))
                        .foregroundStyle(Chrome.Colour.tertiaryLabel)
                        .accessibilityLabel(NoteRowContent.onlineOnlyLabel)
                }
                if wide {
                    Spacer(minLength: 8)
                    ChromeLine(content.date, size: 11 * scale, colour: Chrome.Colour.secondaryLabel,
                               monospacedDigits: true)
                        .layoutPriority(1)
                }
            }
            if let second = wide ? content.snippet : (content.snippet ?? content.date) {
                ChromeLine(second, size: 11 * scale, colour: Chrome.Colour.secondaryLabel)
            }
        }
    }
}

// MARK: - Flattening

/// One visible row of a tree: the item, how deep it sits, and whether it can
/// open. Lists here are drawn flat — a `LazyVStack` over the rows that are
/// showing — which is what makes the metrics exact and the arrow keys simple.
struct ChromeTreeLine: Identifiable {
    let item: NoteOutlineItem
    let depth: Int
    let isExpandable: Bool
    let isExpanded: Bool
    var id: String { item.id }
}

enum ChromeTree {
    /// The rows showing, in order. Collections are open unless folded away
    /// (`collapsed`); places and folders are closed unless opened
    /// (`expanded`) — the defaults the old lists had.
    static func lines(_ roots: [NoteOutlineItem],
                      expanded: Set<String>,
                      collapsed: Set<String>,
                      include: (NoteOutlineItem) -> Bool = { _ in true }) -> [ChromeTreeLine] {
        var out: [ChromeTreeLine] = []
        func walk(_ items: [NoteOutlineItem], depth: Int) {
            for item in items where include(item) {
                let children = item.children.filter(include)
                let expandable = !children.isEmpty
                let open: Bool
                switch item.kind {
                case .collection: open = !collapsed.contains(item.id)
                default: open = expanded.contains(item.id)
                }
                out.append(ChromeTreeLine(item: item, depth: depth,
                                          isExpandable: expandable, isExpanded: expandable && open))
                if expandable && open { walk(children, depth: depth + 1) }
            }
        }
        walk(roots, depth: 0)
        return out
    }

    /// The row height for an item, at the Mac's metrics.
    static func height(_ item: NoteOutlineItem, scale: CGFloat = 1) -> CGFloat {
        switch item.kind {
        case .note: return Chrome.Metric.rowNote * scale
        case .collection: return Chrome.Metric.rowCollection * scale
        case .place, .folder, .file: return Chrome.Metric.rowLeaf * scale
        }
    }
}
