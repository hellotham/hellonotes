//
//  TestHostTests.swift
//  HelloNotesTests
//
//  The suite runs inside the app — a macOS unit-test bundle needs a host — and
//  the host used to open its main window for it, on the person's screen, every
//  run (`Scene.suppressedUnderTests`).
//

#if os(macOS)
import AppKit
import Testing
@testable import HelloNotes

@MainActor
@Suite struct TestHostTests {

    @Test func theTestHostShowsNoMainWindow() async throws {
        #expect(TestEnvironment.isRunningTests)
        // Launch is done by the time a test runs; a beat more for SwiftUI to
        // have shown a window if it were going to.
        try await Task.sleep(for: .milliseconds(300))
        let main = NSApp.windows.filter {
            $0.isVisible && ($0.identifier?.rawValue.hasPrefix("main") ?? false)
        }
        #expect(main.isEmpty, "the test host opened \(main.map { $0.identifier?.rawValue ?? "?" })")
    }
}
#else
#endif
