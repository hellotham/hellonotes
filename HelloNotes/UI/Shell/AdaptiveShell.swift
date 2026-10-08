//
//  AdaptiveShell.swift
//  HelloNotes
//
//  Part 4 of docs/layout-architecture.md as a container: it decides the
//  arrangement from the scene's shape and places four slots into it. It knows
//  nothing about notes, collections or editors — which is what lets the whole
//  contract be asserted in HelloNotesTests without an app.
//
//  **Drawn by the app, not the OS.** The column shells were a
//  `NavigationSplitView` and the tall shell wrapped its halves in
//  `NavigationStack`s — and each of those is drawn by the platform, to the
//  platform's own metrics: a floating glass sidebar and a 52pt unified toolbar
//  on macOS, a full-height sidebar and a 50pt navigation bar on iPadOS. Two
//  builds of the same code were two different pictures. Every column here is
//  an `HStack`/`VStack` of the app's own views, sized by `ShellMetrics` and
//  drawn with `Chrome`, so a Mac window and an iPad of the same size are the
//  same pixels. The sidebar collapses and resizes through the app's own
//  toggle and `ResizableDivider`, the same way the panel always did.
//

import SwiftUI
import MarkdownEditor

struct AdaptiveShell<Sidebar: View, Pane: View,
                     Inspector: View, Compact: View>: View {
    /// Whether the inspector rail is showing. Bound so a toolbar item and the
    /// View menu can toggle it, and so it can be remembered (decision 10).
    @Binding var inspectorPresented: Bool

    /// Whether the tall shell's navigation band is hidden — the app's own
    /// toggle, as the column shells' sidebar is (`columnVisibility`, the same
    /// stored value in the column shells' form). The band held a fixed 320pt
    /// of every portrait iPad screen with no way to reclaim it before there
    /// was one — the one shell where the note being read is the smaller half.
    @Binding var bandHidden: Bool
    /// Whether the column shells show the sidebar — `.detailOnly` hides it.
    /// The type is kept from the split-view days so every command that already
    /// reads and writes it still does.
    @Binding var columnVisibility: NavigationSplitViewVisibility

    /// Collections, their folders, and the pinned Recents/Bookmarks sections —
    /// one tree, one column, and **the only collapsible panel** (D2/D3).
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var pane: () -> Pane
    @ViewBuilder var inspector: () -> Inspector

    /// The panel's width, as dragged. Stored, because it is the person's
    /// choice; clamped at use, so a narrower window borrows the width back
    /// rather than forgetting it (`ResizableDivider`).
    @AppStorage("sidePanelWidth") private var panelWidth = Double(ShellMetrics.panelIdeal)
    /// The sidebar's width, as dragged — the person's, like the panel's.
    @AppStorage("sidebarWidth") private var sidebarWidth = Double(ShellMetrics.sidebarIdeal)
    /// The whole compact presentation, supplied by the caller.
    ///
    /// Compact is not the wide shell with different furniture — it is a
    /// different information architecture: a bottom tab bar of *places*, with
    /// the open note persisting above it like a now-playing track (decision 6).
    /// Rails and a list column have no meaning there, so the shell hands off
    /// rather than pretending to arrange something it cannot.
    @ViewBuilder var compact: () -> Compact

    var body: some View {
        GeometryReader { geo in
            let kind = shellKind(width: geo.size.width, height: geo.size.height)
            let context = ShellContext(
                kind: kind,
                size: geo.size,
                paneWidth: Self.estimatedPaneWidth(kind: kind, width: geo.size.width)
            )

            arrangement(kind, context: context)
                // S2/S3 — the shell fills its scene and never exceeds it.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.shell, context)
        }
    }

    @ViewBuilder
    private func arrangement(_ kind: ShellKind, context: ShellContext) -> some View {
        switch kind {
        case .compact:
            compact()
        case .tall:
            tallShell(width: context.size.width)
        case .two, .wide, .wideInspector:
            columnShell(kind, width: context.size.width)
        }
    }

    // MARK: - Wide / two: sidebar, editor, panel

    private func columnShell(_ kind: ShellKind, width: CGFloat) -> some View {
        let showsSidebar = columnVisibility != .detailOnly
        let sidebarShare = showsSidebar ? clampedSidebarWidth(in: width) + 1 : 0
        return HStack(spacing: 0) {
            if showsSidebar {
                sidebar()
                    .frame(width: clampedSidebarWidth(in: width))
                ResizableDivider(width: $sidebarWidth, range: sidebarRange(in: width), edge: .leading,
                                 label: "Sidebar width")
            }
            // The panel is a **sibling of the editor**, not `.inspector()`,
            // which forces a chevron into the toolbar that cannot be
            // suppressed and swallows toolbar items when the bar gets tight.
            EditorPaneContainer { pane() }
            if inspectorPresented, ShellMetrics.hasPanelColumn(kind: kind, width: width) {
                let available = width - sidebarShare
                ResizableDivider(width: $panelWidth, range: panelRange(available: available))
                inspector()
                    .frame(width: panelWidth(in: available))
            }
        }
    }

    // MARK: - Tall: navigation bands across the top

    /// An iPad in portrait is 834pt wide. By width alone that buys a second
    /// column and a 554pt measure. Banding instead gives the editor the *full*
    /// measure and spends the height that portrait has spare.
    private func tallShell(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            // No `NavigationStack`: it existed to give the band a navigation
            // bar for its title and toolbar, which the OS drew differently on
            // each platform. The band draws its own header now.
            if !bandHidden {
                sidebar()
                    .frame(height: ShellMetrics.bandIdeal)
                    .accessibilityIdentifier("shell.band")
                Rectangle().fill(Chrome.Colour.separator).frame(height: 1)
            }

            HStack(spacing: 0) {
                EditorPaneContainer { pane() }
                // The rail is a column wherever the editor keeps its floor.
                if inspectorPresented, ShellMetrics.hasPanelColumn(kind: .tall, width: width) {
                    ResizableDivider(width: $panelWidth, range: panelRange(available: width))
                    inspector()
                        .frame(width: panelWidth(in: width))
                }
            }
        }
    }

    // MARK: - Sidebar width

    /// Never below its floor or above its cap, and never so wide the editor
    /// loses its own floor.
    private func sidebarRange(in width: CGFloat) -> ClosedRange<CGFloat> {
        let upper = min(ShellMetrics.sidebarCap,
                        max(ShellMetrics.sidebarFloor, width - ShellMetrics.editorFloor))
        return ShellMetrics.sidebarFloor...upper
    }

    private func clampedSidebarWidth(in width: CGFloat) -> CGFloat {
        let range = sidebarRange(in: width)
        return min(max(CGFloat(sidebarWidth), range.lowerBound), range.upperBound)
    }

    // MARK: - Panel width

    /// What the panel may be, here: never below its floor, never so wide that
    /// the editor drops below its own.
    private func panelRange(available: CGFloat) -> ClosedRange<CGFloat> {
        let upper = max(ShellMetrics.panelFloor, available - ShellMetrics.editorFloor)
        return ShellMetrics.panelFloor...upper
    }

    /// The stored width, clamped to what this canvas can give it.
    private func panelWidth(in available: CGFloat) -> CGFloat {
        let range = panelRange(available: available)
        return min(max(CGFloat(panelWidth), range.lowerBound), range.upperBound)
    }

    // MARK: - Pane width

    /// What the pane will be *before* the user drags a divider. Only used to
    /// seed the environment; `EditorPaneContainer` measures the truth and
    /// refines it, so a dragged column still gets the right reading measure.
    static func estimatedPaneWidth(kind: ShellKind, width: CGFloat) -> CGFloat {
        let divider: CGFloat = 1
        switch kind {
        case .compact:
            return width
        case .tall:
            return width >= ShellMetrics.tallRailMin
                ? width - ShellMetrics.panelIdeal - divider
                : width
        case .two, .wide:
            return width - ShellMetrics.sidebarIdeal - divider
        case .wideInspector:
            return width - ShellMetrics.sidebarIdeal - ShellMetrics.panelIdeal - 2 * divider
        }
    }
}

// MARK: - The pane

/// Measures the pane it actually got and republishes it, so everything inside
/// — the reading measure — reads one number that matches reality, including
/// after a divider drag, which the shell's own estimate cannot see.
///
/// Deliberately has **no** `minWidth: editorFloor`: the floor is a design
/// target enforced by the declared window minimum, and baking it in here makes
/// the editor overflow a 250pt Stage Manager tile and clip its own text.
/// Decision 9 is to degrade below the floor, never to spill outside the scene.
struct EditorPaneContainer<Content: View>: View {
    @Environment(\.shell) private var shell
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geo in
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.shell, refined(to: geo.size.width))
                .onAppear { probe(geo) }
                .onChange(of: geo.size) { _, _ in probe(geo) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// `paneWidth` over-reports on macOS — at a 1100pt window with a 280pt
    /// sidebar it publishes 1100 — and subtracting `safeAreaInsets` is *not*
    /// the correction: that lands on 524. Until the numbers are understood the
    /// published value stays what it has always been, and this records what
    /// the container is actually being told, so the answer comes from a
    /// measurement rather than from arithmetic that looked plausible.
    private func probe(_ geo: GeometryProxy) {
        EditorProbe.log("pane container size=\(geo.size) "
                        + "safeArea=(l:\(geo.safeAreaInsets.leading) "
                        + "t:\(geo.safeAreaInsets.top) "
                        + "r:\(geo.safeAreaInsets.trailing) "
                        + "b:\(geo.safeAreaInsets.bottom))")
    }

    private func refined(to width: CGFloat) -> ShellContext {
        var context = shell
        context.paneWidth = width
        return context
    }
}
