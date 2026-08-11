//
//  ChromeProbe.swift
//  HelloNotes
//
//  Measures the window's chrome instead of guessing at it.
//
//  The unreachable top-of-file bug took six speculative fixes and one
//  measurement (implemented.md §17). The titlebar bleed has now taken two
//  speculative fixes — a `toolbarBackground` on the wrong view, and a rail
//  rebuilt as a `List` — and no measurement. Same mistake, so: same remedy.
//
//  It reports what actually decides whether a column can paint into the
//  titlebar: the window's style mask, whether the titlebar is transparent, the
//  toolbar's style, and `contentLayoutRect` (the part of the content view the
//  titlebar does *not* overlap) against each split-view column's frame. A
//  column whose top is above `contentLayoutRect.maxY` is drawing under the
//  titlebar — that is the bleed, stated as a number.
//
//  What it has established so far, so nobody re-tries these:
//
//    * `toolbarBackground` / `toolbarBackgroundVisibility` on the shell — no
//      effect; the modifier needs a toolbar-owning container, and even on one
//      the columns are still physically up there.
//    * Rebuilding the rail as a `List` — no effect on the overlap.
//    * Removing `.fullSizeContentView` from the window's style mask — **no
//      effect**: measured `fullSizeContentView=false` and the overlap stayed at
//      52pt, with every column still full height. AppKit keeps the content view
//      the full frame height; the flag alone does not shrink it.
//
//  Debug builds only, and off unless `HN_GEOM_LOG` asks for it, so an ordinary
//  run neither writes the file nor walks the hierarchy.
//
//      HN_GEOM_LOG=1 ./scripts/relaunch-debug.sh
//      grep chrome ~/Library/Containers/com.hellotham.HelloNotes/Data/Library/Caches/hn-geom.log
//

#if os(macOS)
import SwiftUI
import AppKit

/// Drop into a `.background()` anywhere inside the window. Zero-sized, and does
/// nothing at all unless the probe is enabled.
struct ChromeProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        guard ChromeProbeLog.enabled else { return view }
        // Twice, because *when* you measure is part of the measurement. The
        // titlebar clearance takes effect on a later layout pass than the style
        // flag itself, so a single early reading showed `fullSize=false` with
        // the overlap unchanged — and read as a failed fix rather than an
        // early look.
        for (delay, tag) in [(0.8, "appear"), (3.0, "settled")] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
                ChromeProbeLog.dump(window: view?.window, tag: tag)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Zero-sized: it is an observer, not a participant in layout (S1/S2).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView,
                      context: Context) -> CGSize? { .zero }
}

/// Keeps the shell's columns out of the window's titlebar band.
///
/// Proved in `scratchpad/ChromeLab` before a line of this shipped — which is
/// the process this problem needed and did not get for four attempts. The bench
/// builds the same three-column `NavigationSplitView` in an off-screen window,
/// applies each candidate, and measures. Its verdict:
///
///     1  baseline                              52pt overlap, 5 columns under
///     2  opaque toolbar on detail              52pt, 5           (no effect)
///     3  no fullSizeContentView at creation     0pt, 0           PASS
///     4  strip fullSizeContentView after layout 0pt, 0           PASS
///     5–7 toolbarStyle expanded/unified/preference — worse or unchanged
///     8  allowsFullHeightLayout = false        52pt, 5  (5 items reached!)
///     10 inset the columns' content            52pt, 5  (columns unmoved)
///     11 strip, then something re-applies it   52pt, 5  ← what the app saw
///     12 strip + re-asserting observer          0pt, 0           PASS
///
/// So stripping `.fullSizeContentView` is right, and SwiftUI puts it back —
/// candidate 11 reproduces the app's measurement exactly. The flag therefore has
/// to be re-asserted whenever the window updates, which is candidate 12 and is
/// what this ships. Note candidate 8: the documented `allowsFullHeightLayout`
/// reached all five split items in the bench and *still* changed nothing, so
/// that avenue was dead on its own terms, not merely unreachable.
struct TitlebarClearance: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Zero-sized: an observer, never a participant in layout (S1/S2).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView,
                      context: Context) -> CGSize? { .zero }

    @MainActor
    final class Coordinator {
        private var tokens: [NSObjectProtocol] = []
        private weak var window: NSWindow?

        func attach(to view: NSView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let window = view?.window, window !== self.window else { return }
                self.window = window
                self.clear(window)
                // One assertion is not enough: SwiftUI re-applies its own window
                // style, and a window that has been re-flagged is a window whose
                // columns are 52pt into the titlebar again.
                let names: [Notification.Name] = [
                    NSWindow.didUpdateNotification,
                    NSWindow.didResizeNotification,
                    NSWindow.didBecomeKeyNotification,
                ]
                self.tokens = names.map { name in
                    NotificationCenter.default.addObserver(forName: name, object: window,
                                                            queue: .main) { note in
                        guard let window = note.object as? NSWindow else { return }
                        MainActor.assumeIsolated { self.clear(window) }
                    }
                }
            }
        }

        private func clear(_ window: NSWindow) {
            if window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.remove(.fullSizeContentView)
                window.titlebarAppearsTransparent = false
            }
            window.titlebarSeparatorStyle = .line

            // No `additionalSafeAreaInsets` here. That was tried while hunting
            // the capsule, did nothing for it, and — once the shell became an
            // `HSplitView` whose columns honour the safe area properly — showed
            // up as a 52pt gap above the rail and the note list. A failed
            // experiment left in is a regression waiting for its moment.
        }

        deinit {
            tokens.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

/// Publishes how far the titlebar overlaps the content view, so a column's own
/// content can start below it.
///
/// `TitlebarClearance` takes `.fullSizeContentView` off the window and keeps it
/// off, which fixed the note list and the inspector. The rail still needed this:
/// its rows are ours to place, and a selection chip under the traffic lights is
/// our bug whatever the column does.
struct TitlebarInsetReader: NSViewRepresentable {
    @Binding var inset: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        report(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { report(from: nsView) }

    /// Zero-sized: an observer, never a participant in layout (S1/S2).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView,
                      context: Context) -> CGSize? { .zero }

    private func report(from view: NSView) {
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window, let content = window.contentView else { return }
            let overlap = max(0, content.bounds.height - window.contentLayoutRect.height)
            if abs(overlap - inset) > 0.5 { inset = overlap }
        }
    }
}

enum ChromeProbeLog {
    static let enabled: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["HN_GEOM_LOG"] != nil
        #else
        return false
        #endif
    }()

    private static let logURL: URL? = {
        (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true))?
            .appendingPathComponent("hn-geom.log")
    }()

    /// A one-line note in the same log, so a fix can say whether it did anything.
    /// Always written when the probe is on, regardless of the geometry dump.
    @MainActor
    static func note(_ line: String) {
        guard enabled else { return }
        append("chrome[note] \(line)\n")
    }

    // `samplePixels` and `snapshot` used to live here. Both went through
    // `cacheDisplay(in:to:)`, and **that cannot render materials, vibrancy or
    // Liquid Glass** — it paints them flat white. Those *are* the sidebar
    // chrome, so the instrument was structurally blind to the only thing it was
    // pointed at: it invented a "white capsule" that did not exist, and cost a
    // session of eight fixes, two reverts and a shipped regression chasing it.
    //
    // The replacement is not a better in-process snapshot; it is a different
    // mechanism entirely. `screencapture -l <windowID>` goes through the real
    // compositor, needs no Screen Recording permission for an enumerable
    // window, and captures that one window only:
    //
    //     swiftc -O scripts/winid.swift -o /tmp/winid && /tmp/winid
    //     screencapture -l<id> -o -x /tmp/hn.png
    //
    // Validate an instrument before trusting it. One capture of any app with a
    // normal sidebar would have exposed the flaw in seconds — and when a
    // measurement disagrees with what the user can see, the measurement is the
    // suspect.

    @MainActor
    static func dump(window: NSWindow?, tag: String) {
        guard enabled, let window, let content = window.contentView else { return }

        var lines: [String] = []
        let mask = window.styleMask
        lines.append("chrome[\(tag)] "
            + "styleMask=0x\(String(mask.rawValue, radix: 16)) "
            + "unifiedTitleAndToolbar=\(mask.contains(.unifiedTitleAndToolbar)) "
            + "contentVC=\(window.contentViewController.map { String(describing: type(of: $0)) } ?? "nil") "
            + "fullSizeContentView=\(mask.contains(.fullSizeContentView)) "
            + "titlebarTransparent=\(window.titlebarAppearsTransparent) "
            + "titleVisibility=\(window.titleVisibility == .visible ? "visible" : "hidden") "
            + "toolbarStyle=\(describe(window.toolbarStyle)) "
            + "toolbarVisible=\(window.toolbar?.isVisible ?? false)")

        // The band the titlebar/toolbar overlaps. Anything drawn above
        // `contentLayoutRect.maxY` in the content view's flipped-from-top terms
        // is under the chrome.
        let layout = window.contentLayoutRect
        let overlap = content.bounds.height - layout.height
        lines.append("chrome[\(tag)] contentView=\(short(content.bounds)) "
            + "contentLayoutRect=\(short(layout)) titlebarOverlap=\(round(overlap))pt")

        // Every split view in the window, with its columns — this is what the
        // rails actually are once SwiftUI has resolved them.
        var splits: [NSSplitView] = []
        collectSplitViews(in: content, into: &splits)
        for (i, split) in splits.enumerated() {
            let inWindow = split.convert(split.bounds, to: nil)
            lines.append("chrome[\(tag)] split#\(i) frameInWindow=\(short(inWindow)) "
                + "arranged=\(split.arrangedSubviews.count)")
            for (j, column) in split.arrangedSubviews.enumerated() {
                let f = column.convert(column.bounds, to: nil)
                // Window coordinates are bottom-left origin, so a column that
                // reaches into the titlebar has maxY above contentLayoutRect's.
                let intrudes = f.maxY > layout.maxY + 0.5
                lines.append("chrome[\(tag)]   col\(j) \(short(f)) "
                    + "class=\(type(of: column)) "
                    + "underTitlebar=\(intrudes ? "YES (+\(round(f.maxY - layout.maxY))pt)" : "no")")
            }
        }
        // Frames only. Anything that needs to know what was *drawn* uses
        // `screencapture -l <windowID>` (see the note above) — never an
        // in-process snapshot, which cannot render the materials in question.
        append(lines.joined(separator: "\n") + "\n")
    }

    private static func collectSplitViews(in view: NSView, into found: inout [NSSplitView]) {
        if let split = view as? NSSplitView { found.append(split) }
        for sub in view.subviews { collectSplitViews(in: sub, into: &found) }
    }

    private static func describe(_ style: NSWindow.ToolbarStyle) -> String {
        switch style {
        case .automatic: "automatic"
        case .expanded: "expanded"
        case .preference: "preference"
        case .unified: "unified"
        case .unifiedCompact: "unifiedCompact"
        @unknown default: "unknown"
        }
    }

    private static func short(_ r: CGRect) -> String {
        "(\(round(r.origin.x)),\(round(r.origin.y)) \(round(r.width))x\(round(r.height)))"
    }

    private static func round(_ v: CGFloat) -> Int { Int(v.rounded()) }

    private static func append(_ text: String) {
        guard let url = logURL, let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
#endif
