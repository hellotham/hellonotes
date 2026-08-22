//
//  AccentContrastTests.swift
//  HelloNotesTests
//
//  The accent's contrast maths, and the two settings that used to be Mac-only
//  in practice.
//
//  These exist because the failure they guard against is silent on exactly one
//  platform. "Increase contrast" was a toggle iOS drew, stored, synced, and
//  ignored — the eleven functions behind it were written in `NSColor` inside a
//  `#if os(macOS)` block, so `accentTextColor` on iPad returned the raw tint
//  and the AAA target the switch exists to select was never consulted. Nothing
//  crashed and nothing looked obviously wrong; the text was simply harder to
//  read than the user had asked for.
//
//  So the maths is asserted where it is now written: on framework-free sRGB
//  triples, which run identically on both platforms and in a test with no
//  window.
//

import Testing
import CoreGraphics
@testable import HelloNotes

struct AccentContrastTests {

    // MARK: - WCAG arithmetic

    @Test func contrastMatchesTheWCAGEndpoints() {
        // The two ends of the scale, exactly as the spec defines them.
        #expect(abs(SRGB.contrast(.white, .black) - 21) < 0.001)
        #expect(abs(SRGB.contrast(.white, .white) - 1) < 0.001)
        // Symmetric: a ratio that depends on argument order would silently
        // halve the effective target at half the call sites.
        let a = SRGB(red: 0.42, green: 0.31, blue: 0.78)
        #expect(abs(SRGB.contrast(a, .white) - SRGB.contrast(.white, a)) < 0.0001)
    }

    /// The whole point of `readable`: it does not stop until it clears the bar.
    @Test func readableReachesTheTargetForBothTargets() {
        // A mid lavender — the app's default accent family, and light enough
        // that it fails AA on white before correction.
        let accent = SRGB(red: 0.55, green: 0.45, blue: 0.88)
        let onLight = SRGB.windowGround(isDark: false)
        #expect(SRGB.contrast(accent, onLight) < 4.5, "the fixture has to start below AA")

        let aa = accent.readable(on: onLight, towardDark: true, target: 4.5)
        #expect(SRGB.contrast(aa, onLight) >= 4.5)

        // AAA is what "Increase contrast" selects, and it must be *strictly*
        // more corrected than AA — a target that is read but not acted on looks
        // exactly like one that is ignored.
        let aaa = accent.readable(on: onLight, towardDark: true, target: 7.0)
        #expect(SRGB.contrast(aaa, onLight) >= 7.0)
        #expect(aaa.luminance < aa.luminance)
    }

    /// A hue that cannot reach 7:1 on white must terminate, not spin.
    @Test func readableTerminatesOnAnImpossibleTarget() {
        let yellow = SRGB(red: 1, green: 0.95, blue: 0.2)
        let result = yellow.readable(on: .white, towardDark: true, target: 21)
        // It ran out of room at black rather than looping forever.
        #expect(result.luminance < 0.01)
    }

    @Test func theAccentAdaptsInOppositeDirectionsForEachAppearance() {
        let accent = SRGB(red: 0.42, green: 0.31, blue: 0.78)
        #expect(accent.contextAdjusted(isDark: true).luminance > accent.luminance,
                "lightened on a dark ground")
        #expect(accent.contextAdjusted(isDark: false).luminance < accent.luminance,
                "deepened on a light one")
    }

    @Test func labelOnTopPicksTheMoreLegibleOfBlackAndWhite() {
        #expect(SRGB.grey(0.05).labelOnTop == .white)
        #expect(SRGB.grey(0.95).labelOnTop == .black)
    }

    @Test func blendingIsClampedAndEndpointExact() {
        let a = SRGB(red: 0.2, green: 0.4, blue: 0.6)
        #expect(a.blended(withFraction: 0, of: .white) == a)
        #expect(a.blended(withFraction: 1, of: .white) == .white)
        #expect(a.blended(withFraction: 5, of: .white) == .white, "clamped, not extrapolated")
    }

    // MARK: - The settings that reach it

    @MainActor
    @Test func increaseContrastSelectsTheAAATarget() {
        let settings = AppearanceSettings()
        let wasOn = settings.increaseContrast
        defer { settings.increaseContrast = wasOn }

        settings.increaseContrast = false
        #expect(settings.contrastTarget == 4.5)
        settings.increaseContrast = true
        #expect(settings.contrastTarget == 7.0)
    }

    /// Both editors read one accent property, and it is not spelled with a
    /// framework in its name — `editorAccentNSColor` could only ever be called
    /// from AppKit, which is why `EditorTheme`'s cross-platform `accent:`
    /// parameter received `nil` on iOS for its whole life.
    @MainActor
    @Test func theEditorAccentIsAvailableOnBothPlatforms() {
        let settings = AppearanceSettings()
        settings.accent = .lavender
        // Resolving it at all is the assertion: on the platform this used to be
        // missing on, the call site would not compile.
        #expect(settings.editorAccentPlatformColor.srgb.luminance >= 0)
        #expect(settings.accentTextPlatformColor.srgb.luminance >= 0)
    }

    // MARK: - Text width

    /// The measure is resolved against the body font, and it has to scale with
    /// the text size or the setting stops biting as the text grows.
    @Test func characterWidthScalesWithSize() {
        let small = TextWidth.characterWidth(size: 16)
        #expect(small > 0)
        #expect(TextWidth.characterWidth(size: 32) > small * 1.5)
    }

    @Test func aMeasureIsCentredAndAProportionIsNot() {
        let width = TextWidth.characterWidth(size: 16)
        let measured = TextWidth.resolve(paneWidth: 1400, characterWidth: width,
                                         reading: .normal, editing: .full)
        #expect(measured.centred)
        #expect(measured.width < 1400)

        // `.full` reading takes the pane — the setting's own escape hatch.
        let full = TextWidth.resolve(paneWidth: 1400, characterWidth: width,
                                     reading: .full, editing: .full)
        #expect(!full.centred)
    }

    /// A narrow pane collapses the distinction rather than overflowing it.
    @Test func aNarrowPaneNeverExceedsItself() {
        let width = TextWidth.characterWidth(size: 16)
        let resolved = TextWidth.resolve(paneWidth: 320, characterWidth: width,
                                         reading: .wide, editing: .full)
        #expect(resolved.width <= 320)
    }
}
