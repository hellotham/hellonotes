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

struct AdaptiveShell<LibraryRail: View, NoteList: View, Pane: View,
                     Inspector: View, Compact: View>: View {
    /// Whether the inspector rail is showing. Bound so a toolbar item and the
    /// View menu can toggle it, and so it can be remembered (decision 10).
    @Binding var inspectorPresented: Bool
    /// Column visibility for the wide shells, so the sidebar toggle works.
    @Binding var columnVisibility: NavigationSplitViewVisibility

    /// Touch sizing. Passed in rather than sniffed, so a test can drive it.
    var prefersTouch: Bool = false

    @ViewBuilder var libraryRail: () -> LibraryRail
    @ViewBuilder var noteList: () -> NoteList
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

    @ViewBuilder
    private func columnShell(_ kind: ShellKind) -> some View {
        #if os(macOS)
        macColumnShell(kind)
        #else
        // iPadOS keeps the real `NavigationSplitView`: the inset sidebar is the
        // platform's own look there, not a defect, and it brings the sidebar
        // toggle and column behaviour a touch UI expects.
        NavigationSplitView(columnVisibility: kind.libraryIsOverlay
                            ? .constant(.doubleColumn) : $columnVisibility) {
            libraryRail()
                .navigationSplitViewColumnWidth(min: ShellMetrics.libraryFloor,
                                                ideal: ShellMetrics.libraryIdeal,
                                                max: ShellMetrics.libraryCap)
        } content: {
            noteList()
                .navigationSplitViewColumnWidth(min: ShellMetrics.listFloor,
                                                ideal: ShellMetrics.listIdeal,
                                                max: ShellMetrics.listCap)
        } detail: {
            EditorPaneContainer { pane() }
                .inspector(isPresented: kind == .wideInspector
                           ? $inspectorPresented : .constant(false)) {
                    inspector()
                        .inspectorColumnWidth(min: ShellMetrics.inspectorFloor,
                                              ideal: ShellMetrics.inspectorIdeal,
                                              max: ShellMetrics.inspectorCap)
                }
        }
        #endif
    }

    #if os(macOS)
    private func macColumnShell(_ kind: ShellKind) -> some View {
        // An `HSplitView` of ordinary views, not a `NavigationSplitView`.
        //
        // On macOS 26 the first column of a `NavigationSplitView` is drawn as an
        // **inset floating capsule** — the new sidebar appearance. At 64pt that
        // capsule is a rounded pill running the whole window height, straight
        // through the titlebar row, which is what "the collection vertical bar"
        // is. It is not the `List` (plain and sidebar styles render the same
        // pill) and it is not the column's contents: moving the rail out of the
        // slot simply moved the capsule onto the note list instead. It belongs
        // to the slot.
        //
        // `HSplitView` has no sidebar slot, so no column gets that treatment;
        // each is an ordinary view drawing on the window's own background, and
        // columns stay draggable (decision 4). Each carries its own
        // `NavigationStack` because `.searchable`, `.navigationTitle` and the
        // column toolbars need a navigation context — the same thing the tall
        // shell already does for its band cells.
        HSplitView {
            if kind.hasLibraryRail {
                libraryRail()
                    .frame(width: ShellMetrics.railWidth)
            }

            NavigationStack { noteList() }
                .frame(minWidth: ShellMetrics.listFloor,
                       idealWidth: ShellMetrics.listIdeal,
                       maxWidth: ShellMetrics.listCap)

            NavigationStack { EditorPaneContainer { pane() } }
                .frame(minWidth: ShellMetrics.editorFloor, maxWidth: .infinity)

            if kind == .wideInspector && inspectorPresented {
                inspector()
                    .frame(minWidth: ShellMetrics.inspectorFloor,
                           idealWidth: ShellMetrics.inspectorIdeal,
                           maxWidth: ShellMetrics.inspectorCap)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    #endif

    // Decision 12 — below 960pt the library rail vanishes — is now expressed
    // where the rail is built (`kind.hasLibraryRail` above) rather than through
    // a split view's column visibility, because there is no longer a split view
    // to hide a column of. `columnVisibility` stays in the API so the View menu
    // and the window's sidebar toggle keep a binding to talk to.

    // MARK: - Tall: navigation bands across the top

    /// An iPad in portrait is 834pt wide. By width alone that buys a second
    /// column and a 554pt measure. Banding instead gives the editor the *full*
    /// measure and spends the height that portrait has spare.
    private func tallShell(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Each band cell needs its own navigation context. In the
                // column shells `NavigationSplitView` provides one per column;
                // here the shell must, or `.searchable`, `.navigationTitle`
                // and every column toolbar button silently disappear.
                NavigationStack { libraryRail() }
                    .frame(width: ShellMetrics.libraryIdeal)
                Divider()
                NavigationStack { noteList() }
            }
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
        case .two:
            return width - ShellMetrics.listIdeal - divider
        case .wide:
            return width - ShellMetrics.libraryIdeal - ShellMetrics.listIdeal - 2 * divider
        case .wideInspector:
            return width - ShellMetrics.libraryIdeal - ShellMetrics.listIdeal
                 - ShellMetrics.inspectorIdeal - 3 * divider
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refined(to width: CGFloat) -> ShellContext {
        var context = shell
        context.paneWidth = width
        return context
    }
}
