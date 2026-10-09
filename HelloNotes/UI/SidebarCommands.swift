//
//  SidebarCommands.swift
//  HelloNotes
//
//  The collection's commands, in the sidebar that holds the collection: its
//  tools above the tree (the Mind Map of its links, the Assistant, Ask Your
//  Library, its Git) and, below it, making and opening collections and folders.
//
//  The sidebar used to hold no commands at all — "a hidden command is an
//  unreachable command" — and the one exception was a `+` menu in its header.
//  So the collection's commands were in the bar over the *editor*, in a menu
//  shared with the notes' commands, and some were in the bottom bar as well:
//  the same thing in three places, none of them where the collection was. They
//  are here now, named, one row each. The sidebar's own toggle is always in the
//  bar, and every one of them is in the menu bar too.
//
//  One definition, drawn two ways: rows in the sidebar column, and — in the
//  band, the tall shell's left region, which is wide and only about 320pt
//  high — a strip of the same commands across its top. The rows read which
//  from the environment, so the shell writes each command once.
//

import SwiftUI

/// How the sidebar's commands are drawn where they are.
enum SidebarCommandLayout {
    /// One row each, the sidebar's own rows: a glyph and a name.
    case rows
    /// A strip of named buttons across the band.
    case strip
}

extension EnvironmentValues {
    @Entry var sidebarCommandLayout: SidebarCommandLayout = .rows
}

/// A command in the sidebar: a glyph and its name, and what it does.
struct SidebarCommandRow: View {
    let title: String
    let systemImage: String
    /// A word after the name — Git's branch.
    var detail: String? = nil
    /// A dot after the name — Git's uncommitted changes.
    var showsDot: Bool = false
    var accent: Color = .accentColor
    let action: () -> Void

    init(_ title: String, systemImage: String, detail: String? = nil, showsDot: Bool = false,
         accent: Color = .accentColor, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.detail = detail
        self.showsDot = showsDot
        self.accent = accent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            SidebarCommandLabel(title: title, systemImage: systemImage, detail: detail,
                                showsDot: showsDot, accent: accent)
        }
        .buttonStyle(ChromePlainStyle())
        .accessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
    }
}

/// A command that opens a menu of choices — New Collection, Open Collection —
/// drawn like the rows beside it, with a chevron saying it opens a menu.
struct SidebarCommandMenuRow<Content: View>: View {
    let title: String
    let systemImage: String
    var accent: Color = .accentColor
    @ViewBuilder let content: () -> Content

    init(_ title: String, systemImage: String, accent: Color = .accentColor,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.accent = accent
        self.content = content
    }

    var body: some View {
        Menu(content: content) {
            SidebarCommandLabel(title: title, systemImage: systemImage, opensMenu: true, accent: accent)
        }
        .menuStyle(.button)
        .buttonStyle(ChromePlainStyle())
        .menuIndicator(.hidden)
        .accessibilityLabel(title)
    }
}

/// The look both kinds of command share, as a row or as a strip button.
private struct SidebarCommandLabel: View {
    let title: String
    let systemImage: String
    var detail: String? = nil
    var showsDot: Bool = false
    var opensMenu: Bool = false
    var accent: Color

    @Environment(\.sidebarCommandLayout) private var layout
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.chromeScale) private var scale
    @State private var hovering = false

    var body: some View {
        switch layout {
        case .rows:
            ChromeRowFrame(height: Chrome.Metric.rowLeaf, accent: accent) {
                content
                Spacer(minLength: 0)
            }
            .opacity(isEnabled ? 1 : 0.4)
        case .strip:
            content
                .padding(.horizontal, 8)
                .frame(height: Chrome.Metric.control)
                .background(hovering ? Chrome.Colour.hover : Color.clear,
                            in: RoundedRectangle(cornerRadius: Chrome.Metric.radius))
                .contentShape(.rect)
                .onHover { hovering = $0 }
                .opacity(isEnabled ? 1 : 0.4)
        }
    }

    private var content: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 12 * scale))
                .foregroundStyle(accent)
                .frame(width: 16)
            ChromeLine(title, size: 12 * scale, colour: Chrome.Colour.label)
            if let detail {
                ChromeLine(detail, size: 11 * scale, colour: Chrome.Colour.secondaryLabel)
            }
            if showsDot {
                Circle().fill(Chrome.Colour.orange).frame(width: 6, height: 6)
            }
            if opensMenu {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8 * scale, weight: .semibold))
                    .foregroundStyle(Chrome.Colour.tertiaryLabel)
            }
        }
    }
}

/// The sidebar's commands as rows, a group of them with a little room around.
struct SidebarCommandSection<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.vertical, 4)
        .environment(\.sidebarCommandLayout, .rows)
    }
}

/// The band's strip: the same commands, side by side, scrolling when the band
/// is narrower than they are.
struct SidebarCommandStrip<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                content()
            }
            .padding(.horizontal, Chrome.Metric.barPadding)
        }
        .frame(height: Chrome.Metric.barHeight)
        .environment(\.sidebarCommandLayout, .strip)
    }
}
