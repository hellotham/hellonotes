//
//  TerminationGuard.swift
//  HelloNotes
//
//  Ensures no debounced editor edit is lost on ⌘Q. Autosave trails typing by a
//  ~600 ms debounce; a fire-and-forget flush on scenePhase change can be cut
//  short when the process exits. This app delegate implements the proper macOS
//  quit handshake: `applicationShouldTerminate` returns `.terminateLater`, we
//  synchronously drain every registered flush hook, then reply so the app exits
//  only once all pending saves have hit disk.
//

#if os(macOS)
import AppKit

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
#endif
