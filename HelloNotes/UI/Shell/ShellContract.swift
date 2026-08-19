//
//  ShellContract.swift
//  HelloNotes
//
//  The layout contract from docs/layout-architecture.md, as code: the sizes in
//  Part 3, the shell selection rule in Part 4, and the context both publish to
//  the views inside them.
//
//  Everything here is pure — no view state, no platform calls — so the whole
//  contract can be asserted in a test without a running app.
//

import SwiftUI

// MARK: - Part 3: component sizes

/// Every size the shell is allowed to use. A number that isn't here is a number
/// nobody decided; put it here (and in Part 3 of the design) before using it.
enum ShellMetrics {
    // Rails and columns

    /// **One sidebar**: collections and their folders in a single tree, with
    /// Recents and Bookmarks pinned above them (`docs/shell-chrome.md` D2/D4).
    ///
    /// It replaced a fixed-width collection *rail* plus a separate folder-tree
    /// column, and the reason is structural rather than aesthetic. SwiftUI hands
    /// a correctly-placed sidebar toggle to **column one only**. With the rail
    /// in that slot, the panel that actually needs collapsing — the tree, which
    /// P2 hides to get width — was column two, so its control had to be
    /// hand-placed. Every hand-placed variant failed the same way: buttons
    /// floating mid-list, three inspector toggles, a `»` chevron. Measured in
    /// `scratchpad/ChromeLab`: design 4 (three columns) produces **no toggle at
    /// all**; design 10 (this shape) produces the free one at the sidebar's own
    /// trailing edge, x≈245pt — Apple Notes' position to the point.
    ///
    /// Capped close to the ideal, not at a comfortable maximum: `NSSplitView`
    /// hands slack to whichever column can still grow, and the width belongs to
    /// the editor.
    static let sidebarFloor: CGFloat = 220
    static let sidebarIdeal: CGFloat = 280
    static let sidebarCap: CGFloat = 340

    static let inspectorFloor: CGFloat = 220
    static let inspectorIdeal: CGFloat = 280
    static let inspectorCap: CGFloat = 360

    /// The pane below which the editor is degraded but must still render
    /// (decision 9) — a design target enforced by the declared *window*
    /// minimum, never by a `minWidth` on the pane itself. Baking it into the
    /// view makes the editor overflow a 250pt Stage Manager tile and clip its
    /// own text.
    static let editorFloor: CGFloat = 320

    /// Horizontal padding inside a pane, per side.
    static let insets: CGFloat = 16

    // Chrome — definite heights (S3)
    static let formatBar: CGFloat = 36
    static let statusBar: CGFloat = 28
    static let tabBarPointer: CGFloat = 32
    static let tabBarTouch: CGFloat = 44
    static let keyboardAccessoryBar: CGFloat = 44
    static let bottomTabBar: CGFloat = 49
    static let miniStrip: CGFloat = 56

    /// The navigation band across the top of a tall shell.
    static let bandIdeal: CGFloat = 320

    /// The format bar is persistent from this pane width up (decision 3);
    /// below it, the same commands collapse into an overflow menu.
    static let formatBarMinPane: CGFloat = 560

    // MARK: Shell thresholds (Part 4)

    static let compactMax: CGFloat = 600
    static let twoMax: CGFloat = 960
    static let inspectorMin: CGFloat = 1400
    /// A tall shell keeps its right rail only if it is also reasonably wide.
    static let tallRailMin: CGFloat = 900

    /// The declared window minimum (decision 9). Below this the OS is forcing
    /// the size and the shell degrades rather than erroring.
    static let windowMinWidth: CGFloat = 860
    static let windowMinHeight: CGFloat = 480

    /// A pane may split manually up to this many ways: `min(4, pane / 320)`.
    static func maxPanes(detailWidth: CGFloat) -> Int {
        max(1, min(4, Int(detailWidth / editorFloor)))
    }
}

// MARK: - Part 4: the shell

/// Which arrangement the scene calls for. Chosen by the **axis of abundance**,
/// never by device identity — Stage Manager makes device identity meaningless,
/// so a Mac window and an iPad at the same size get the same shell.
enum ShellKind: String, Equatable, Sendable {
    /// Editor is the whole screen; navigation is a bottom tab bar.
    case compact
    /// Vertical room to spare: navigation bands across the top.
    case tall
    /// Sidebar + pane, no room for an inspector.
    case two
    /// Sidebar + pane.
    case wide
    /// Sidebar + pane + right inspector.
    case wideInspector

    /// Every non-compact shell carries the sidebar; the user collapses it.
    var hasSidebar: Bool { self != .compact }

    /// Only compact has no sidebar column at all — its navigation is the bottom
    /// tab bar, so there is something to reach for rather than nothing.
    ///
    /// Decision 12 used to retract the library below 960pt because *three*
    /// columns did not fit there. Two do: a 280pt sidebar plus the 320pt editor
    /// floor is 600pt, so at the 860pt window minimum both fit with room over.
    /// Forcing it shut would leave P2 — who works at exactly that width — with
    /// a locked toggle and no way to reach a collection.
    var sidebarIsOverlay: Bool { self == .compact }

    /// Compact is the only shell that gives the editor the whole screen.
    var editorIsScreen: Bool { self == .compact }

    /// Whether this shell can show the inspector *when the user asks for it*.
    /// Distinct from `inspectorMin`, which is about what to show by default.
    var canShowInspector: Bool { self == .wideInspector || self == .wide }
}

/// The one rule that reads both platforms.
///
/// Wide displays have horizontal room → navigation becomes side rails. Tall
/// displays have vertical room → navigation becomes a band across the top, and
/// the editor keeps the full measure beneath it. Phones have neither → the
/// editor is the whole screen.
func shellKind(width: CGFloat, height: CGFloat) -> ShellKind {
    if width < ShellMetrics.compactMax { return .compact }
    if height > width { return .tall }
    if width < ShellMetrics.twoMax { return .two }
    return width >= ShellMetrics.inspectorMin ? .wideInspector : .wide
}

// MARK: - Reading vs editing (Part 2, decision 5)

/// What the person is doing, which decides how wide their text is.
///
/// Reading gets a fixed measure, centred — line length is the whole point.
/// Editing fills the pane, left-aligned, like VS Code: the pane *is* the
/// workspace, and a fixed 80ch column stranded in 1300pt of gutter on each side
/// isn't restraint, it just looks broken.
enum TextIntent: Equatable, Sendable { case reading, editing }

/// The user's preferred reading measure, in characters.
enum ReadingWidth: String, CaseIterable, Sendable {
    case narrow, normal, wide, full
    var characters: CGFloat? {
        switch self {
        case .narrow: 60
        case .normal: 80
        case .wide: 90
        case .full: nil        // no measure — take the pane
        }
    }
    var label: String {
        switch self {
        case .narrow: "Narrow (60 characters)"
        case .normal: "Normal (80 characters)"
        case .wide: "Wide (90 characters)"
        case .full: "Full width"
        }
    }
}

/// The user's preferred editing width, as a proportion of the pane.
enum EditorWidth: String, CaseIterable, Sendable {
    case full, ninety, seventyFive, half
    var proportion: CGFloat {
        switch self {
        case .full: 1.0
        case .ninety: 0.9
        case .seventyFive: 0.75
        case .half: 0.5
        }
    }
    var label: String {
        switch self {
        case .full: "Full pane"
        case .ninety: "90%"
        case .seventyFive: "75%"
        case .half: "50%"
        }
    }
}

enum TextWidth {
    /// Widths are always resolved against the *current* font, never stored as
    /// points: source mode is monospace, so the same character count is a
    /// different width there.
    ///
    /// - Returns: the width the prose should occupy, and whether to centre it.
    static func resolve(intent: TextIntent,
                        paneWidth: CGFloat,
                        characterWidth: CGFloat,
                        reading: ReadingWidth,
                        editing: EditorWidth) -> (width: CGFloat, centred: Bool) {
        let available = max(1, paneWidth - 2 * ShellMetrics.insets)
        switch intent {
        case .reading:
            guard let characters = reading.characters else { return (available, false) }
            // A fixed measure, centred — and `min` means a narrow pane never
            // sees the setting bite.
            return (min(characters * characterWidth, available), true)
        case .editing:
            // Proportional to the pane, left-aligned, with the floor from
            // Part 3 — but never wider than the pane itself.
            return (min(available, max(ShellMetrics.editorFloor,
                                       available * editing.proportion)), false)
        }
    }
}

// MARK: - Context published to everything inside the shell

/// What a view inside the shell needs to know about the shell it is inside.
/// Read it with `@Environment(\.shell)`; never re-derive it from a
/// `GeometryReader` further down, or two parts of the UI can disagree.
struct ShellContext: Equatable, Sendable {
    var kind: ShellKind = .wide
    var size: CGSize = CGSize(width: 1470, height: 923)
    /// Width available to a single editor pane, after rails and dividers.
    var paneWidth: CGFloat = 1470
    /// Touch sizing: bigger hit targets, no hover-only affordances.
    var prefersTouch: Bool = false

    /// Decision 3 — a persistent format bar needs a pointer and room.
    var showsFormatBar: Bool { !prefersTouch && paneWidth >= ShellMetrics.formatBarMinPane }

    /// Tab bars are never removed; they only change height (HIG: 44pt touch).
    var tabBarHeight: CGFloat { prefersTouch ? ShellMetrics.tabBarTouch : ShellMetrics.tabBarPointer }

    /// Decision 12 — below 960pt the library needs a ☰ affordance somewhere.
    var needsLibraryAffordance: Bool { kind.sidebarIsOverlay }

    var maxPanes: Int { ShellMetrics.maxPanes(detailWidth: paneWidth) }
}

private struct ShellContextKey: EnvironmentKey {
    static let defaultValue = ShellContext()
}

extension EnvironmentValues {
    var shell: ShellContext {
        get { self[ShellContextKey.self] }
        set { self[ShellContextKey.self] = newValue }
    }
}
