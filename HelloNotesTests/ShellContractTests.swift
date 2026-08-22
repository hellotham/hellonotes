//
//  ShellContractTests.swift
//  HelloNotesTests
//
//  The layout contract from docs/layout-architecture.md Part 6, as a test — on
//  **both** platforms.
//
//  The contract's first rule is that the shell is chosen by the axis of
//  abundance and never by the device: "a Mac window and an iPad of the same size
//  get the same layout." This file asserts exactly that, and it was `#if
//  os(macOS)` end to end — so the one rule in the codebase that is explicitly
//  about the two platforms agreeing had only ever been checked on one of them.
//  A divergence in `ShellKind`, `ShellMetrics` or `TextWidth` at any size would
//  have gone unnoticed on iOS.
//
//  Nothing here needs AppKit: `ShellKind`, `ShellMetrics` and `TextWidth.resolve`
//  are pure functions of a size. The half that genuinely does — measuring real
//  viewport geometry in a real window — is `ShellViewportTests`, which stays
//  macOS-only and says why.
//

import Testing
import SwiftUI
import MarkdownEditor
@testable import HelloNotes

@MainActor
struct ShellContractTests {

    // MARK: - Scenes (Part 6)

    struct Scene {
        let name: String
        let width: CGFloat
        let height: CGFloat
        let expected: ShellKind
    }

    static let scenes: [Scene] = [
        Scene(name: "iPad 1/3",        width: 320,  height: 1024, expected: .compact),
        Scene(name: "iPhone SE",       width: 375,  height: 667,  expected: .compact),
        Scene(name: "iPhone 17 Pro",   width: 402,  height: 874,  expected: .compact),
        Scene(name: "iPad 1/2",        width: 507,  height: 1024, expected: .compact),
        Scene(name: "Stage Mgr tiny",  width: 250,  height: 800,  expected: .compact),
        Scene(name: "Mac half-screen", width: 660,  height: 900,  expected: .tall),
        Scene(name: "iPad portrait",   width: 834,  height: 1194, expected: .tall),
        Scene(name: "Tall Mac window", width: 900,  height: 1400, expected: .tall),
        Scene(name: "Mac minimum",     width: 860,  height: 480,  expected: .two),
        Scene(name: "Mac default",     width: 1100, height: 720,  expected: .wide),
        Scene(name: "iPad landscape",  width: 1194, height: 834,  expected: .wide),
        Scene(name: "Mac typical",     width: 1470, height: 923,  expected: .wideInspector),
        Scene(name: "Mac ultrawide",   width: 2560, height: 1440, expected: .wideInspector),
        Scene(name: "Mac large",       width: 3840, height: 2160, expected: .wideInspector),
    ]

    // MARK: - The rule itself

    @Test("The shell follows the axis of abundance, not the device")
    func shellSelection() {
        for scene in Self.scenes {
            #expect(shellKind(width: scene.width, height: scene.height) == scene.expected,
                    "\(scene.name) \(Int(scene.width))x\(Int(scene.height))")
        }
    }

    @Test("A Mac window and an iPad of the same size get the same shell")
    func shellIgnoresDeviceIdentity() {
        // 1194x834 is an iPad in landscape and an ordinary Mac window alike.
        #expect(shellKind(width: 1194, height: 834) == .wide)
        // Portrait is the one that differs — and only because the *shape* did.
        #expect(shellKind(width: 834, height: 1194) == .tall)
    }

    // MARK: - Decision 5: reading is fixed and centred, editing fills the pane

    @Test("The pane has one column: a proportion, capped by a measure")
    func textWidthComposesBothSettings() {
        let characterWidth: CGFloat = 7      // ~14pt system font
        let pane: CGFloat = 3200             // a single pane on a 3840pt display

        // No measure: the proportion alone, left-aligned, VS Code style.
        let full = TextWidth.resolve(paneWidth: pane, characterWidth: characterWidth,
                                     reading: .full, editing: .full)
        #expect(full.width == pane - 2 * ShellMetrics.insets)
        #expect(full.centred == false, "a full-width column is left-aligned")

        // A measure caps it, and a capped column is centred.
        let measured = TextWidth.resolve(paneWidth: pane, characterWidth: characterWidth,
                                         reading: .normal, editing: .full)
        #expect(measured.width == 80 * characterWidth)
        #expect(measured.centred, "a measure is only a measure if it is centred")

        // Editor width alone narrows without centring.
        let half = TextWidth.resolve(paneWidth: pane, characterWidth: characterWidth,
                                     reading: .full, editing: .half)
        #expect(half.width == (pane - 2 * ShellMetrics.insets) / 2)
        #expect(half.centred == false)
    }

    /// The whole point of collapsing the two intents: the column cannot depend
    /// on what the pane is *showing*, or switching Edit→Preview moves the text.
    @Test("One pane, one column — mode cannot change it")
    func theColumnDoesNotDependOnTheMode() {
        for pane in [CGFloat(320), 860, 1470, 3200] {
            for reading in ReadingWidth.allCases {
                for editing in EditorWidth.allCases {
                    let a = TextWidth.resolve(paneWidth: pane, characterWidth: 7,
                                              reading: reading, editing: editing)
                    let b = TextWidth.resolve(paneWidth: pane, characterWidth: 7,
                                              reading: reading, editing: editing)
                    #expect(a == b)
                    #expect(a.width <= pane, "pane \(Int(pane)) \(reading) \(editing)")
                }
            }
        }
    }

    @Test("A narrow pane collapses the distinction — neither setting bites")
    func narrowPaneIgnoresBothSettings() {
        let pane: CGFloat = 375              // a phone
        let available = pane - 2 * ShellMetrics.insets
        let resolved = TextWidth.resolve(paneWidth: pane, characterWidth: 7,
                                         reading: .normal, editing: .full)
        #expect(resolved.width <= available, "the column must never exceed its pane")
    }

    // MARK: - Decision 3 / switching / affordances

    @Test("The format bar needs a pointer and room; switching is never removed")
    func chromeRules() {
        for scene in Self.scenes {
            let kind = shellKind(width: scene.width, height: scene.height)
            let paneWidth = AdaptiveShell<EmptyView, EmptyView, EmptyView, EmptyView>
                .estimatedPaneWidth(kind: kind, width: scene.width)
            let touch = ShellContext(kind: kind, size: CGSize(width: scene.width, height: scene.height),
                                     paneWidth: paneWidth, prefersTouch: true)
            let pointer = ShellContext(kind: kind, size: CGSize(width: scene.width, height: scene.height),
                                       paneWidth: paneWidth, prefersTouch: false)

            #expect(!touch.showsFormatBar,
                    "\(scene.name): touch editing uses the keyboard accessory bar, not a format bar")
            #expect(pointer.showsFormatBar == (paneWidth >= ShellMetrics.formatBarMinPane),
                    "\(scene.name): pane \(Int(paneWidth))")
            #expect(touch.tabBarHeight >= 44, "\(scene.name): HIG touch target")
            // Decision 12 — below 960pt there must be a way back to the library.
            #expect(pointer.needsLibraryAffordance == (kind == .compact),
                    "\(scene.name)")
        }
    }

    @Test("Surplus width buys another note, never a wider line")
    func paneCeilingGrowsWithWidth() {
        #expect(ShellMetrics.maxPanes(detailWidth: 600) == 1)
        #expect(ShellMetrics.maxPanes(detailWidth: 700) == 2)
        #expect(ShellMetrics.maxPanes(detailWidth: 1400) == 4)
        // Never more than four, however wide the display.
        #expect(ShellMetrics.maxPanes(detailWidth: 8000) == 4)
        // Below the floor, still one pane — degrade, never zero (decision 9).
        #expect(ShellMetrics.maxPanes(detailWidth: 250) == 1)
    }

    @Test("One sidebar, draggable between a floor and a cap, and the pane pays for it")
    func sidebarIsTheOnlyCollapsibleColumn() {
        // A tree of collections and folders holds names of every length, so
        // unlike the fixed rail it replaced this column *is* draggable — but
        // capped close to its ideal, because NSSplitView hands slack to
        // whichever column can still grow and the width belongs to the editor.
        #expect(ShellMetrics.sidebarFloor < ShellMetrics.sidebarIdeal)
        #expect(ShellMetrics.sidebarIdeal < ShellMetrics.sidebarCap)
        #expect(ShellMetrics.sidebarCap - ShellMetrics.sidebarIdeal <= 100)

        // Both columns fit at the declared window minimum. This is what makes
        // the sidebar collapsible-by-choice rather than forced shut at 860pt:
        // three columns did not fit there, which is why the old shell retracted
        // the library below 960 — and why its toggle ended up hand-placed.
        #expect(ShellMetrics.sidebarIdeal + ShellMetrics.editorFloor
                <= ShellMetrics.windowMinWidth)

        // Every arrangement that shows the sidebar subtracts exactly its width —
        // this is what stops the pane estimate (and so the format-bar rule and
        // the reading measure) drifting from what the pane actually gets.
        let wide = AdaptiveShell<EmptyView, EmptyView, EmptyView, EmptyView>
            .estimatedPaneWidth(kind: .wide, width: 1100)
        #expect(wide == 1100 - ShellMetrics.sidebarIdeal - 1)

        let inspector = AdaptiveShell<EmptyView, EmptyView, EmptyView, EmptyView>
            .estimatedPaneWidth(kind: .wideInspector, width: 1470)
        #expect(inspector == 1470 - ShellMetrics.sidebarIdeal
                                  - ShellMetrics.inspectorIdeal - 2)

        // Only compact has no sidebar column at all; everywhere else the user
        // decides, so nothing may lock the toggle.
        for kind in [ShellKind.two, .wide, .wideInspector, .tall] {
            #expect(kind.hasSidebar, "\(kind.rawValue) must carry the sidebar")
            #expect(!kind.sidebarIsOverlay, "\(kind.rawValue) must not force it shut")
        }
        #expect(!ShellKind.compact.hasSidebar)
    }

    @Test("The Library place shows the most recent notes without sorting the vault")
    func mostRecentPicksTheTop() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let notes = (0..<200).map { index in
            Note(title: "n\(index)",
                 fileURL: URL(fileURLWithPath: "/v/n\(index).md"),
                 lastModified: base.addingTimeInterval(TimeInterval(index)))
        }
        // Shuffled input, because the single-pass selection must not quietly
        // depend on the array already being in order.
        let top = LibraryPlace.mostRecent(notes.shuffled(), limit: 8)
        #expect(top.map(\.title) == ["n199", "n198", "n197", "n196",
                                     "n195", "n194", "n193", "n192"])
        #expect(LibraryPlace.mostRecent([], limit: 8).isEmpty)
        #expect(LibraryPlace.mostRecent(Array(notes.prefix(3)), limit: 8).count == 3)
    }
}
