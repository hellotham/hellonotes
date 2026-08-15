//
//  ShellContractTests.swift
//  HelloNotesTests
//
//  The validation matrix from docs/layout-architecture.md Part 6, as a test.
//
//  A note's first lines were once unreachable because a viewport reported its
//  *content* height as its ideal size, which inflated the split view past the
//  window and offset it to y = -251. Nothing in the codebase could have caught
//  that: it was a layout fact, not a logic fact. These tests measure the real
//  view tree in a real (never-shown) window, so the class of bug fails the
//  build instead of reaching the user.
//

#if os(macOS)
import Testing
import AppKit
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

    @Test("Editing fills a wide pane; reading holds its measure")
    func textWidthFollowsIntent() {
        let characterWidth: CGFloat = 7      // ~14pt system font
        let pane: CGFloat = 3200             // a single pane on a 3840pt display

        let editing = TextWidth.resolve(intent: .editing, paneWidth: pane,
                                        characterWidth: characterWidth,
                                        reading: .normal, editing: .full)
        #expect(editing.width == pane - 2 * ShellMetrics.insets)
        #expect(editing.centred == false, "editing is left-aligned, VS Code style")

        let reading = TextWidth.resolve(intent: .reading, paneWidth: pane,
                                        characterWidth: characterWidth,
                                        reading: .normal, editing: .full)
        #expect(reading.width == 80 * characterWidth)
        #expect(reading.centred, "a measure is only a measure if it is centred")
    }

    @Test("A narrow pane collapses the distinction — neither setting bites")
    func narrowPaneIgnoresBothSettings() {
        let pane: CGFloat = 375              // a phone
        let available = pane - 2 * ShellMetrics.insets
        for intent in [TextIntent.reading, .editing] {
            let resolved = TextWidth.resolve(intent: intent, paneWidth: pane,
                                             characterWidth: 7,
                                             reading: .normal, editing: .full)
            #expect(resolved.width <= available,
                    "\(intent) must never exceed the pane it lives in")
        }
    }

    @Test("Prose never exceeds its pane, at any setting or size")
    func proseNeverExceedsPane() {
        for pane in [CGFloat(250), 320, 560, 860, 1470, 3840] {
            for reading in ReadingWidth.allCases {
                for editing in EditorWidth.allCases {
                    for intent in [TextIntent.reading, .editing] {
                        let resolved = TextWidth.resolve(
                            intent: intent, paneWidth: pane, characterWidth: 7,
                            reading: reading, editing: editing)
                        #expect(resolved.width <= pane,
                                "pane \(Int(pane)) \(intent) \(reading) \(editing)")
                    }
                }
            }
        }
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

    // MARK: - The measured rules (Part 6, 1–4)

    /// Hosts a view in a real toolbar window that is never ordered front, lays
    /// it out, and hands back the view tree.
    private func layout<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> NSHostingView<V> {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.toolbar = NSToolbar(identifier: "shell-contract")
        window.titlebarAppearsTransparent = true
        window.contentView = hosting
        hosting.frame = window.contentView?.bounds ?? .zero
        window.layoutIfNeeded()
        // Let SwiftUI settle its own layout pass.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return hosting
    }

    /// Every viewport in the tree, found by the identifier the fixture stamps
    /// on it. Deliberately does **not** descend into a scroll view's document
    /// view: that content is *supposed* to be far larger than the window — being
    /// a window onto something bigger than itself is what a viewport is for.
    /// The contract governs the viewport and everything above it.
    private func viewports(in view: NSView, into found: inout [NSScrollView]) {
        if let scroll = view as? NSScrollView, scroll.identifier != nil {
            found.append(scroll)
            return
        }
        for sub in view.subviews { viewports(in: sub, into: &found) }
    }

    /// The viewport and each of its ancestors up to the window's content view.
    private func viewportAndAncestors(_ view: NSView) -> [NSView] {
        var chain: [NSView] = []
        var node: NSView? = view
        while let current = node, chain.count < 20 {
            chain.append(current)
            node = current.superview
        }
        return chain
    }

    /// A shell whose every slot is a viewport onto content far larger than any
    /// window — the exact shape that broke the app.
    private func oversizedShell() -> some View {
        AdaptiveShell(
            inspectorPresented: .constant(true),
            columnVisibility: .constant(.all),
            // 2,000 notes' worth of tree in the one sidebar there now is.
            sidebar: { OversizedViewport(tag: "sidebar", contentHeight: 56_000) },
            pane: { OversizedViewport(tag: "editor", contentHeight: 40_000) },
            inspector: { OversizedViewport(tag: "inspector", contentHeight: 2000) },
            compact: {
                VStack(spacing: 0) {
                    OversizedViewport(tag: "editor", contentHeight: 40_000)
                    Color.clear.frame(height: ShellMetrics.miniStrip)
                    Color.clear.frame(height: ShellMetrics.bottomTabBar)
                }
            }
        )
    }

    @Test("No view exceeds its scene, and none is stranded above it")
    func nothingExceedsOrEscapesTheScene() {
        for scene in Self.scenes {
            let hosting = layout(oversizedShell(), width: scene.width, height: scene.height)
            var found: [NSScrollView] = []
            viewports(in: hosting, into: &found)

            #expect(!found.isEmpty, "\(scene.name): no viewport was laid out at all")

            for viewport in found {
                let tag = viewport.identifier?.rawValue ?? "?"
                for view in viewportAndAncestors(viewport) {
                    // Rule 1 — no ancestor of any viewport exceeds the scene.
                    #expect(view.frame.height <= scene.height + 1,
                            "\(scene.name): \(tag) ancestor \(type(of: view)) is \(Int(view.frame.height))pt in a \(Int(scene.height))pt scene")
                }
                // Rule 2 — no viewport origin is negative in window space.
                let inWindow = viewport.convert(viewport.bounds, to: nil)
                #expect(inWindow.minY >= -1,
                        "\(scene.name): \(tag) sits at y=\(Int(inWindow.minY))")
                // Rule 5 — and it never spills sideways out of the scene either.
                #expect(viewport.frame.width <= scene.width + 1,
                        "\(scene.name): \(tag) is \(Int(viewport.frame.width))pt wide in a \(Int(scene.width))pt scene")
            }
        }
    }

    @Test("Resizing strands nothing outside the scene")
    func liveResizeStrandsNothing() {
        let hosting = NSHostingView(rootView: oversizedShell())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1470, height: 923),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.toolbar = NSToolbar(identifier: "shell-resize")
        window.contentView = hosting

        // The full sweep: wide → phone-narrow → wide again.
        for width in [CGFloat(3840), 1470, 1100, 860, 660, 402, 250, 660, 1470, 3840] {
            window.setFrame(NSRect(x: 0, y: 0, width: width, height: 1200), display: true)
            hosting.frame = window.contentView?.bounds ?? .zero
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))

            var found: [NSScrollView] = []
            viewports(in: hosting, into: &found)

            #expect(!found.isEmpty, "width \(Int(width)): everything vanished")

            let stranded = found.filter { $0.convert($0.bounds, to: nil).minY < -1 }
                .map { $0.identifier?.rawValue ?? "?" }
            #expect(stranded.isEmpty,
                    "width \(Int(width)): stranded above the window: \(stranded.joined(separator: ", "))")

            let overflowing = found
                .flatMap { viewport in
                    viewportAndAncestors(viewport)
                        .filter { $0.frame.height > 1201 }
                        .map { "\(viewport.identifier?.rawValue ?? "?")/\(type(of: $0))" }
                }
            #expect(overflowing.isEmpty,
                    "width \(Int(width)): taller than the window: \(overflowing.joined(separator: ", "))")
        }
    }

    // MARK: - S1, on the app's own representables

    /// SwiftUI's own ideal size for a view. This is the probe that used to
    /// return the whole note's height (3433pt for 76 lines).
    private func idealSize<V: View>(_ view: V) -> CGSize {
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize
    }

    @Test("A viewport's ideal size never depends on its content")
    func viewportsDoNotAdvertiseContentSize() {
        // A viewport must answer the same ideal whether it holds one line or a
        // hundred thousand — that independence *is* invariant S1.
        let small = idealSize(OversizedViewport(tag: "small", contentHeight: 40))
        let huge = idealSize(OversizedViewport(tag: "huge", contentHeight: 100_000))
        #expect(small == huge,
                "ideal changed with content: \(small) vs \(huge)")
        #expect(huge.height < 1000, "ideal height \(huge.height) looks like content height")
    }

    @Test("The note outline does not size the shell by its row count")
    func noteOutlineDoesNotInflateTheShell() {
        // NSSplitView sizes itself to its tallest column, so a 2,000-note
        // outline could inflate the whole shell on its own.
        func outline(rows: Int) -> NoteOutlineList {
            NoteOutlineList(
                roots: (0..<rows).map { NoteOutlineItem(id: "f\($0)", kind: .folder("Folder \($0)")) },
                signature: "rows-\(rows)",
                selection: .constant(nil),
                revealID: .constant(nil),
                accent: .accentColor,
                isBookmarked: { _ in false },
                onToggleBookmark: { _ in },
                onDelete: { _ in },
                onOpenInNewWindow: { _ in },
                onCloseCollection: { _ in },
                onFocusCollection: { _ in }
            )
        }
        let few = idealSize(outline(rows: 1))
        let many = idealSize(outline(rows: 2000))
        #expect(few == many, "outline ideal grew with the vault: \(few) vs \(many)")
    }
}

// MARK: - Test fixture

/// A representable wrapping a scroll view whose content is far larger than any
/// window — i.e. the shape of every real viewport in the app, with the sizing
/// contract applied.
private struct OversizedViewport: NSViewRepresentable {
    let tag: String
    var contentHeight: CGFloat = 4000

    func makeNSView(context: Context) -> NSScrollView {
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: contentHeight))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = document
        scroll.identifier = NSUserInterfaceItemIdentifier(tag)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        view.documentView?.frame.size.height = contentHeight
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView,
                      context: Context) -> CGSize? { viewportSizeThatFits(proposal) }
}
#endif
