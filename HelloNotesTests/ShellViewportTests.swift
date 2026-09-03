//
//  ShellViewportTests.swift
//  HelloNotesTests
//
//  The measured half of the layout contract (docs/layout-architecture.md Part 6,
//  rules 1–4): a viewport must report the size it is *offered*, never the size
//  it *contains*.
//
//  Split out of `ShellContractTests` so that file could go cross-platform. This
//  half genuinely cannot: it hosts the shell in a real `NSWindow` with a real
//  `NSToolbar` and walks the `NSView` tree looking for a scroll view taller than
//  its window. That is the bug it exists for — a note's first lines rendered
//  251pt above the window with no scroll offset able to reach them — and it is
//  an AppKit fact, measured with AppKit.
//
//  The equivalent iOS assertion lives in the editor package, where
//  `MarkdownUITextView` answers `sizeThatFits` through `viewportSizeThatFits`
//  and `UITextViewBindTests` pins the behaviour headlessly.
//

#if os(macOS)
import Testing
import SwiftUI
import AppKit
import MarkdownEditor
@testable import HelloNotes

@MainActor
struct ShellViewportTests {


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
            bandHidden: .constant(false),
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
        // The same scene table the cross-platform half asserts the shell choice
        // against, so the measured rules and the arithmetic rules can never be
        // checked at different sizes.
        for scene in ShellContractTests.scenes {
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
                expandedFolders: .constant([]),
                collapsedCollections: .constant([]),
                accent: .accentColor
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
