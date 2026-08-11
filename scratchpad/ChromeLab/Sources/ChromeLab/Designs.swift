//
//  Designs.swift — candidate shell layouts, rendered to PNGs.
//
//  This exists because every previous attempt at the shell's chrome was made
//  *in the app* and checked by relaunching and looking. The process this
//  project uses (and that I kept abandoning) is: build the layout in a test
//  app, look at it there, iterate until it is right, and only then port it.
//
//      swift run ChromeLab --design 1     → /tmp/hn-design-1.png
//
//  Each design is a real SwiftUI `App` with a `WindowGroup`, because that is
//  what HelloNotes uses and nothing less faithful reproduced its behaviour.
//  The window is never ordered front; the snapshot is the window rendering
//  itself.
//
//  The target, in the user's words, is Mail: "the message list is full height —
//  there is no top row, and the title ('Inbox') is part of the panel. the
//  toolbar sits on top of the message window."
//

import AppKit
import SwiftUI

// MARK: - Shared pieces

/// The 64pt icon rail. `topClearance` is the band left empty for the window's
/// traffic lights — the thing that makes a full-height sidebar read as
/// deliberate rather than as content shoved under the window controls.
struct DesignRail: View {
    var topClearance: CGFloat
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(["books.vertical.fill", "folder.fill", "plus"], id: \.self) { symbol in
                        VStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(symbol == "folder.fill" ? Color.accentColor.opacity(0.18) : .clear)
                                .frame(width: 40, height: 30)
                                .overlay { Image(systemName: symbol).font(.system(size: 15)) }
                            Text(symbol == "books.vertical.fill" ? "Library"
                                 : symbol == "folder.fill" ? "My Vault" : "Open")
                                .font(.system(size: 9))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 6)
            }
            .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: topClearance) }
            Spacer(minLength: 0)
        }
    }
}

/// The note list. `inPanelTitle` puts "My Vault" *inside* the panel, Mail-style,
/// instead of in the window's titlebar.
struct DesignList: View {
    var inPanelTitle: Bool
    var topClearance: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            if inPanelTitle {
                HStack {
                    Text("My Vault").font(.headline)
                    Spacer()
                    Image(systemName: "arrow.up.arrow.down")
                    Image(systemName: "square.and.pencil")
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .padding(.top, topClearance)
                Divider()
            }
            List(0..<12, id: \.self) { i in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Note \(i)").font(.headline)
                    Text("12 August 2026").font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        }
    }
}

struct DesignEditor: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("A Note Title").font(.largeTitle.bold())
                ForEach(0..<12, id: \.self) { _ in
                    Text("The quick brown fox jumps over the lazy dog. " +
                         "The quick brown fox jumps over the lazy dog.")
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - The candidates

struct DesignApp: App {
    static var index: Int {
        guard let i = CommandLine.arguments.firstIndex(of: "--design"),
              i + 1 < CommandLine.arguments.count,
              let n = Int(CommandLine.arguments[i + 1]) else { return 1 }
        return n
    }

    /// `--width 860` judges the chrome at P2's laptop, where the band is tight
    /// enough to force the framework's own collapse decisions into the open.
    static var width: CGFloat {
        guard let i = CommandLine.arguments.firstIndex(of: "--width"),
              i + 1 < CommandLine.arguments.count,
              let n = Double(CommandLine.arguments[i + 1]) else { return 1470 }
        return CGFloat(n)
    }

    var body: some Scene {
        WindowGroup {
            candidate
                .background(DesignSnapshot(
                    name: "design-\(Self.index)-\(Int(Self.width))",
                    size: CGSize(width: Self.width, height: 860)
                ))
        }
    }

    @ViewBuilder
    private var candidate: some View {
        switch Self.index {
        case 1:
            // 1 — the app as it is: three columns, toolbar items on the list,
            //     no clearance anywhere. The baseline to compare against.
            NavigationSplitView {
                DesignRail(topClearance: 0)
                    .navigationSplitViewColumnWidth(min: 64, ideal: 64, max: 64)
            } content: {
                DesignList(inPanelTitle: false, topClearance: 0)
                    .navigationTitle("My Vault")
                    .toolbar { ToolbarItem { Image(systemName: "arrow.up.arrow.down") } }
                    .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 340)
            } detail: {
                DesignEditor()
                    .toolbar { ToolbarItem { Image(systemName: "sparkles") } }
            }

        case 2:
            // 2 — Mail's shape: panels full height, title inside the list panel,
            //     traffic-light clearance on both left panels, toolbar items
            //     only on the detail pane.
            NavigationSplitView {
                DesignRail(topClearance: 52)
                    .navigationSplitViewColumnWidth(min: 64, ideal: 64, max: 64)
            } content: {
                DesignList(inPanelTitle: true, topClearance: 52)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 340)
            } detail: {
                DesignEditor()
                    .toolbar { ToolbarItem { Image(systemName: "sparkles") } }
            }

        case 3:
            // 3 — as 2, but the rail folded into the list panel as a leading
            //     strip, so the window has two columns rather than three.
            NavigationSplitView {
                HStack(spacing: 0) {
                    DesignRail(topClearance: 52).frame(width: 64)
                    Divider()
                    DesignList(inPanelTitle: true, topClearance: 52)
                }
                .navigationSplitViewColumnWidth(min: 284, ideal: 344, max: 404)
            } detail: {
                DesignEditor()
                    .toolbar { ToolbarItem { Image(systemName: "sparkles") } }
            }

        case 4:
            // Three columns, no custom toolbar items at all. Where does SwiftUI
            // put its automatic sidebar toggle — column 1's edge, or nowhere?
            NavigationSplitView {
                DesignRail(topClearance: 52)
                    .navigationSplitViewColumnWidth(min: 84, ideal: 84, max: 84)
            } content: {
                DesignList(inPanelTitle: false, topClearance: 0)
                    .navigationTitle("My Vault")
                    .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 340)
            } detail: {
                DesignEditor()
                    .searchable(text: .constant(""), prompt: "Search all collections")
            }

        case 5:
            // Two columns: rail folded into the list column as a leading strip,
            // so the *collapsible* panel is column 1 and gets the free toggle at
            // its trailing edge — the finvestlens position, which our three
            // column shape cannot reach.
            NavigationSplitView {
                HStack(spacing: 0) {
                    DesignRail(topClearance: 52).frame(width: 84)
                    Divider()
                    DesignList(inPanelTitle: false, topClearance: 0)
                }
                .navigationSplitViewColumnWidth(min: 304, ideal: 364, max: 424)
            } detail: {
                DesignEditor()
                    .searchable(text: .constant(""), prompt: "Search all collections")
            }

        case 6:
            // 6 — THE DECIDED DESIGN (docs/shell-chrome.md Part 4). Everything
            //     the previous twenty attempts got wrong reduces to one thing:
            //     the panel that collapses was not column one. Here it is.
            //
            //     Four claims are under test, and each has a defect it prevents:
            //       a. the free toggle lands at the sidebar's trailing edge
            //          → no hand-placed button floating mid-list;
            //       b. a `.navigation`-placed action sits beside it, Notes-style
            //          → New Folder has a home that hides with the sidebar;
            //       c. five trailing toggles render over the inspector with NO
            //          `»` chevron, because `.inspector()` is not used
            //          → the three-toggles-and-a-chevron defect;
            //       d. `.searchable` stays an expanded field
            //          → the collapsed-glyph defect.
            DesignDecided()

        case 7:
            // 7 — design 6 with the sidebar hidden: P2's working configuration,
            //     and the state no earlier attempt ever checked. Two questions
            //     only a capture answers: does the toggle relocate beside the
            //     traffic lights (Mail/Notes behaviour), and does the
            //     sidebar-scoped Add action go with it rather than stranding?
            DesignDecided(columns: .detailOnly)

        case 8:
            // 8 — design 6 with `.searchable` replaced by an ordinary TextField
            //     in a toolbar item. Two measured failures force this:
            //
            //       * at 860pt (P2's laptop) `.searchable` collapses to a
            //         magnifier glyph — the exact UI-4 defect, produced by the
            //         framework, not by us. A fixed-width field cannot collapse.
            //       * `.searchable` always takes the trailing end of the band,
            //         pushing the inspector's tabs left, over the *editor*.
            //         Pages puts a panel's selectors above that panel.
            //
            //     Losing `.searchable` costs the free ⌘F binding and scopes;
            //     both are cheap to restore, and neither is worth a control that
            //     disappears at the width it is most needed.
            DesignDecided(usesSystemSearchable: false)

        case 9:
            DesignDecided(columns: .detailOnly, usesSystemSearchable: false)

        case 10:
            // 10 — search at the LEADING edge, beside the sidebar it searches.
            //      Two reasons, one from the user and one from the measurements:
            //
            //      * it reads correctly: search is about files and folders, and
            //        it now sits against the panel that holds them (Xcode's
            //        navigator filter, VS Code's search view, Obsidian's).
            //      * design 8 at 860pt overflowed search AND all five tabs into
            //        a `»`. The band is width-bound at P2's laptop, so the title
            //        goes too — Apple Notes shows no window title in the band at
            //        all, and the collection is already the sidebar's selection.
            DesignDecided(usesSystemSearchable: false, searchLeading: true)

        case 11:
            DesignDecided(columns: .detailOnly, usesSystemSearchable: false, searchLeading: true)

        default:
            Text("no such design")
        }
    }
}

// MARK: - Design 6, the decided shell

/// `.searchable` cannot be applied conditionally inline — the two branches have
/// different types — so the choice becomes a modifier.
struct MaybeSearchable: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: .constant(""), prompt: "Search all collections")
        } else {
            content
        }
    }
}

/// `.toolbar(removing: .title)` drops the title *from the band* while the window
/// keeps it for the Window menu and Mission Control.
struct MaybeTitleless: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.toolbar(removing: .title) } else { content }
    }
}

/// Collections and folders in one tree — Apple Notes' sidebar, which nests
/// folders under an account section header. Recents and Bookmarks are pinned
/// `DisclosureGroup`s above the collections rather than tabs: a writer scans
/// recents *and* walks the tree in the same minute, so hiding one behind the
/// other is a cost with no matching benefit (shell-chrome.md D4/D5).
struct DesignCollectionTree: View {
    @State private var recentsExpanded = false
    @State private var bookmarksExpanded = false

    var body: some View {
        List(selection: .constant("1 Rupa")) {
            DisclosureGroup(isExpanded: $recentsExpanded) {
                ForEach(["Torrens", "Chef Kwon"], id: \.self) { Label($0, systemImage: "doc.text") }
            } label: {
                Label("Recents", systemImage: "clock")
            }
            DisclosureGroup(isExpanded: $bookmarksExpanded) {
                ForEach(["Reading list"], id: \.self) { Label($0, systemImage: "doc.text") }
            } label: {
                Label("Bookmarks", systemImage: "bookmark")
            }

            // One `Section` per collection: the collection is a *header*, its
            // folders are the rows. Notes does exactly this with "iCloud".
            Section("My Vault") {
                ForEach(["1 Rupa", "2 Sanna", "AI", "Analayo"], id: \.self) { folder in
                    Label(folder, systemImage: "folder").tag(folder)
                }
            }
            Section("Obsidian Vault") {
                ForEach(["Daily", "Projects"], id: \.self) { folder in
                    Label(folder, systemImage: "folder").tag(folder)
                }
            }
        }
    }
}

/// The inspector as an `HStack` sibling of the editor — **not** `.inspector()`,
/// which forces a `»` chevron into the toolbar that cannot be suppressed. Its
/// tab strip lives in the toolbar (see `inspectorTabs`), so the panel itself
/// starts with content: no strip, no header row, nothing stacked.
struct DesignInspector: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("STATISTICS").font(.caption).foregroundStyle(.secondary)
                LabeledContent("Words", value: "512")
                LabeledContent("Read time", value: "2 min")
                Divider()
                Text("OUTLINE").font(.caption).foregroundStyle(.secondary)
                Text("▸ Heading one")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DesignDecided: View {
    /// Five tabs, so five toggles — Pages' `Format`/`Document` pattern scaled
    /// up. Icon-only because five labelled items would not fit beside a search
    /// field at P2's 860pt.
    private static let tabs: [(String, String)] = [
        ("Outline", "list.bullet.indent"), ("Tags", "number"), ("References", "link"),
        ("Properties", "tag"), ("History", "clock.arrow.circlepath"),
    ]
    var columns: NavigationSplitViewVisibility = .automatic
    var usesSystemSearchable = true
    /// Leading placement also drops the window title from the band: at 860pt
    /// the two cannot both fit, and Notes proves the title is expendable.
    var searchLeading = false

    @State private var activeTab = "Outline"
    @State private var inspectorShown = true
    @State private var visibility: NavigationSplitViewVisibility = .automatic
    @State private var query = ""

    /// A plain field, sized in points. `.searchable` was measured collapsing to
    /// a glyph at 860pt — this cannot, which is the whole reason it exists.
    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $query).textFieldStyle(.plain)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(width: searchLeading ? 190 : 240)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            DesignCollectionTree()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            HStack(spacing: 0) {
                DesignEditor()
                if inspectorShown {
                    Divider()
                    DesignInspector().frame(width: 260)
                }
            }
            .modifier(MaybeSearchable(enabled: usesSystemSearchable))
        }
        .navigationTitle("My Vault")
        .onAppear { visibility = columns }
        // The window keeps its title (Window menu, Mission Control); the *band*
        // does not draw it. Notes shows none, and at 860pt it is the difference
        // between everything fitting and a `»`.
        .modifier(MaybeTitleless(enabled: searchLeading))
        .toolbar {
            // (b) Beside the free toggle, hiding with the sidebar it acts on.
            ToolbarItem(placement: .navigation) {
                Menu {
                    Button("New Collection…") {}
                    Button("New Folder…") {}
                } label: {
                    Label("Add", systemImage: "plus.rectangle.on.folder")
                }
            }
            if searchLeading {
                ToolbarItem(placement: .navigation) { searchField }
            }
            // Commands over the editor: P2 collapses the sidebar while working,
            // so anything inside it would vanish exactly when it is wanted.
            ToolbarItemGroup(placement: .principal) {
                Button { } label: { Label("New Note", systemImage: "square.and.pencil") }
                Button { } label: { Label("Open Quickly", systemImage: "arrow.forward.square") }
            }
            // Search *before* the tabs, so the tabs keep the trailing end and
            // land over the inspector (Pages). A plain field, sized in points,
            // is the only version that survives 860pt without collapsing.
            if !usesSystemSearchable && !searchLeading {
                ToolbarItem { searchField }
            }
            // (c) The tab strip *is* the toolbar. Pressing the active tab closes
            // the inspector, which is what Pages' Format button does.
            ToolbarItemGroup {
                ForEach(Self.tabs, id: \.0) { title, symbol in
                    Button {
                        if inspectorShown && activeTab == title { inspectorShown = false }
                        else { activeTab = title; inspectorShown = true }
                    } label: {
                        Label(title, systemImage: symbol)
                    }
                    .background(
                        inspectorShown && activeTab == title
                            ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                }
            }
        }
    }
}

/// Captures the bench's **own** window through `screencapture`, then closes it.
///
/// `cacheDisplay` — what every earlier snapshot used — cannot render vibrancy,
/// materials or Liquid Glass. Those *are* the sidebar chrome, so the instrument
/// was structurally blind to the thing under test: a design render showed a
/// white block where the rail should be. `screencapture -l <windowID>` goes
/// through the real compositor, so what lands in the PNG is what an eye would
/// see. It captures this one window by id — nothing else on the display.
struct DesignSnapshot: NSViewRepresentable {
    let name: String
    /// Judge chrome at a width a persona actually uses. The default WindowGroup
    /// size is 900pt, which is narrower than P2's laptop and *collapses
    /// `.searchable` into a glyph* — a defect of the bench, not of the design.
    var size: CGSize = CGSize(width: 1470, height: 860)

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak view] in
            MainActor.assumeIsolated {
                guard let window = view?.window else { print("no window"); exit(2) }
                window.setContentSize(size)
                window.orderFrontRegardless()
                RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                // Let the compositor draw it before asking for the picture.
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))

                let path = "/tmp/hn-\(name).png"
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-l\(window.windowNumber)", "-o", "-x", path]
                try? capture.run()
                capture.waitUntilExit()

                let content = window.contentView
                let band = content.map {
                    max(0, $0.bounds.height - window.contentLayoutRect.height)
                } ?? 0
                window.close()
                print("\(name): \(Int(content?.bounds.width ?? 0))x\(Int(content?.bounds.height ?? 0)) "
                      + "titlebarBand=\(Int(band))pt exit=\(capture.terminationStatus) → \(path)")
                exit(0)
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func sizeThatFits(_ p: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? { .zero }
}
