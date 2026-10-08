//
//  PointerPresence.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  Is there a pointer? — asked of the hardware, not of the operating system.
//
//  What reads it now is the words a view uses — the graph says "tap" to a
//  finger and "click" to a pointer. The shell used to take it too, for a tab
//  bar's height, a note row's floor and a format bar, and none of those read
//  it: the format bar was never built, and the heights were declared and
//  drawn by nothing (ui.md §12, item 1; implemented.md §51.36). The Mac passed
//  `false` and the iPad `true`, both hard-coded — so a Mac window and an iPad
//  of the same size answered differently, where the layout contract chooses
//  by the axis of abundance, *never by device*.
//
//  So the question is answered here, once, and both platforms ask it with the same
//  expression. `GCMouse` is the documented way to ask on iOS and reports mice
//  and trackpads alike; it is also *dynamic*, which matters — detaching an iPad
//  from its keyboard should give back the touch sizing while you are holding it.
//

import Foundation
#if canImport(GameController)
import GameController
#endif

@MainActor
@Observable
final class PointerPresence {

    /// One instance, because it is a fact about the machine rather than about
    /// any window — and because each observer would otherwise register its own
    /// notification pair.
    static let shared = PointerPresence()

    /// Whether an indirect pointing device is currently driving the cursor.
    private(set) var isAvailable: Bool

    /// The shell's own vocabulary: touch sizing is the absence of a pointer.
    var prefersTouch: Bool { !isAvailable }

    private init() {
        #if os(macOS)
        // A Mac always has one. There is no state to observe.
        isAvailable = true
        #elseif canImport(GameController)
        isAvailable = GCMouse.current != nil
        observe()
        #else
        isAvailable = false
        #endif
    }

    #if !os(macOS) && canImport(GameController)
    private func observe() {
        let refresh: @Sendable (Notification) -> Void = { _ in
            Task { @MainActor in
                PointerPresence.shared.isAvailable = GCMouse.current != nil
            }
        }
        NotificationCenter.default.addObserver(
            forName: .GCMouseDidConnect, object: nil, queue: .main, using: refresh)
        NotificationCenter.default.addObserver(
            forName: .GCMouseDidDisconnect, object: nil, queue: .main, using: refresh)
    }
    #else
    /// Nothing to observe: a Mac always has a pointer, so `isAvailable` is
    /// constant and there is no connect/disconnect to hear about. The shared
    /// answer above (`prefersTouch`) is what both platforms read.
    private func observe() {}
    #endif
}
