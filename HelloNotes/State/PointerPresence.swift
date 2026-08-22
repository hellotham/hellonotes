//
//  PointerPresence.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  Is there a pointer? — asked of the hardware, not of the operating system.
//
//  `AdaptiveShell` takes `prefersTouch`, and it does more than size hit targets:
//  `ShellContext.showsFormatBar` is `!prefersTouch && paneWidth >= …`, so it
//  **removes a region**, and `tabBarHeight` changes with it. The Mac passed
//  `false` and the iPad passed `true`, both hard-coded — so a Mac window and an
//  iPad of the same size rendered different shells, which the layout contract
//  forbids in as many words: chosen by the axis of abundance, *never by device*.
//
//  Decision 3 says "a persistent format bar needs a pointer and room". An iPad
//  with a Magic Keyboard and trackpad has a pointer and, at 1470pt, the room.
//  The rule was never "not on iOS" — the implementation had substituted the
//  operating system for the fact the rule is actually about, which is the same
//  substitution that kept the inspector column off iPad.
//
//  So the question is answered here, once, and both shells ask it with the same
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
