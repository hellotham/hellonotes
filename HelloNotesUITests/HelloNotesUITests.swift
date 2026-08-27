//
//  HelloNotesUITests.swift
//  HelloNotesUITests
//
//  Created by Chris Tham on 11/7/2026.
//

import XCTest

final class HelloNotesUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    // MARK: - Screens that must not be empty
    //
    //  **Every parity check this project had asked about source.** Is the
    //  command wired on both shells, is the `#if` two-sided. None of them can
    //  see a screen that compiles, type-checks, is reachable from the menu, and
    //  renders as an empty box — which is what iOS Settings ▸ AI did for the
    //  whole of build 11, because `iOSSettingsView` wrapped an already-`Form`
    //  view in a second `Form`.
    //
    //  Offscreen rendering cannot catch it either: `sizeThatFits` answers 0 for
    //  a healthy `Form` (it is a viewport, so it reports the size it is
    //  *offered*), and `ImageRenderer` draws the nested form and the plain one
    //  identically. Both were tried, with a negative control, and both failed —
    //  see `ScreenRenderTests`. A live navigation hierarchy is the only place
    //  the collapse exists, which is why these tests are here and not there.
    //
    //  Each asserts on a control the screen *must* show rather than on a
    //  screenshot, so a failure means "this screen did not draw" and not "a
    //  caption reflowed".

    /// Launch, and wait out the splash.
    ///
    /// The splash is deliberately `.isModal` so VoiceOver cannot wander into the
    /// app behind it, and it auto-dismisses after 2.8s. XCUITest reads any modal
    /// as an interrupting alert, looks for a Cancel button, finds none, and
    /// abandons whatever tap it was making — so every test here has to let it
    /// finish rather than fight it.
    @MainActor
    private func launchPastSplash() -> XCUIApplication {
        // **Orientation decides which shell you get.** The simulator holds its
        // last orientation between runs, and an iPhone 13 Pro Max in landscape
        // is 926pt wide — regular width — so the app correctly draws the
        // sidebar shell and none of the compact tab bar exists. Five tests
        // skipped with "Compact shell only", which was true and read exactly
        // like a broken test. Pin it rather than inherit it.
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif

        let app = XCUIApplication()
        app.launch()
        let splash = app.staticTexts["Where every idea says hello."]
        if splash.waitForExistence(timeout: 5) {
            XCTAssertTrue(splash.waitForNonExistence(timeout: 20), "splash never dismissed")
        }
        return app
    }

    /// Open the Settings sheet from the compact shell's overflow menu.
    @MainActor
    private func openSettings(_ app: XCUIApplication) throws {
        // The compact shell remembers the place it was left in (`compactPlace`),
        // and the overflow button lives on Notes. Without this the test is a
        // coin toss decided by whatever the last session was doing — which is
        // exactly how it passed once and then skipped five times in a row.
        let notes = app.buttons["Notes"]
        if notes.waitForExistence(timeout: 15) { notes.tap() }

        let more = app.buttons["More actions"]
        try XCTSkipUnless(more.waitForExistence(timeout: 15),
                          "Compact shell only — at regular width Settings is reached from the menu bar.")
        more.tap()
        let settings = app.buttons["Settings…"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "Settings… missing from the overflow menu")
        settings.tap()
    }

    /// Scroll until `element` is on screen, or give up.
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        var attempts = 0
        while !element.exists && attempts < 12 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5),
                      "never became reachable by scrolling", file: file, line: line)
    }

    /// The four places the compact shell offers. A tab that selects but draws
    /// nothing looks exactly like a tab with nothing in it.
    @MainActor
    func testEveryCompactPlaceDrawsContent() throws {
        #if os(iOS)
        let app = launchPastSplash()
        try XCTSkipUnless(app.buttons["Tags"].waitForExistence(timeout: 15),
                          "Compact shell only.")

        for (tab, marker) in [("Notes", "Collections"), ("Tags", "Tags"),
                              ("Search", "Search"), ("AI", "AI")] {
            app.buttons[tab].tap()
            XCTAssertTrue(app.descendants(matching: .any)[marker].waitForExistence(timeout: 5),
                          "the \(tab) place drew no content")
        }
        #else
        throw XCTSkip("iOS navigation test.")
        #endif
    }

    /// The Settings sheet's own sections. `Form { Form { … } }` collapses the
    /// inner one, and the outer sheet keeps drawing — so the failure is local to
    /// one section and invisible from anywhere else.
    @MainActor
    func testSettingsSheetDrawsEverySection() throws {
        #if os(iOS)
        let app = launchPastSplash()
        try openSettings(app)

        XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 10),
                      "Settings opened but drew nothing")
        for section in ["Accent color", "Text size", "AI", "Git", "Attachments",
                        "Daily notes", "Templates"] {
            reveal(app.staticTexts[section], in: app)
        }
        #else
        throw XCTSkip("iOS navigation test.")
        #endif
    }

    /// The check build 11 would have failed.
    @MainActor
    func testAISettingsScreenIsNotEmpty() throws {
        #if os(iOS)
        let app = launchPastSplash()
        try openSettings(app)

        let providers = app.buttons["Providers & API Keys"]
        reveal(providers, in: app)
        providers.tap()

        XCTAssertTrue(app.staticTexts["Chat provider"].waitForExistence(timeout: 5),
                      "AI settings opened but drew no content — the form collapsed")
        XCTAssertTrue(app.staticTexts["Providers"].exists,
                      "the provider list is missing from AI settings")
        #else
        throw XCTSkip("iOS navigation test.")
        #endif
    }

    /// Git settings reaches iOS by the same `NavigationLink` shape as AI, so it
    /// is one edit away from the same collapse.
    @MainActor
    func testGitSettingsScreenIsNotEmpty() throws {
        #if os(iOS)
        let app = launchPastSplash()
        try openSettings(app)

        let git = app.buttons["Repository & Accounts"]
        guard git.exists || {
            var n = 0
            while !git.exists && n < 12 { app.swipeUp(); n += 1 }
            return git.exists
        }() else {
            throw XCTSkip("Git settings appear only for a collection in a repository.")
        }
        git.tap()
        XCTAssertTrue(app.staticTexts["Commit identity"].waitForExistence(timeout: 5),
                      "Git settings opened but drew no content")
        #else
        throw XCTSkip("iOS navigation test.")
        #endif
    }

    // MARK: - Not yet covered
    //
    //  The **editor and the inspector** are not swept. Selecting a collection in
    //  the compact shell marks it selected rather than navigating, so reaching a
    //  note takes a step this test did not model — and a test that skips reads
    //  as coverage while providing none, which is the failure mode this whole
    //  file exists to correct. Left out deliberately, and named here so the gap
    //  is a known one rather than an assumed pass.

}
