//
//  TerminationGuard.swift
//  HelloNotes
//
//  Draining debounced autosaves before the app goes away — on both platforms.
//
//  HelloNotes autosaves on a debounce, so at any moment up to half a second of
//  typing exists only in an editor's buffer. macOS asks an app whether it may
//  quit, so this held the quit open until every registered flush had run.
//
//  iOS never asks: an app is backgrounded and later killed without a second
//  word. So it was `#if os(macOS)` end to end, `TerminationGuard.current` was
//  nil on iPad, and the shell's registrations there were no-ops — the whole
//  drain existed on one platform. `iOSNoteWindowView` had to grow its own
//  scene-phase flush, which covered the standalone window and nothing else: the
//  main window's open tabs still had no drain at all.
//
//  Both platforms have a moment where "you are about to lose the buffer" is
//  known — `applicationShouldTerminate` on one, resigning active on the other —
//  so the registry and the flush are shared and only that moment differs.
//  Resigning active is the earlier and safer signal: it fires when the app is
//  backgrounded, when the task switcher appears, and before a suspend.
//

import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

#if canImport(AppKit)
@MainActor
final class TerminationGuard: NSObject, NSApplicationDelegate {
    /// The most recently constructed delegate (the one SwiftUI's
    /// `@NSApplicationDelegateAdaptor` retains), so views can register hooks.
    static weak var current: TerminationGuard?

    /// Flush closures keyed by their owning object (e.g. each window's tabs).
    private var flushHooks: [ObjectIdentifier: () async -> Void] = [:]

    /// Backs the "New Note from Selection" Services-menu item.
    private let servicesProvider = ServicesProvider()
    /// ⌥⌘N global quick-capture hotkey (retained for the app's lifetime).
    private var globalHotKey: GlobalHotKey?

    override init() {
        super.init()
        Self.current = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = servicesProvider
        NSUpdateDynamicServices()
        globalHotKey = GlobalHotKey.makeDefault()
    }

    /// Register (or replace) a flush hook for `owner`. Call from a window shell
    /// with its editor tabs' `flushAll`.
    func register(_ owner: AnyObject, flush: @escaping () async -> Void) {
        flushHooks[ObjectIdentifier(owner)] = flush
    }

    func unregister(_ owner: AnyObject) {
        flushHooks.removeValue(forKey: ObjectIdentifier(owner))
    }

    /// How long the quit handshake will wait for pending writes.
    ///
    /// A flush ends in a *coordinated* write, and a coordinated write against a
    /// File Provider that is wedged can block for as long as the provider takes
    /// — which is unbounded. Without a deadline, `.terminateLater` then makes
    /// the app unquittable, and the user's only way out is a force-quit that
    /// discards the very edits this class exists to protect: the safety
    /// mechanism becomes the data-loss mechanism. Five seconds is far longer
    /// than a local write needs and far shorter than a person will wait before
    /// reaching for Force Quit.
    private static let flushDeadline: Duration = .seconds(5)

    /// Drain the registry now, under whatever assurance the platform offers
    /// that the process will live long enough.
    ///
    /// The Mac's assurance is that leaving the foreground is not suspension —
    /// nothing is about to reclaim the process — so this is the bounded drain
    /// and nothing more. iOS has to take a background-task assertion for the
    /// same guarantee. One name, so the shell's `scenePhase` handler does not
    /// have to know which it is talking to.
    func flushUnderAssertion() async {
        guard !flushHooks.isEmpty else { return }
        let hooks = Array(flushHooks.values)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for hook in hooks { await hook() }
            }
            group.addTask { try? await Task.sleep(for: Self.flushDeadline) }
            await group.next()
            group.cancelAll()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !flushHooks.isEmpty else { return .terminateNow }
        let hooks = Array(flushHooks.values)
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in
                    for hook in hooks { await hook() }
                }
                group.addTask {
                    try? await Task.sleep(for: Self.flushDeadline)
                }
                // Whichever finishes first decides; the loser is cancelled.
                await group.next()
                group.cancelAll()
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#else
/// The iOS half: the same registry, drained when the app stops being frontmost.
///
/// A plain object rather than a `UIApplicationDelegate`, because SwiftUI's iOS
/// lifecycle offers `scenePhase` and this has to work for every scene at once —
/// a note window and the main window both hold buffers. `willResignActive`
/// covers backgrounding, the task switcher, and the moment before a suspend.
@MainActor
final class TerminationGuard: NSObject {
    static weak var current: TerminationGuard?

    private var flushHooks: [ObjectIdentifier: () async -> Void] = [:]
    private var observer: (any NSObjectProtocol)?

    override init() {
        super.init()
        Self.current = self
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await TerminationGuard.current?.flushUnderAssertion() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func register(_ owner: AnyObject, flush: @escaping () async -> Void) {
        flushHooks[ObjectIdentifier(owner)] = flush
    }

    func unregister(_ owner: AnyObject) {
        flushHooks.removeValue(forKey: ObjectIdentifier(owner))
    }

    /// The same bounded drain the Mac runs, for the same reason: a provider that
    /// never answers must not hold the app open — or, here, eat the background
    /// execution time the rest of the flushes need.
    private static let flushDeadline: Duration = .seconds(5)

    /// Drain the registry while holding a background-task assertion.
    ///
    /// The Mac's half returns `.terminateLater` and replies only once the drain
    /// lands, so the process genuinely cannot die mid-write. This half fired an
    /// un-awaited `Task` off `willResignActive` and returned — nothing held the
    /// process at all, so a coordinated write to a slow File Provider could be
    /// cut off by suspension and the last debounce window of typing was simply
    /// lost. That is the one thing this class exists to prevent, and the 5s
    /// deadline above is meaningless without an assertion to budget against.
    ///
    /// Suspension mid-coordinated-write is also the `0xdead10cc` termination
    /// case, which the assertion avoids by keeping the app awake until the
    /// coordinator has let go.
    func flushUnderAssertion() async {
        guard !flushHooks.isEmpty else { return }
        var assertion = UIBackgroundTaskIdentifier.invalid
        assertion = UIApplication.shared.beginBackgroundTask(withName: "HelloNotes.flush") {
            // Expired: the system wants the time back. Ending it here is what
            // keeps the app from being killed outright.
            if assertion != .invalid {
                UIApplication.shared.endBackgroundTask(assertion)
                assertion = .invalid
            }
        }
        await flushAll()
        if assertion != .invalid {
            UIApplication.shared.endBackgroundTask(assertion)
            assertion = .invalid
        }
    }

    private func flushAll() async {
        let hooks = Array(flushHooks.values)
        guard !hooks.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for hook in hooks { await hook() }
            }
            group.addTask {
                try? await Task.sleep(for: Self.flushDeadline)
            }
            await group.next()
            group.cancelAll()
        }
    }
}
#endif
