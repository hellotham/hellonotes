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

    /// The open note itself — the axis nothing measured, and where build 12's
    /// worst defect lived.
    ///
    /// The editor's bottom bar is a row of `.fixedSize()` menus and fixed-width
    /// buttons, so it cannot compress: on a 428pt iPhone its minimum is
    /// 512.67pt. An `HStack` that cannot shrink to the width it is offered
    /// reports the width it *contains*; the enclosing `VStack` takes its widest
    /// child; and SwiftUI centres an oversized subview in its parent. So the
    /// pane, the inline title and every line of the note sat at x = -42.33 and
    /// lost their first character, while the navigation bar — which is not in
    /// that stack — stayed perfectly inset and made the screen look fine.
    ///
    /// Every check the app had was blind to it: `PlatformParityTests` asks
    /// whether commands are *wired*, the shell contract measures the shell, and
    /// the four sweeps above stop at the places. None of them asked where a
    /// glyph landed. This one does, and only on the left edge — content scrolled
    /// off to the *right* is ordinary, content off to the *left* is this bug.
    @MainActor
    func testTheOpenNoteIsNotClippedOffTheScreen() throws {
        #if os(iOS)
        let app = launchPastSplash()
        try XCTSkipUnless(app.buttons["Tags"].waitForExistence(timeout: 15),
                          "Compact shell only.")

        // Make the note rather than hunting for one: what the vault holds is
        // not this test's subject, and a test that depends on it fails for the
        // wrong reason on a fresh device.
        app.buttons["Notes"].tap()
        // Through the overflow, which is *named*. Writing this test turned up
        // a button on this screen whose accessibility label is the empty
        // string — VoiceOver announces nothing for it and no test can name it
        // — so route through the one control that says what it is.
        let more = app.buttons["More actions"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15),
                      "the Notes place has no overflow menu. Buttons: "
                      + app.buttons.allElementsBoundByIndex.map(\.label).joined(separator: " | "))
        more.tap()
        let newNote = app.buttons["New Note"].firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 10),
                      "New Note is not in the overflow menu. Buttons: "
                      + app.buttons.allElementsBoundByIndex.map(\.label).joined(separator: " | "))
        newNote.tap()

        // The strip is how the compact shell says a note is open; expanding it
        // is the only way the note is on screen to be measured.
        let strip = app.buttons["shell.miniStrip"].firstMatch
        if strip.waitForExistence(timeout: 15) { strip.tap() }

        // The word count is the editor's own bottom bar — proof the editor is
        // what we are looking at, not the place behind it.
        let wordCount = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] 'word'")).firstMatch
        XCTAssertTrue(wordCount.waitForExistence(timeout: 15),
                      "the editor never appeared, so nothing was measured")

        let screen = app.windows.element(boundBy: 0).frame
        let texts = app.staticTexts.allElementsBoundByIndex.filter { $0.exists }
        XCTAssertFalse(texts.isEmpty, "the open note drew no text at all")
        for text in texts {
            XCTAssertGreaterThanOrEqual(
                text.frame.minX, screen.minX,
                "\"\(text.label)\" starts \(screen.minX - text.frame.minX)pt off the left edge")
        }
        #else
        throw XCTSkip("iOS layout test.")
        #endif
    }

    /// No control a person can reach is announced by its icon's file name.
    ///
    /// Two wrong versions of this test came first, and both are the reason it
    /// is written the way it is.
    ///
    /// It started as "no button has an empty label", after a dump of the Notes
    /// place showed one that did. That was a misreading: SwiftUI gives a `Menu`
    /// **two** accessibility elements — the interactive one, which carries the
    /// label, and an inert twin for the `Image` used as its label, at the same
    /// frame and not hittable. The empty one is the twin, and it is the only
    /// unlabelled button in all four places.
    ///
    /// Narrowing it to "nothing *reachable* is unlabelled" looked right and was
    /// **unfalsifiable**: deleting `.accessibilityLabel("More actions")` — the
    /// negative control — left the test green, because SwiftUI names an
    /// `ellipsis.circle` menu "More" all by itself. A check that cannot fail is
    /// worse than no check, because it reads as coverage.
    ///
    /// What SwiftUI does for an icon it has no name for is fall back to the
    /// **SF Symbol's raw name**: swap that menu's image for `scribble.variable`
    /// and the button's label becomes `scribble.variable`, which VoiceOver then
    /// reads aloud, verbatim, to a person who cannot see it. That is a real
    /// defect class, it is what an icon-only control gets when someone forgets
    /// the modifier, and — unlike the other two — it fails when introduced.
    ///
    /// The screens here are almost entirely icons, so this is the axis that
    /// matters. `PlatformParityTests` guards *field* labelling; this guards
    /// controls, and only where a person can actually land on one.
    @MainActor
    func testEveryReachableControlHasAName() throws {
        #if os(iOS)
        let app = launchPastSplash()
        try XCTSkipUnless(app.buttons["Tags"].waitForExistence(timeout: 15),
                          "Compact shell only.")

        for place in ["Notes", "Search", "Tags", "AI"] {
            app.buttons[place].tap()
            XCTAssertTrue(app.buttons[place].waitForExistence(timeout: 5),
                          "the \(place) tab vanished when selected")

            let reachable = app.buttons.allElementsBoundByIndex
                .filter { $0.exists && $0.isHittable }
            XCTAssertFalse(reachable.isEmpty,
                           "the \(place) place offers nothing to press")
            for button in reachable {
                // `scribble.variable`, `square.and.pencil` — all lowercase,
                // dot-separated, no spaces. A person's own text never looks
                // like this; an unnamed SF Symbol always does.
                let isSymbolName = button.label.range(
                    of: "^[a-z0-9]+(\\.[a-z0-9]+)+$",
                    options: .regularExpression) != nil
                XCTAssertFalse(
                    isSymbolName,
                    "the \(place) place has a reachable control at \(button.frame) "
                    + "announced as \"\(button.label)\" — that is its icon's SF Symbol "
                    + "name, not a label. Give it .accessibilityLabel(_:).")
            }
        }
        #else
        throw XCTSkip("iOS accessibility test.")
        #endif
    }

    // MARK: - Not yet covered
    //
    //  The **inspector** is not swept, and the editor is swept only for where
    //  its text lands — not for whether each of the bottom bar's commands can
    //  still be reached once the row scrolls. Left out deliberately, and named
    //  here so the gap is a known one rather than an assumed pass.

}
