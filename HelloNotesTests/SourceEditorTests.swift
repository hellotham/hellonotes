//
//  SourceEditorTests.swift
//  HelloNotesTests
//
//  Markdown mode must not rewrite what you type — on either platform.
//
//  A silent corruption, which is why it wants a test rather than a comment.
//  Markdown mode shows the note's literal source; the system's typographic
//  substitutions turn `---` under a table header into an em dash and `"` into a
//  curly quote, and the file on disk then holds characters no Markdown parser
//  recognises. The table stops being a table and nothing says so.
//
//  iOS found it and fixed its own copy of the view. macOS kept SwiftUI's
//  `TextEditor`, whose `NSTextView` follows the user's system settings — the
//  same corruption, on the platform where a hand-written table is most likely to
//  live. `makeSourceOnly` is the fix, named so it can be asserted rather than
//  read.
//

import Testing
@testable import HelloNotes
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@MainActor
struct SourceEditorTests {

    @Test func theSourceEditorNeverSubstitutesTypography() {
        #if canImport(AppKit)
        // A text view configured the way the *system* would leave it, so the
        // test fails if `makeSourceOnly` stops being applied rather than
        // passing on a view that happened to default correctly.
        let view = NSTextView()
        view.isAutomaticDashSubstitutionEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = true
        view.isAutomaticTextReplacementEnabled = true
        view.isAutomaticSpellingCorrectionEnabled = true
        view.isRichText = true

        SourceEditor.makeSourceOnly(view)

        #expect(view.isAutomaticDashSubstitutionEnabled == false,
                "`---` under a table header becomes an em dash")
        #expect(view.isAutomaticQuoteSubstitutionEnabled == false,
                "a curly quote stops closing a fence")
        #expect(view.isAutomaticTextReplacementEnabled == false)
        #expect(view.isAutomaticSpellingCorrectionEnabled == false)
        #expect(view.isContinuousSpellCheckingEnabled == false)
        #expect(view.isRichText == false, "source is plain text or it is not source")
        #else
        let view = UITextView()
        view.smartDashesType = .yes
        view.smartQuotesType = .yes
        view.smartInsertDeleteType = .yes
        view.autocorrectionType = .yes

        SourceEditor.makeSourceOnly(view)

        #expect(view.smartDashesType == .no,
                "`---` under a table header becomes an em dash")
        #expect(view.smartQuotesType == .no,
                "a curly quote stops closing a fence")
        #expect(view.smartInsertDeleteType == .no)
        #expect(view.autocorrectionType == .no)
        #expect(view.spellCheckingType == .no)
        #endif
    }
}
