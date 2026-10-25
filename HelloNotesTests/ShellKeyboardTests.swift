//
//  ShellKeyboardTests.swift
//  HelloNotesTests
//
//  A keyboard must not change which shell the window is.
//
//  The shell is chosen by the scene's shape — taller than wide is the band
//  across the top, wider than tall is the columns — and it was chosen by the
//  height the scene was *offered*, which a keyboard takes from. On an iPad in
//  portrait the keyboard coming up made the scene wider than tall, so the band
//  became the columns: two branches, every view in the window made again. The
//  text view that had asked for the keyboard was gone, the keyboard with it,
//  the scene was tall again, and nothing could be typed into a note. The
//  Assistant, which takes the keyboard as it appears, went round for good
//  (docs/implemented.md §51.41).
//
//  Nothing saw it: the interface tests run on a phone, whose shell is chosen
//  by width alone, and the window comparison holds the iPad in landscape. It
//  was found shooting the App Store's screenshots, by a tap that never came
//  back.
//
//  A keyboard arrives as a bottom safe-area inset, so one is given here — the
//  Mac has no keyboard to bring up, and the shell cannot tell the difference.
//  Each test checks the inset really took the height, or a pass would prove
//  nothing.
//

import Foundation
import SwiftUI
import Testing
@testable import HelloNotes
#if canImport(AppKit)
import AppKit
#endif

@Suite(.serialized) @MainActor
struct ShellKeyboardTests {

    /// The 13-inch iPad in portrait, as its scene measured with the keyboard
    /// down and up (HN-iPad13, iPadOS 27): the height offered and the inset
    /// under it. Their sum does not move.
    @Test func theShellIsChosenToTheScenesBottomEdge() {
        #expect(shellKind(width: 1032, offeredHeight: 1324, bottomInset: 20) == .tall)
        #expect(shellKind(width: 1032, offeredHeight: 941, bottomInset: 403) == .tall)
        // What it was chosen by, and what that made of the same scene.
        #expect(shellKind(width: 1032, height: 941) != .tall)
    }

    #if canImport(AppKit)
    /// The keyboard comes up under a scene taller than wide, and goes: the
    /// shell is the band throughout, and the pane in it is the same view — it
    /// appeared once.
    @Test func aKeyboardLeavesTheShellAndItsPaneAlone() async {
        let keyboard = Keyboard()
        let record = Record()
        let window = host(Scene(keyboard: keyboard, record: record), size: CGSize(width: 800, height: 1000))
        defer { close(window) }
        await pump(0.3)
        #expect(record.kinds == [.tall])
        #expect(record.appearances == 1)
        let before = record.heights.last ?? 0

        // 300pt of an 800×1000 scene leaves 700: wider than tall.
        keyboard.height = 300
        await pump(0.3)
        let during = record.heights.last ?? 0
        #expect(during < before - 250, "the inset took no height, so this proves nothing: \(before) → \(during)")
        #expect(record.kinds == [.tall], "the keyboard changed the shell: \(record.kinds)")
        #expect(record.appearances == 1, "the keyboard made the pane again")

        keyboard.height = 0
        await pump(0.3)
        #expect(record.kinds == [.tall])
        #expect(record.appearances == 1)
    }

    // MARK: - The scene

    @Observable @MainActor
    final class Keyboard { var height: CGFloat = 0 }

    @MainActor
    final class Record {
        var appearances = 0
        var kinds: [ShellKind] = []
        var heights: [CGFloat] = []
    }

    private struct Scene: View {
        let keyboard: Keyboard
        let record: Record

        var body: some View {
            AdaptiveShell(inspectorPresented: .constant(false), bandHidden: .constant(false),
                          columnVisibility: .constant(.all),
                          sidebar: { Color.clear },
                          pane: { Pane(record: record) },
                          inspector: { Color.clear },
                          compact: { Color.clear })
                .safeAreaPadding(.bottom, keyboard.height)
        }
    }

    /// Stands where the editor does, and says what it was told and how often
    /// it was made.
    private struct Pane: View {
        @Environment(\.shell) private var shell
        let record: Record

        var body: some View {
            Color.clear
                .onAppear { record.appearances += 1 }
                .onChange(of: shell.kind, initial: true) { _, kind in record.kinds.append(kind) }
                .onChange(of: shell.size.height, initial: true) { _, height in record.heights.append(height) }
        }
    }

    // MARK: - Hosting

    private func host(_ view: some View, size: CGSize) -> NSWindow {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.layoutIfNeeded()
        return window
    }

    private func close(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    /// Turn the main run loop for `seconds`, in small steps, so the hosted
    /// views lay out and their tasks run.
    private func pump(_ seconds: TimeInterval) async {
        // For its seconds, for no fewer looks than a crowded main actor
        // leaves it, and with the run loop last (`Waits.Pump`).
        var pump = Waits.Pump(seconds)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.004))
            try? await Task.sleep(for: .milliseconds(1))
        } while pump.goesOn
        RunLoop.main.run(until: Date().addingTimeInterval(0.004))
    }
    #endif
}
