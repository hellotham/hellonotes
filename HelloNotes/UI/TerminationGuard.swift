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

    override init() {
        super.init()
        Self.current = self
    }

    /// Register (or replace) a flush hook for `owner`. Call from a window shell
    /// with its editor tabs' `flushAll`.
    func register(_ owner: AnyObject, flush: @escaping () async -> Void) {
        flushHooks[ObjectIdentifier(owner)] = flush
    }

    func unregister(_ owner: AnyObject) {
        flushHooks.removeValue(forKey: ObjectIdentifier(owner))
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !flushHooks.isEmpty else { return .terminateNow }
        let hooks = Array(flushHooks.values)
        Task { @MainActor in
            for hook in hooks { await hook() }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#endif
