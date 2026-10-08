//
//  FlushRegistryTests.swift
//  HelloNotesTests
//
//  What the app waits for before it goes — each window's flush, and the
//  let-go flush of each window closing (`FlushRegistry`, implemented.md §51.36).
//

import Foundation
import Testing
@testable import HelloNotes

@MainActor
struct FlushRegistryTests {

    /// A quit that begins while a window is letting go of its tabs waits for
    /// that flush to land. The window came off the registry and flushed in a
    /// task nothing awaited, so ⌘W and then ⌘Q during a slow coordinated write
    /// ended the process with the save unfinished.
    @Test func aDrainWaitsForAWindowLettingGo() async {
        let registry = FlushRegistry()
        let window = NSObject()
        registry.register(window) { _ in }
        let (gate, landed) = (Gate(), Locked(false))
        registry.letGo(window) { await gate.wait(); landed.set(true) }

        let draining = Task { await registry.drain(lettingGo: true) }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!landed.value)
        gate.open()
        await draining.value
        #expect(landed.value, "the quit went before the window's let-go flush landed")
        #expect(!registry.hasWork)
    }

    /// A window that comes back before its let-go flush lands keeps the hook
    /// it registers again — the let-go is keyed by a token of its own, not by
    /// the window — and a quit then flushes it.
    @Test func aWindowThatComesBackKeepsItsHook() async {
        let registry = FlushRegistry()
        let window = NSObject()
        let gate = Gate()
        registry.letGo(window) { await gate.wait() }
        let flushed = Locked(0)
        registry.register(window) { _ in flushed.mutate { $0 += 1 } }
        gate.open()
        try? await Task.sleep(for: .milliseconds(50))

        await registry.drain(lettingGo: true)
        #expect(flushed.value == 1, "the window's new hook went with its earlier let-go")
    }
}
