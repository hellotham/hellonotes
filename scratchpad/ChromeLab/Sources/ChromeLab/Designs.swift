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

    var body: some Scene {
        WindowGroup {
            candidate
                .background(DesignSnapshot(name: "design-\(Self.index)"))
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

        default:
            Text("no such design")
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

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak view] in
            MainActor.assumeIsolated {
                guard let window = view?.window else { print("no window"); exit(2) }
                window.orderFrontRegardless()
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
