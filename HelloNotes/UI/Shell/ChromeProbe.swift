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
        // After layout settles: the split view has no useful frames before it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak view] in
            ChromeProbeLog.dump(window: view?.window, tag: "appear")
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Zero-sized: it is an observer, not a participant in layout (S1/S2).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView,
                      context: Context) -> CGSize? { .zero }
}

/// Stops the split-view columns being laid out beneath the window's titlebar.
///
/// The probe measured the problem exactly: `contentLayoutRect` is 52pt shorter
/// than the content view, and *every* column — rail, note list, editor,
/// inspector — is full height, so all four paint those 52pt up under the
/// titlebar. That is what "the sidebar background bleeds into the toolbar row"
/// and "the rail's rounded border overlaps the window controls" both are. No
/// background or toolbar modifier can undo it, because the columns really are
/// up there; and taking `.fullSizeContentView` off the window changed nothing
/// (measured: flag off, overlap still 52pt).
///
/// `NSSplitViewItem.allowsFullHeightLayout` is the actual control — "whether
/// the split view item can be laid out beneath the window's titlebar" — and
/// SwiftUI exposes no equivalent, which is why three attempts from that side
/// all missed. `titlebarSeparatorStyle = .line` then draws the rule under the
/// toolbar that makes it read as its own row.
struct TitlebarClearance: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        apply(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // SwiftUI rebuilds and re-styles its split view controllers, so this is
        // re-asserted rather than assumed to have stuck the first time.
        apply(from: nsView)
    }

    /// Zero-sized: an observer, never a participant in layout (S1/S2).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView,
                      context: Context) -> CGSize? { .zero }

    private func apply(from view: NSView) {
        // A hop, because the window and the split view controllers do not exist
        // yet on the first pass.
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window, let content = window.contentView else { return }
            window.titlebarSeparatorStyle = .line
            for controller in splitViewControllers(in: content) {
                for item in controller.splitViewItems where item.allowsFullHeightLayout {
                    item.allowsFullHeightLayout = false
                    item.titlebarSeparatorStyle = .line
                }
            }
        }
    }

    /// Every `NSSplitViewController` in the window. Found through the split
    /// views themselves, since SwiftUI does not hand its controllers over.
    private func splitViewControllers(in view: NSView) -> [NSSplitViewController] {
        var found: [NSSplitViewController] = []
        func walk(_ v: NSView) {
            if let split = v as? NSSplitView,
               let controller = split.delegate as? NSSplitViewController,
               !found.contains(where: { $0 === controller }) {
                found.append(controller)
            }
            v.subviews.forEach(walk)
        }
        walk(view)
        return found
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

    @MainActor
    static func dump(window: NSWindow?, tag: String) {
        guard enabled, let window, let content = window.contentView else { return }

        var lines: [String] = []
        let mask = window.styleMask
        lines.append("chrome[\(tag)] "
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
