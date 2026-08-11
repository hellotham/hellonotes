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

            // Removing the flag is not enough on its own: the app settles with
            // it off and *still* reports a 52pt band, because SwiftUI keeps
            // re-applying its window configuration. So inset the safe area by
            // whatever band survives, which is the supported way to tell every
            // view inside — including the sidebar's material — to lay out below
            // the titlebar rather than behind it.
            guard let content = window.contentView else { return }
            let band = max(0, content.bounds.height - window.contentLayoutRect.height)
            if abs(content.additionalSafeAreaInsets.top - band) > 0.5 {
                content.additionalSafeAreaInsets.top = band
            }
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

    /// Samples rendered pixels in the titlebar band, per column.
    ///
    /// Every frame-based metric here disagreed with what the user could see —
    /// a wrapper view can be full height with nothing of the column drawn in
    /// the band, which is exactly what the bench proved. Pixels are the only
    /// measurement that corresponds to the complaint. For each column region it
    /// reports the colour *inside* the band and the colour just *below* it: the
    /// same colour twice means that column's content is drawn up there.
    @MainActor
    static func samplePixels(window: NSWindow, tag: String) {
        guard enabled, let content = window.contentView else { return }
        let band = max(0, content.bounds.height - window.contentLayoutRect.height)
        guard band > 2,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)

        // The rep is in *pixels*; everything else here is in points. On a
        // Retina display that is a factor of two, and sampling point
        // coordinates into a pixel buffer reads somewhere else entirely —
        // which is how this probe came to report a clean rail while the
        // window's own snapshot showed it white. Scale, or measure nothing.
        let scale = CGFloat(rep.pixelsWide) / max(1, content.bounds.width)
        func hex(_ xPoints: CGFloat, _ yPoints: CGFloat) -> String {
            let x = Int(xPoints * scale), y = Int(yPoints * scale)
            guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh,
                  let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return "----" }
            return String(format: "%02X%02X%02X",
                          Int(c.redComponent * 255), Int(c.greenComponent * 255),
                          Int(c.blueComponent * 255))
        }

        // Column regions, by the widths the shell actually uses.
        let width = content.bounds.width
        let probes: [(String, CGFloat)] = [
            ("rail", 32),
            ("list", ShellMetrics.railWidth + 120),
            ("editor", width * 0.5),
            ("inspector", width - 60),
        ]
        let inBand = band / 2                      // middle of the band
        let below = band + 12                      // just under it
        let line = probes.filter { $0.1 < width }.map { name, x in
            "\(name)=\(hex(x, inBand))/\(hex(x, below))"
        }.joined(separator: " ")
        append("chrome[\(tag)] pixels band=\(Int(band))pt (inBand/below) \(line)\n")
    }

    /// Writes the window's own rendered contents to a PNG beside the log.
    /// Only this window, no screen-recording permission, nothing of anyone
    /// else's screen — the app photographing itself.
    @MainActor
    static func snapshot(window: NSWindow?, tag: String) {
        guard enabled, let window, let content = window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]),
              let url = logURL?.deletingLastPathComponent()
                  .appendingPathComponent("hn-window-\(tag).png") else { return }
        try? data.write(to: url)
        append("chrome[\(tag)] snapshot written to \(url.path)\n")
    }

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
        append(lines.joined(separator: "\n") + "\n")
        samplePixels(window: window, tag: tag)
        snapshot(window: window, tag: tag)
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
