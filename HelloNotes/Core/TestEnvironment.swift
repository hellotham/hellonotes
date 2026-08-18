//
//  TestEnvironment.swift
//  HelloNotes
//
//  Is this process running as a test host?
//
//  `HelloNotesTests` is a *hosted* unit-test bundle: `xcodebuild test` launches
//  the whole app and injects the bundle into it. That means the app's launch
//  work runs first — restoring the library, scanning and indexing every note in
//  it, donating them to Spotlight, writing the widget snapshot — before, and
//  then alongside, the tests.
//
//  On a real vault that is not a rounding error. Restoring a 2,000-note
//  collection out of a cloud folder is coordinated I/O against files that may
//  not be downloaded, and it lands on the main actor — which is exactly where
//  the swift-testing suites run. The tests do not deadlock so much as queue
//  behind the user's own vault, which is why the suite could sit for twenty
//  minutes with the runner idle and the app apparently healthy.
//
//  Nothing here changes what is *tested*: every test builds the state it needs.
//  What it removes is a test host that opens someone's real notes.
//

import Foundation

nonisolated enum TestEnvironment {
    /// True when this process was launched to host a test bundle.
    ///
    /// `XCTestConfigurationFilePath` is set by the test runner in the host's
    /// environment and by nothing else — it is the check Apple's own templates
    /// use. Resolved once: it cannot change during the process's life.
    static let isRunningTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }()
}
