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

/// The flushes the app must wait for before it goes: one hook per window,
/// called when the app quits or leaves the foreground — and the let-go flush
/// of each window closing, until it lands. Shared by both platforms' guards.
///
/// **A window closing is waited for too.** It came off the registry in
/// `onDisappear` and then started its let-go flush in a task nothing awaited,
/// so ⌘W and then ⌘Q during a slow coordinated write ended the process with
/// that save unfinished (implemented.md §51.36). `letGo` takes the hook off and
/// runs the flush as a task of its own, which a drain waits for until it
/// lands; it is keyed by a token, not by the window, so a window that comes
/// back meanwhile keeps the hook it registers again.
@MainActor
final class FlushRegistry {
    private var hooks: [ObjectIdentifier: (_ lettingGo: Bool) async -> Void] = [:]
    private var lettingGo: [UUID: Task<Void, Never>] = [:]

    var hasWork: Bool { !hooks.isEmpty || !lettingGo.isEmpty }

    func register(_ owner: AnyObject, flush: @escaping (_ lettingGo: Bool) async -> Void) {
        hooks[ObjectIdentifier(owner)] = flush
    }

    func unregister(_ owner: AnyObject) {
        hooks.removeValue(forKey: ObjectIdentifier(owner))
    }

    /// `owner` is going: its hook comes off, and `flush` runs now — waited for
    /// by any drain that begins before it lands.
    func letGo(_ owner: AnyObject, flush: @escaping () async -> Void) {
        unregister(owner)
        let token = UUID()
        lettingGo[token] = Task { [weak self] in
            await flush()
            self?.lettingGo.removeValue(forKey: token)
        }
    }

    /// Every registered hook, told whether the buffers are being let go, and
    /// every let-go flush still under way.
    func drain(lettingGo letting: Bool) async {
        let hooks = Array(self.hooks.values)
        let pending = Array(lettingGo.values)
        for hook in hooks { await hook(letting) }
        for flush in pending { await flush.value }
    }
}

#if canImport(AppKit)
@MainActor
final class TerminationGuard: NSObject, NSApplicationDelegate {
    /// The most recently constructed delegate (the one SwiftUI's
    /// `@NSApplicationDelegateAdaptor` retains), so views can register hooks.
    static weak var current: TerminationGuard?

    /// Flush closures keyed by their owning object (e.g. each window's tabs),
    /// told whether the buffers are being let go — see
    /// `EditorModel.flush(lettingGo:)` — and the let-go flushes under way.
    let flushes = FlushRegistry()

    /// Backs the "New Note from Selection" Services-menu item.
    private let servicesProvider = ServicesProvider()
    /// The ⌃⌥⌘N global new-note hotkey (retained for the app's lifetime).
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
    func register(_ owner: AnyObject, flush: @escaping (_ lettingGo: Bool) async -> Void) {
        flushes.register(owner, flush: flush)
    }

    /// A window going: its hook off, and its let-go flush run now and waited
    /// for by a quit that comes before it lands (`FlushRegistry.letGo`).
    func letGo(_ owner: AnyObject, flush: @escaping () async -> Void) {
        flushes.letGo(owner, flush: flush)
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
    /// and nothing more, and the buffers are not let go: a conflict still open
    /// stays in its editor, to be chosen when the person comes back. iOS has
    /// to take a background-task assertion for the same guarantee. One name,
    /// so the shell's `scenePhase` handler does not have to know which it is
    /// talking to.
    func flushUnderAssertion() async {
        guard flushes.hasWork else { return }
        let flushes = self.flushes
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await flushes.drain(lettingGo: false)
            }
            group.addTask { try? await Task.sleep(for: Self.flushDeadline) }
            await group.next()
            group.cancelAll()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard flushes.hasWork else { return .terminateNow }
        let flushes = self.flushes
        // Whichever finishes first replies: the drain, or the deadline. A task
        // group cannot do this — it returns only once every child has, and a
        // flush inside a coordinated write does not stop for cancellation — so
        // a wedged provider still held ⌘Q open for as long as it liked, the
        // deadline notwithstanding. Quitting lets every buffer go.
        let reply = QuitReply()
        Task { @MainActor in
            await flushes.drain(lettingGo: true)
            reply.send()
        }
        Task { @MainActor in
            try? await Task.sleep(for: Self.flushDeadline)
            reply.send()
        }
        return .terminateLater
    }
}

/// Answers `applicationShouldTerminate` once, whoever asks first.
@MainActor
private final class QuitReply {
    private var sent = false

    func send() {
        guard !sent else { return }
        sent = true
        NSApp.reply(toApplicationShouldTerminate: true)
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

    let flushes = FlushRegistry()
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

    func register(_ owner: AnyObject, flush: @escaping (_ lettingGo: Bool) async -> Void) {
        flushes.register(owner, flush: flush)
    }

    /// A window going — see the Mac's `letGo`.
    func letGo(_ owner: AnyObject, flush: @escaping () async -> Void) {
        flushes.letGo(owner, flush: flush)
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
        guard flushes.hasWork else { return }
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
        guard flushes.hasWork else { return }
        let flushes = self.flushes
        await withTaskGroup(of: Void.self) { group in
            // Letting go: nothing tells an app it is about to be killed after
            // this, so a buffer holding a conflict keeps mine beside the note
            // now, or not at all.
            group.addTask { @MainActor in
                await flushes.drain(lettingGo: true)
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
