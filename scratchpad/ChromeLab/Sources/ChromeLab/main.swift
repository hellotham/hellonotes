//
//  ChromeLab
//
//  Headless bench for one question: what actually stops a SwiftUI
//  `NavigationSplitView`'s columns being laid out under the window titlebar?
//
//  Each candidate gets its own window, built the same way, never ordered front.
//  We lay it out, let AppKit settle, then measure. No screenshots, no relaunches,
//  no looking.
//

import AppKit
import SwiftUI

// MARK: - The shell under test
//
// The same *shape* as AdaptiveShell: a three-column NavigationSplitView with an
// inspector. Content is deliberately trivial — this is about chrome geometry,
// not about what the columns hold. Each column paints an opaque colour so that
// "does it reach into the titlebar" is a question about real drawn pixels.

struct LabShell: View {
    /// Applies `.toolbarBackgroundVisibility` to the detail column.
    var opaqueToolbar: Bool
    /// Insets each column's content below the titlebar band.
    var contentInset: CGFloat

    var body: some View {
        NavigationSplitView {
            column(.systemPurple, "rail")
                .navigationSplitViewColumnWidth(min: 64, ideal: 64, max: 64)
        } content: {
            column(.systemTeal, "list")
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 340)
        } detail: {
            let detail = column(.systemOrange, "editor")
                .inspector(isPresented: .constant(true)) {
                    column(.systemPink, "inspector")
                        .inspectorColumnWidth(min: 220, ideal: 280, max: 360)
                }
                .toolbar {
                    ToolbarItem { Image(systemName: "magnifyingglass") }
                }
            if opaqueToolbar {
                detail.toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            } else {
                detail
            }
        }
    }

    private func column(_ color: NSColor, _ label: String) -> some View {
        Color(nsColor: color)
            .overlay(alignment: .top) { Text(label).padding(4) }
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: contentInset)
            }
    }
}

/// The redesign under test: three columns as an `HSplitView` of ordinary views.
/// Nothing here is a `sidebar`, so nothing gets the full-height treatment.
struct HSplitShell: View {
    var body: some View {
        HSplitView {
            Color(nsColor: .systemPurple).frame(width: 64)
            Color(nsColor: .systemTeal).frame(minWidth: 220, idealWidth: 280, maxWidth: 340)
            Color(nsColor: .systemOrange).frame(maxWidth: .infinity)
            Color(nsColor: .systemPink).frame(width: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar { ToolbarItem { Image(systemName: "magnifyingglass") } }
    }
}

// MARK: - Candidates

struct Candidate {
    let name: String
    /// Style mask the window is *created* with.
    var fullSizeContentView: Bool = true
    var titlebarTransparent: Bool = false
    var toolbarStyle: NSWindow.ToolbarStyle = .automatic
    var opaqueToolbar: Bool = false
    /// Applied after the window exists and SwiftUI has laid out once — the
    /// timing the app was using.
    var stripFullSizeAfterLayout: Bool = false
    /// Set `allowsFullHeightLayout = false` on every reachable split item.
    var clearFullHeightItems: Bool = false
    /// Inset the columns' own content instead of moving the columns.
    var contentInset: CGFloat = 0
    /// Put `.fullSizeContentView` *back* after stripping it, to model SwiftUI
    /// re-applying its own window style — which is what the app measured.
    var reapplyAfterStrip: Bool = false
    /// Install an observer that re-strips the flag whenever the window updates.
    var reassertingObserver: Bool = false
    /// Skip the `layoutIfNeeded()` after stripping, to find out whether the
    /// re-layout — rather than the flag itself — is what moves the columns.
    var skipLayoutAfterStrip: Bool = false
    /// Resize the content view to `contentLayoutRect` explicitly.
    var resizeContentView: Bool = false
    /// Build the shell from `HSplitView` instead of `NavigationSplitView`.
    var useHSplit: Bool = false
    /// Host through a `contentViewController`, the way SwiftUI's `WindowGroup`
    /// does, rather than assigning `contentView` directly. This is the fidelity
    /// the first bench lacked: with a content *view* the strip alone works, and
    /// the app — which has a content view *controller* — measured no change.
    var useContentViewController: Bool = false
}

let candidates: [Candidate] = [
    Candidate(name: "1 baseline (as the app is today)"),
    Candidate(name: "2 opaque toolbar on detail", opaqueToolbar: true),
    Candidate(name: "3 no fullSizeContentView at creation", fullSizeContentView: false),
    Candidate(name: "4 strip fullSizeContentView after layout", stripFullSizeAfterLayout: true),
    Candidate(name: "5 toolbarStyle = .expanded", toolbarStyle: .expanded),
    Candidate(name: "6 toolbarStyle = .unified", toolbarStyle: .unified),
    Candidate(name: "7 toolbarStyle = .preference", toolbarStyle: .preference),
    Candidate(name: "8 allowsFullHeightLayout = false", clearFullHeightItems: true),
    Candidate(name: "9 no fullSize + expanded toolbar",
              fullSizeContentView: false, toolbarStyle: .expanded),
    Candidate(name: "10 content inset 52pt (columns stay, content moves)", contentInset: 52),
    // 11 models the app exactly: strip the flag, then have something put it
    // back — which is the only explanation for the app measuring no change
    // when the bench says stripping works.
    Candidate(name: "11 strip, then something re-applies it",
              stripFullSizeAfterLayout: true, reapplyAfterStrip: true),
    Candidate(name: "12 strip + re-asserting observer",
              stripFullSizeAfterLayout: true, reapplyAfterStrip: true,
              reassertingObserver: true),
    // 13 and 14 isolate what the app is missing: its flag is off (the observer
    // works) and yet the overlap stays 52pt, so the *re-layout* must be the
    // part that actually moves the columns.
    Candidate(name: "13 strip, no re-layout", stripFullSizeAfterLayout: true,
              skipLayoutAfterStrip: true),
    Candidate(name: "14 strip, no re-layout, resize content view",
              stripFullSizeAfterLayout: true, skipLayoutAfterStrip: true,
              resizeContentView: true),
    Candidate(name: "15 [VC] baseline", useContentViewController: true),
    Candidate(name: "16 [VC] strip + observer",
              stripFullSizeAfterLayout: true, reapplyAfterStrip: true,
              reassertingObserver: true, useContentViewController: true),
    Candidate(name: "17 [VC] strip + observer + resize content view",
              stripFullSizeAfterLayout: true, reapplyAfterStrip: true,
              reassertingObserver: true, resizeContentView: true,
              useContentViewController: true),
    Candidate(name: "18 [VC] no fullSize at creation",
              fullSizeContentView: false, useContentViewController: true),
    // 19/20: the redesign. No NavigationSplitView at all — an HSplitView of
    // plain views, where no column is a "sidebar" and none gets full-height
    // behaviour. If this measures clean without any window surgery, the whole
    // class of problem is a consequence of the container, not of our content.
    Candidate(name: "19 HSplitView shell (no NavigationSplitView)", useHSplit: true),
    Candidate(name: "20 HSplitView + no fullSize", fullSizeContentView: false, useHSplit: true),
]

/// Re-removes `.fullSizeContentView` every time the window updates, so a later
/// re-application by the framework does not undo it. Retained for the window's
/// lifetime by the array below.
final class TitlebarClearanceObserver: NSObject {
    private var tokens: [NSObjectProtocol] = []

    init(window: NSWindow) {
        super.init()
        let names: [Notification.Name] = [
            NSWindow.didUpdateNotification,
            NSWindow.didResizeNotification,
            NSWindow.didBecomeKeyNotification,
        ]
        tokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window,
                                                    queue: .main) { note in
                guard let w = note.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    if w.styleMask.contains(.fullSizeContentView) {
                        w.styleMask.remove(.fullSizeContentView)
                    }
                }
            }
        }
    }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}

enum ObserverBox { @MainActor static var kept: [TitlebarClearanceObserver] = [] }

// MARK: - Measurement

struct Result {
    let name: String
    let overlap: CGFloat
    let columnsUnderTitlebar: Int
    let columns: Int
    let splitItemsSeen: Int
    var passes: Bool { overlap < 0.5 && columnsUnderTitlebar == 0 }
}

@MainActor
func measure(_ candidate: Candidate) -> Result {
    var mask: NSWindow.StyleMask = [.titled, .closable, .resizable]
    if candidate.fullSizeContentView { mask.insert(.fullSizeContentView) }

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1470, height: 859),
                          styleMask: mask, backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = candidate.titlebarTransparent
    window.toolbarStyle = candidate.toolbarStyle
    let toolbar = NSToolbar(identifier: "lab")
    toolbar.displayMode = .iconOnly
    window.toolbar = toolbar

    let root = AnyView(candidate.useHSplit
        ? AnyView(HSplitShell())
        : AnyView(LabShell(opaqueToolbar: candidate.opaqueToolbar,
                           contentInset: candidate.contentInset)))
    if candidate.useContentViewController {
        window.contentViewController = NSHostingController(rootView: root)
    } else {
        let hosting = NSHostingView(rootView: root)
        window.contentView = hosting
        hosting.frame = window.contentView?.bounds ?? .zero
    }
    window.layoutIfNeeded()
    settle(0.35)

    if candidate.reassertingObserver {
        ObserverBox.kept.append(TitlebarClearanceObserver(window: window))
    }

    if candidate.stripFullSizeAfterLayout {
        window.styleMask.remove(.fullSizeContentView)
        window.titlebarAppearsTransparent = false
        if !candidate.skipLayoutAfterStrip { window.layoutIfNeeded() }
        if candidate.resizeContentView {
            window.contentView?.frame = window.contentLayoutRect
            window.contentView?.needsLayout = true
        }
        settle(0.25)
    }

    if candidate.reapplyAfterStrip {
        // Whatever SwiftUI does, it ends up back on. Model it, then let the
        // window update so an observer (candidate 12) gets its chance.
        window.styleMask.insert(.fullSizeContentView)
        window.layoutIfNeeded()
        window.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                                            modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil,
                                            subtype: 0, data1: 0, data2: 0)!, atStart: false)
        settle(0.35)
    }

    var itemsSeen = 0
    if candidate.clearFullHeightItems {
        for controller in splitViewControllers(of: window) {
            for item in controller.splitViewItems {
                itemsSeen += 1
                item.allowsFullHeightLayout = false
            }
        }
        window.layoutIfNeeded()
        settle(0.25)
    }

    // Measure.
    let content = window.contentView!
    let layout = window.contentLayoutRect
    let overlap = max(0, content.bounds.height - layout.height)

    var columns = 0, under = 0
    for split in splitViews(in: content) {
        for column in split.arrangedSubviews {
            columns += 1
            let f = column.convert(column.bounds, to: nil)
            if f.maxY > layout.maxY + 0.5 { under += 1 }
        }
    }

    window.close()
    return Result(name: candidate.name, overlap: overlap, columnsUnderTitlebar: under,
                  columns: columns, splitItemsSeen: itemsSeen)
}

@MainActor
func settle(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

@MainActor
func splitViews(in view: NSView) -> [NSSplitView] {
    var found: [NSSplitView] = []
    func walk(_ v: NSView) {
        if let s = v as? NSSplitView { found.append(s) }
        v.subviews.forEach(walk)
    }
    walk(view)
    return found
}

@MainActor
func splitViewControllers(of window: NSWindow) -> [NSSplitViewController] {
    var found: [NSSplitViewController] = []
    func walkController(_ c: NSViewController) {
        if let s = c as? NSSplitViewController { found.append(s) }
        c.children.forEach(walkController)
    }
    if let root = window.contentViewController { walkController(root) }
    // Also try the responder chain from each split view, which is where a
    // controller hides when it is not a child of contentViewController.
    if let content = window.contentView {
        for split in splitViews(in: content) {
            var responder: NSResponder? = split
            while let r = responder {
                if let c = r as? NSSplitViewController, !found.contains(where: { $0 === c }) {
                    found.append(c)
                }
                responder = r.nextResponder
            }
        }
    }
    return found
}

// MARK: - Run

/// `String(format:)` with `%s` takes a *C* string; handing it a Swift `String`
/// bridges to an object pointer and segfaults before a single line prints —
/// which is exactly how this bench failed on its first run.
func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? String(s.prefix(width)) : s + String(repeating: " ", count: width - s.count)
}

func rpad(_ s: String, _ width: Int) -> String {
    s.count >= width ? String(s.prefix(width)) : String(repeating: " ", count: width - s.count) + s
}

@MainActor
func run() {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)   // never comes to the front

    print("ChromeLab — which configuration keeps the columns out of the titlebar?")
    print(String(repeating: "─", count: 88))
    print(pad("candidate", 48) + rpad("overlap", 10) + rpad("cols under", 12)
          + rpad("cols", 6) + rpad("items", 7) + "  verdict")
    print(String(repeating: "─", count: 88))

    var results: [Result] = []
    for candidate in candidates {
        let r = measure(candidate)
        results.append(r)
        print(pad(r.name, 48)
              + rpad("\(Int(r.overlap))pt", 10)
              + rpad("\(r.columnsUnderTitlebar)", 12)
              + rpad("\(r.columns)", 6)
              + rpad("\(r.splitItemsSeen)", 7)
              + "  " + (r.passes ? "PASS" : "no"))
    }

    print(String(repeating: "─", count: 88))
    let winners = results.filter(\.passes)
    if winners.isEmpty {
        print("No candidate keeps the columns out of the titlebar band.")
        print("If every column is still under it, the columns cannot be moved from")
        print("SwiftUI, and the only honest fix is to inset the columns' own content")
        print("(candidate 10) or to stop using NavigationSplitView for the shell.")
    } else {
        print("Passing: " + winners.map(\.name).joined(separator: ", "))
    }
    exit(winners.isEmpty ? 1 : 0)
}

// `--app` runs the *real* thing: a SwiftUI `App` with a `WindowGroup`, which is
// how HelloNotes' window is actually made. The VC model above still was not
// faithful enough — candidate 16 passes there while the app measures 52pt — so
// the last unmodelled difference is SwiftUI building and owning the window.
if CommandLine.arguments.contains("--rail") {
    MainActor.assumeIsolated { RailApp.main() }
} else if CommandLine.arguments.contains("--app") {
    MainActor.assumeIsolated { LabApp.main() }
} else {
    MainActor.assumeIsolated { run() }
}


// MARK: - The faithful model: a real SwiftUI App

struct LabApp: App {
    var body: some Scene {
        WindowGroup {
            LabShell(opaqueToolbar: false, contentInset: 0)
                .background(ClearanceInstaller(strip: CommandLine.arguments.contains("--strip")))
                .background(AppMeasurer())
        }
    }
}

/// Clears the flag from inside the *layout pass*, not after it.
///
/// `didUpdate` fires after AppKit has already laid the window out, so removing
/// the flag there is a tug-of-war with SwiftUI, which re-applies it: the app
/// settles with the flag off and the layout still computed as though it were on.
/// A view's `layout()` runs *during* every pass, so clearing it here means the
/// flag is off at the moment the geometry is decided.
final class LayoutHookView: NSView {
    override func layout() {
        if let w = window, w.styleMask.contains(.fullSizeContentView) {
            w.styleMask.remove(.fullSizeContentView)
            w.titlebarAppearsTransparent = false
        }
        super.layout()
    }
}

struct LayoutHookInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { LayoutHookView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func sizeThatFits(_ p: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? { .zero }
}

/// The mechanism under test, exactly as the app ships it.
struct ClearanceInstaller: NSViewRepresentable {
    let strip: Bool

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        context.coordinator.attach(to: v, strip: strip)
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView, strip: strip)
    }
    func makeCoordinator() -> C { C() }
    func sizeThatFits(_ p: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? { .zero }

    @MainActor final class C {
        private var tokens: [NSObjectProtocol] = []
        private weak var window: NSWindow?

        func attach(to view: NSView, strip: Bool) {
            guard strip else { return }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let w = view?.window, w !== self.window else { return }
                self.window = w
                self.clear(w)
                let names: [Notification.Name] = [.init("NSWindowDidUpdateNotification"),
                                                   NSWindow.didResizeNotification,
                                                   NSWindow.didBecomeKeyNotification]
                self.tokens = names.map { n in
                    NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { note in
                        guard let w = note.object as? NSWindow else { return }
                        MainActor.assumeIsolated { self.clear(w) }
                    }
                }
            }
        }

        private func clear(_ w: NSWindow) {
            guard w.styleMask.contains(.fullSizeContentView) else { return }
            w.styleMask.remove(.fullSizeContentView)
            w.titlebarAppearsTransparent = false
        }
    }
}

/// Samples actual rendered pixels in the titlebar band.
///
/// Every previous metric measured *wrapper view frames*, which is why it kept
/// disagreeing with what a person sees: a wrapper can be full height while
/// nothing of the column is drawn up there, and vice versa. The columns are
/// painted in distinct colours, so "is a column bleeding into the toolbar row"
/// is answerable exactly — read the pixel.
@MainActor
func columnColourInTitlebarBand(_ window: NSWindow) -> String {
    guard let content = window.contentView else { return "no content view" }
    let band = max(0, content.bounds.height - window.contentLayoutRect.height)
    guard band > 0 else { return "no titlebar band at all" }

    guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
        return "could not snapshot"
    }
    content.cacheDisplay(in: content.bounds, to: rep)

    // Sample a few points across the band, in view coordinates. The content
    // view is flipped-from-bottom, so the band is at the TOP = high y.
    let ys = [content.bounds.height - 6, content.bounds.height - band / 2]
    let xs: [(String, CGFloat)] = [("rail", 30), ("list", 240), ("editor", 700), ("inspector", 1350)]
    var hits: [String] = []
    for (name, x) in xs where x < content.bounds.width {
        for y in ys {
            guard let c = rep.colorAt(x: Int(x), y: Int(content.bounds.height - y)) else { continue }
            let rgb = c.usingColorSpace(.sRGB)
            guard let rgb else { continue }
            // The lab colours are saturated; window chrome is not.
            let sat = rgb.saturationComponent
            if sat > 0.35 { hits.append(name); break }
        }
    }
    return hits.isEmpty
        ? "band \(Int(band))pt: NO column colour in it — clean"
        : "band \(Int(band))pt: column colour present at [\(hits.joined(separator: ", "))] — BLEEDING"
}

/// Measures the real window a second after it exists, prints, and exits.
struct AppMeasurer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak v] in
            MainActor.assumeIsolated {
                guard let w = v?.window, let content = w.contentView else {
                    print("no window"); exit(2)
                }
                let layout = w.contentLayoutRect
                let overlap = max(0, content.bounds.height - layout.height)
                var cols = 0, under = 0
                for split in splitViews(in: content) {
                    for c in split.arrangedSubviews {
                        cols += 1
                        if c.convert(c.bounds, to: nil).maxY > layout.maxY + 0.5 { under += 1 }
                    }
                }
                let mode = CommandLine.arguments.contains("--layouthook") ? "layout hook"
                         : CommandLine.arguments.contains("--strip") ? "strip+observer" : "baseline"
                print("[WindowGroup \(mode)] PIXELS → \(columnColourInTitlebarBand(w))")
                print("[WindowGroup \(mode)] styleMask=0x\(String(w.styleMask.rawValue, radix: 16)) "
                      + "contentVC=\(w.contentViewController.map { String(describing: type(of: $0)) } ?? "nil") "
                      + "fullSize=\(w.styleMask.contains(.fullSizeContentView)) "
                      + "overlap=\(Int(overlap))pt columnsUnder=\(under)/\(cols) "
                      + (overlap < 0.5 && under == 0 ? "PASS" : "FAIL"))
                exit(0)
            }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func sizeThatFits(_ p: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? { .zero }
}


// MARK: - Rail bench
//
// The remaining question, asked precisely: does the rail's *first row* clear the
// titlebar? A sidebar `List` gets AppKit's titlebar content-inset for free — but
// the app's rail is `VStack { List; footer }`, so the List is no longer the
// column's root view, and the inset may not survive that. Measure both.

struct RailApp: App {
    var body: some Scene {
        WindowGroup {
            RailShell(wrapped: CommandLine.arguments.contains("--wrapped"))
                .background(ClearanceInstaller(strip: !CommandLine.arguments.contains("--nostrip")))
                .background(RailMeasurer())
        }
    }
}

struct RailShell: View {
    /// true = the app's shape (List inside a VStack with a pinned footer).
    let wrapped: Bool

    var body: some View {
        NavigationSplitView {
            Group {
            if wrapped {
                // What the rail was: List inside a VStack with the footer.
                VStack(spacing: 0) {
                    rows
                    Divider()
                    Text("git").frame(maxWidth: .infinity).padding(.vertical, 8)
                }
            } else {
                // What was just shipped without proof: List as the root, footer
                // as a bottom safe-area inset.
                rows.safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        Divider()
                        Text("git").frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                }
            }
            }
            // The app pins its rail to 64pt. A default-width sidebar was not a
            // faithful model — and this is the last unmodelled difference.
            .navigationSplitViewColumnWidth(min: 64, ideal: 64, max: 64)
        } detail: {
            Color(nsColor: .systemOrange)
                .toolbar { ToolbarItem { Image(systemName: "magnifyingglass") } }
        }
    }

    private var rows: some View {
        List {
            ForEach(0..<6) { i in
                Text("row \(i)")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    // A saturated chip, like the rail's selection background —
                    // this is the thing that lands on the traffic lights.
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .systemPurple)))
                    .accessibilityIdentifier(i == 0 ? "rail.firstRow" : "rail.row")
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: CommandLine.arguments.contains("--shortfall") ? shortfall : 0)
        }
        .frame(maxHeight: .infinity)
    }

    /// The part of the titlebar band AppKit's automatic inset does *not* cover.
    /// Measured, so it is 0 when there is no band and 0 when AppKit already
    /// covered it — it cannot double-inset.
    @State private var shortfall: CGFloat = 0
}

struct RailMeasurer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                guard let w = v.window, let content = w.contentView else { print("no window"); exit(2) }

                // Measure the thing that actually decides this, rather than
                // guessing at which subview is "the first row": AppKit gives a
                // source list an automatic top content inset the height of the
                // titlebar. If that inset is there, the rows clear the traffic
                // lights. If it is zero, they do not. The previous heuristic
                // ("topmost smallish view in the left column") returned the same
                // number for both shapes and proved nothing.
                var reports: [String] = []
                for scroll in scrollViews(in: content) {
                    let f = scroll.convert(scroll.bounds, to: nil)
                    guard f.minX < 200 else { continue }   // the sidebar column
                    reports.append("top=\(Int(scroll.contentInsets.top))pt "
                        + "auto=\(scroll.automaticallyAdjustsContentInsets)")
                }
                print("[rail PIXELS] " + railChipInBand(w))
                let shape = (CommandLine.arguments.contains("--wrapped")
                    ? "VStack{List,footer}" : "List+bottomInset")
                    + (CommandLine.arguments.contains("--nostrip") ? " [no clearance]" : " [clearance]")
                let inset = reports.first ?? "no sidebar scroll view found"
                let overlap = Int(max(0, content.bounds.height - w.contentLayoutRect.height))
                print("[rail \(shape)] \(inset)  windowOverlap=\(overlap)pt")
                exit(0)
            }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func sizeThatFits(_ p: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? { .zero }
}

/// Is a saturated chip drawn in the titlebar band of the *rail* column?
@MainActor
func railChipInBand(_ window: NSWindow) -> String {
    guard let content = window.contentView else { return "no content view" }
    let band = max(0, content.bounds.height - window.contentLayoutRect.height)
    guard band > 0 else { return "no band" }
    guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return "?" }
    content.cacheDisplay(in: content.bounds, to: rep)
    for y in stride(from: 2.0, through: band - 2, by: 4.0) {
        guard let c = rep.colorAt(x: 40, y: Int(y))?.usingColorSpace(.sRGB) else { continue }
        if c.saturationComponent > 0.35 {
            return "band \(Int(band))pt: CHIP IN BAND at \(Int(y))pt from top — BLEEDING"
        }
    }
    return "band \(Int(band))pt: no chip in band — clean"
}

@MainActor
func scrollViews(in view: NSView) -> [NSScrollView] {
    var found: [NSScrollView] = []
    func walk(_ v: NSView) {
        if let s = v as? NSScrollView { found.append(s) }
        v.subviews.forEach(walk)
    }
    walk(view)
    return found
}
