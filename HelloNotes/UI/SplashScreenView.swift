//
//  SplashScreenView.swift
//  HelloNotes
//
//  Created by Chris Tham on 13/7/2026.
//
//  An Adobe-style launch splash: full-bleed artwork in the app icon's
//  purple → magenta → orange gradient, a slowly drifting constellation of
//  linked notes, the wordmark, a tagline, and the credits / version /
//  copyright small print. Shown briefly at launch, and again from
//  "About HelloNotes" (macOS), where it stays until clicked.
//

import SwiftUI

struct SplashScreenView: View {
    /// Invoked when the user clicks the splash (or presses Escape on macOS).
    var onDismiss: () -> Void = {}

    var body: some View {
        ZStack {
            artwork
            content
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture { onDismiss() }
        #if os(macOS)
        .onExitCommand { onDismiss() }
        #endif
    }

    // MARK: Artwork

    /// The icon's gradient, with a soft glow behind the icon and a darkened
    /// corner so the small print stays legible.
    private var artwork: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(.sRGB, red: 0.48, green: 0.24, blue: 0.93),
                    Color(.sRGB, red: 0.78, green: 0.25, blue: 0.75),
                    Color(.sRGB, red: 0.93, green: 0.30, blue: 0.51),
                    Color(.sRGB, red: 0.98, green: 0.62, blue: 0.24),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )

            // Glow behind the app icon.
            RadialGradient(colors: [.white.opacity(0.32), .clear],
                           center: UnitPoint(x: 0.76, y: 0.38),
                           startRadius: 10, endRadius: 260)

            ConstellationView()

            // Legibility vignette under the text block.
            LinearGradient(colors: [.black.opacity(0.42), .clear],
                           startPoint: .bottomLeading,
                           endPoint: UnitPoint(x: 0.55, y: 0.35))
        }
    }

    // MARK: Text + icon

    private var content: some View {
        ZStack(alignment: .topLeading) {
            // Company mark, top-left like a publisher logo.
            Text("HELLO THAM")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .tracking(5)
                .foregroundStyle(.white.opacity(0.85))
                .padding(28)

            appIcon
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 64)
                .padding(.trailing, 84)

            VStack(alignment: .leading, spacing: 5) {
                Spacer()

                Text("HelloNotes")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 2)

                Text("Where every idea says hello.")
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.bottom, 14)

                Rectangle()
                    .fill(.white.opacity(0.35))
                    .frame(width: 300, height: 1)
                    .padding(.bottom, 10)

                Group {
                    Text("\(BuildInfo.versionLine)\(BuildInfo.buildDate.isEmpty ? "" : "  ·  Built \(BuildInfo.buildDate)")")
                    Text("Created by Chris Tham")
                    Text("Made with SwiftUI, MarkdownEngine & SwiftGitX")
                        .foregroundStyle(.white.opacity(0.65))
                    Text("© \(BuildInfo.copyrightYear) Hello Tham. All rights reserved.")
                        .foregroundStyle(.white.opacity(0.65))
                }
                .font(.system(size: 11.5, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
            }
            .padding(28)
        }
    }

    @ViewBuilder private var appIcon: some View {
        #if os(macOS)
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 148, height: 148)
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
        #else
        // iOS keeps the artwork icon-free (the user just saw the home-screen
        // icon); the constellation and wordmark carry the identity.
        EmptyView()
        #endif
    }
}

// MARK: - Constellation

/// A drifting, twinkling network of linked notes — the app icon's motif,
/// animated. Deterministic layout (golden-ratio scatter), gentle sine drift.
private struct ConstellationView: View {

    private struct Star {
        let base: CGPoint     // unit coordinates
        let radius: CGFloat
        let phase: Double
        let drift: CGSize
    }

    private static let stars: [Star] = (0..<18).map { i in
        let f = Double(i)
        return Star(
            base: CGPoint(x: (0.137 + f * 0.6180339887).truncatingRemainder(dividingBy: 1),
                          y: (0.271 + f * 0.3819660113).truncatingRemainder(dividingBy: 1)),
            radius: 2.2 + CGFloat((f * 0.618).truncatingRemainder(dividingBy: 1)) * 3.4,
            phase: f * 0.73,
            drift: CGSize(width: 5 + (f * 1.3).truncatingRemainder(dividingBy: 5),
                          height: 4 + (f * 1.7).truncatingRemainder(dividingBy: 6))
        )
    }

    /// Links between nearby stars (at most two per star, so it reads as a
    /// note graph rather than a mesh).
    private static let links: [(Int, Int)] = {
        var result: [(Int, Int)] = []
        var degree = [Int: Int]()
        for i in stars.indices {
            for j in (i + 1)..<stars.count {
                let dx = stars[i].base.x - stars[j].base.x
                let dy = stars[i].base.y - stars[j].base.y
                if (dx * dx + dy * dy).squareRoot() < 0.24,
                   degree[i, default: 0] < 2, degree[j, default: 0] < 2 {
                    result.append((i, j))
                    degree[i, default: 0] += 1
                    degree[j, default: 0] += 1
                }
            }
        }
        return result
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate

                func position(_ star: Star) -> CGPoint {
                    CGPoint(x: star.base.x * size.width + sin(t * 0.32 + star.phase) * star.drift.width,
                            y: star.base.y * size.height + cos(t * 0.27 + star.phase * 1.4) * star.drift.height)
                }

                let points = Self.stars.map(position)

                // Links first, under the orbs.
                for (i, j) in Self.links {
                    var line = Path()
                    line.move(to: points[i])
                    line.addLine(to: points[j])
                    let shimmer = 0.14 + 0.06 * sin(t * 0.6 + Double(i + j))
                    ctx.stroke(line, with: .color(.white.opacity(shimmer)), lineWidth: 1)
                }

                for (i, star) in Self.stars.enumerated() {
                    let twinkle = 0.55 + 0.35 * sin(t * 0.8 + star.phase * 2.1)
                    let rect = CGRect(x: points[i].x - star.radius, y: points[i].y - star.radius,
                                      width: star.radius * 2, height: star.radius * 2)
                    var orb = ctx
                    orb.addFilter(.shadow(color: .white.opacity(0.8), radius: star.radius * 1.8))
                    orb.fill(Path(ellipseIn: rect), with: .color(.white.opacity(twinkle)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - macOS presentation

#if os(macOS)
/// Presents the splash in a borderless floating window: at launch it fades in,
/// lingers, and fades away; from the About menu it stays until clicked.
@MainActor
enum SplashWindow {
    private static var window: NSWindow?
    private static var dismissTask: Task<Void, Never>?

    static func show(autoDismiss: Bool) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingView(rootView: SplashScreenView { close() })
        hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 440)

        let panel = SplashPanel(contentRect: hosting.frame, styleMask: [.borderless],
                                backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.contentView = hosting
        panel.center()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            panel.animator().alphaValue = 1
        }
        window = panel

        if autoDismiss {
            dismissTask = Task {
                try? await Task.sleep(for: .seconds(3.5))
                guard !Task.isCancelled else { return }
                close()
            }
        }
    }

    static func close() {
        dismissTask?.cancel()
        dismissTask = nil
        guard let panel = window else { return }
        window = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.45
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}

/// Borderless windows refuse key status by default; the splash accepts it so
/// Escape can dismiss it.
private final class SplashPanel: NSWindow {
    override var canBecomeKey: Bool { true }
}
#endif
