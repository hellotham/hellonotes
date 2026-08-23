//
//  AdaptiveShell.swift
//  HelloNotes
//
//  Part 4 of docs/layout-architecture.md as a container: it decides the
//  arrangement from the scene's shape and places four slots into it. It knows
//  nothing about notes, collections or editors — which is what lets the whole
//  contract be asserted in HelloNotesTests without an app.
//
//  Native where native delivers the contract: the wide shells are a real
//  `NavigationSplitView` plus a real `.inspector`, so draggable and collapsible
//  columns, the sidebar toggle, and sidebar material all come from the system
//  (decisions 4 and 12). Custom layout only where the system has no equivalent:
//  the top band of a tall shell, and the compact bottom chrome.
//

import SwiftUI
import MarkdownEditor

struct AdaptiveShell<Sidebar: View, Pane: View,
                     Inspector: View, Compact: View>: View {
    /// Whether the inspector rail is showing. Bound so a toolbar item and the
    /// View menu can toggle it, and so it can be remembered (decision 10).
    @Binding var inspectorPresented: Bool
    /// Column visibility for the wide shells, so the sidebar toggle works.
    @Binding var columnVisibility: NavigationSplitViewVisibility

    /// Touch sizing. Passed in rather than sniffed, so a test can drive it.
    var prefersTouch: Bool = false

    /// Collections, their folders, and the pinned Recents/Bookmarks sections —
    /// one tree, one column, and **the only collapsible panel** (D2/D3).
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var pane: () -> Pane
    @ViewBuilder var inspector: () -> Inspector
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
                paneWidth: Self.estimatedPaneWidth(kind: kind, width: geo.size.width),
                prefersTouch: prefersTouch
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
            columnShell(kind)
        }
    }

    // MARK: - Wide / two: the native three-column shell plus an inspector

    private func columnShell(_ kind: ShellKind) -> some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar()
                .navigationSplitViewColumnWidth(min: ShellMetrics.sidebarFloor,
                                                ideal: ShellMetrics.sidebarIdeal,
                                                max: ShellMetrics.sidebarCap)
        } detail: {
            // The inspector is a **sibling of the editor**, not `.inspector()`.
            //
            // `.inspector()` forces a `»` chevron into the toolbar that cannot
            // be suppressed, and the chevron then swallows toolbar items when
            // the band gets tight — which is where "three inspector toggles,
            // one hidden under »" came from. An `HStack` sibling has no chrome
            // of its own, so the five tab toggles in the band are the panel's
            // only affordance (D6/D7). Proven in finvestlens `Views.swift:1293`
            // and in `scratchpad/ChromeLab --design 10`.
            HStack(spacing: 0) {
                EditorPaneContainer { pane() }
                if kind == .wideInspector && inspectorPresented {
                    Divider()
                    inspector()
                        .frame(minWidth: ShellMetrics.inspectorFloor,
                               idealWidth: ShellMetrics.inspectorIdeal,
                               maxWidth: ShellMetrics.inspectorCap)
                }
            }
        }
    }

    // MARK: - Tall: navigation bands across the top

    /// An iPad in portrait is 834pt wide. By width alone that buys a second
    /// column and a 554pt measure. Banding instead gives the editor the *full*
    /// measure and spends the height that portrait has spare.
    private func tallShell(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            // The band needs its own navigation context. In the column shells
            // `NavigationSplitView` provides one per column; here the shell
            // must, or `.navigationTitle` and every toolbar button silently
            // disappears. One cell now rather than two: collections and folders
            // are a single tree (D2), so there is nothing to sit beside.
            NavigationStack { sidebar() }
                .frame(height: ShellMetrics.bandIdeal)
                .accessibilityIdentifier("shell.band")

            Divider()

            HStack(spacing: 0) {
                EditorPaneContainer { NavigationStack { pane() } }
                // A tall window that is also wide keeps its right rail.
                if width >= ShellMetrics.tallRailMin && inspectorPresented {
                    Divider()
                    inspector()
                        .frame(width: ShellMetrics.inspectorIdeal)
                }
            }
        }
    }

    // MARK: - Pane width

    /// What the pane will be *before* the user drags a divider. Only used to
    /// seed the environment; `EditorPaneContainer` measures the truth and
    /// refines it, so a dragged column still gets the right format-bar rule.
    static func estimatedPaneWidth(kind: ShellKind, width: CGFloat) -> CGFloat {
        let divider: CGFloat = 1
        switch kind {
        case .compact:
            return width
        case .tall:
            return width >= ShellMetrics.tallRailMin
                ? width - ShellMetrics.inspectorIdeal - divider
                : width
        case .two, .wide:
            return width - ShellMetrics.sidebarIdeal - divider
        case .wideInspector:
            return width - ShellMetrics.sidebarIdeal - ShellMetrics.inspectorIdeal - 2 * divider
        }
    }
}

// MARK: - The pane

/// Measures the pane it actually got and republishes it, so everything inside
/// (the format-bar rule, the reading measure, the pane ceiling) reads one
/// number that matches reality — including after a divider drag, which the
/// shell's own estimate cannot see.
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
