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
import MarkdownEditor   // PlatformFont

// MARK: - Part 3: component sizes

/// Every size the shell is allowed to use. A number that isn't here is a number
/// nobody decided; put it here (and in Part 3 of the design) before using it.
/// The sidebar's persisted selection.
///
/// `railPlaceUnset` was a `static let` on *each* shell, with the same value —
/// two constants that must agree is the shape this project keeps removing.
enum RailPlaceStorage {
    static let key = "railPlace"
    /// No choice made yet, as distinct from "the Library place".
    static let unset = "?"
}

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

// MARK: - The pane's text column (Part 2, decision 5)

//  There used to be a `TextIntent` here — `.reading` or `.editing` — and the
//  note pane chose between them by *mode*: Preview asked for the reading
//  measure and got 80 characters centred, while Edit asked for the editing
//  measure and got the whole pane. So the first thing switching Edit→Preview
//  did was move the text sideways and change every line break in the document,
//  before a single glyph had been re-measured. No amount of matching the
//  typography fixes a column that changes width.
//
//  A pane has one column. Both settings still apply, and they answer different
//  questions: Editor width is a proportion of the pane, Reading width is a
//  maximum measure in characters. The column is the proportion, capped by the
//  measure — and centred only when the measure is what bit.

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
    /// The pane's text column: one width, whatever mode the pane is showing.
    ///
    /// - Returns: the width the prose should occupy, and whether to centre it.
    static func resolve(paneWidth: CGFloat,
                        characterWidth: CGFloat,
                        reading: ReadingWidth,
                        editing: EditorWidth) -> (width: CGFloat, centred: Bool) {
        let available = max(1, paneWidth - 2 * ShellMetrics.insets)
        // Editor width: proportional to the pane, with the floor from Part 3,
        // and never wider than the pane itself.
        let proportion = min(available, max(ShellMetrics.editorFloor,
                                            available * editing.proportion))
        // Reading width then caps it as a measure in characters. `.full` has no
        // measure, which is the setting's own escape hatch.
        guard let characters = reading.characters else { return (proportion, false) }
        let measure = min(proportion, characters * characterWidth)
        // Centre only when the measure is doing the work: a column narrowed by
        // Editor width alone stays left-aligned, VS Code style, because the
        // pane *is* the workspace.
        return (measure, measure < proportion - 0.5)
    }

    /// Measured, not assumed — and always against the *body* font, whatever the
    /// pane is currently showing.
    ///
    /// It used to be resolved against "the font actually in use", which meant
    /// the monospaced one in Source mode: the same "80 characters" was a wider
    /// column there than in Edit or Preview, so the column changed width when
    /// the mode did. A measure is about prose line length; the pane's column is
    /// the pane's, not the mode's.
    ///
    /// Cross-platform, and here rather than in a view, because it used to be a
    /// `private static` on the macOS-only `NoteEditorView` written in `NSFont`
    /// — which is the whole reason Reading width and Editor width were settings
    /// the iPad stored and never applied.
    static func characterWidth(size: CGFloat) -> CGFloat {
        ("0" as NSString).size(withAttributes: [.font: PlatformFont.systemFont(ofSize: size)]).width
    }
}

/// Constrains prose to the user's measure and centres it when the setting asks
/// for a fixed one.
///
/// A modifier rather than a helper on one view, so both shells' editors are
/// laid out by the same code — the Mac's `NoteEditorView` and the iPad's
/// `iOSLiveEditor` were two answers to one question, and only one of them had
/// read the setting.
struct MeasuredText: ViewModifier {
    let fontSize: CGFloat
    let reading: ReadingWidth
    let editing: EditorWidth

    /// Read here rather than passed in, so a caller cannot measure against a
    /// width the shell disagrees with — the contract's own rule about never
    /// re-deriving the pane width further down.
    @Environment(\.shell) private var shell

    func body(content: Content) -> some View {
        let resolved = TextWidth.resolve(
            paneWidth: shell.paneWidth,
            characterWidth: TextWidth.characterWidth(size: fontSize),
            reading: reading,
            editing: editing
        )
        HStack(spacing: 0) {
            if resolved.centred { Spacer(minLength: 0) }
            content.frame(maxWidth: resolved.width)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// Lay this content out at the user's Reading / Editor width.
    func measuredText(fontSize: CGFloat,
                      reading: ReadingWidth,
                      editing: EditorWidth) -> some View {
        modifier(MeasuredText(fontSize: fontSize, reading: reading, editing: editing))
    }
}

/// Applies the user's measure when there is one, and nothing at all when there
/// is not.
///
/// `ViewModifier` rather than an `if` in the body: a conditional branch around
/// a `UIViewRepresentable` changes the view's identity, which tears the text
/// view down and rebuilds it — dropping the caret every time the setting is
/// touched.
struct OptionalMeasure: ViewModifier {
    let fontSize: CGFloat
    let width: (reading: ReadingWidth, editing: EditorWidth)?

    func body(content: Content) -> some View {
        content.measuredText(fontSize: fontSize,
                             reading: width?.reading ?? .full,
                             editing: width?.editing ?? .full)
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

// MARK: - The declared window minimum (decision 9)

extension View {
    /// Declare the shell's window minimum where the app owns its window size.
    ///
    /// A minimum on the content is how a resizable window's floor is declared:
    /// the window manager reads it and refuses to go smaller. Where the app
    /// does *not* own the window size, the same modifier means something else
    /// entirely — SwiftUI honours a minimum over the proposal, so the shell
    /// lays out at 860pt inside a 393pt iPhone and the result is centred and
    /// clipped off both edges, unreachable.
    ///
    /// This was applied unconditionally when the two shells merged: only
    /// `MacContentView` had carried it, inside that file's whole-file gate, and
    /// merging the files silently handed the Mac's floor to every phone and to
    /// any iPad narrower than 860pt — which includes an 11" iPad in portrait.
    ///
    /// Both branches answer the same question. Where the size is imposed, the
    /// floor is not a declaration to make but a case to degrade through, which
    /// `shellKind` already does — `.compact` *is* the answer for below 600pt.
    func declaredWindowMinimum() -> some View {
        #if os(macOS)
        return frame(minWidth: ShellMetrics.windowMinWidth,
                     minHeight: ShellMetrics.windowMinHeight)
            // S2 (docs/layout-architecture.md): a minimum is a floor, not a
            // ceiling. Without a maximum, any column child with a large ideal
            // size inflates the split view past the window and offsets it
            // off-screen.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        return frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
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
