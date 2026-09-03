//
//  AnswerMarkdownTests.swift
//  HelloNotesTests
//

import Foundation
import SwiftUI
import Testing
@testable import HelloNotes

struct AnswerMarkdownTests {

    private func plain(_ s: String) -> String {
        String(AnswerMarkdown.attributed(s).characters)
    }

    /// The complaint, exactly: a real Ask Your Library answer, drawn with its
    /// own syntax showing.
    @Test func theSyntaxDoesNotSurvive() {
        let answer = """
        Based on the note **[[Linking]]**, links work like this:

        * **Creating Links:** Typing `[[` offers every note.
        * **Custom display text:** `[[Note|shown text]]`.
        """
        let text = plain(answer)
        #expect(!text.contains("**"), "bold markers still on screen")
        #expect(!text.contains("* "), "list markers still on screen")
        #expect(text.contains("Creating Links:"))
        // Backticks go, the code text stays.
        #expect(text.contains("[[Note|shown text]]"))
        #expect(!text.contains("`"))
    }

    /// Line structure survives. This is what `LocalizedStringKey` gets wrong —
    /// `.inlineOnly` folds a bulleted answer into one paragraph.
    @Test func lineBreaksSurvive() {
        let text = plain("one\ntwo\nthree")
        #expect(text == "one\ntwo\nthree")
        #expect(plain("* a\n* b").split(separator: "\n").count == 2)
    }

    /// Bullets become bullets, and a nested item stays nested.
    @Test func listMarkersBecomeBullets() {
        let text = plain("- top\n  - nested\n1. first\n2) second")
        #expect(text.contains("• top"))
        #expect(text.contains("  • nested"), "indent lost")
        // The writer's numbering is kept, not renumbered.
        #expect(text.contains("1. first"))
        #expect(text.contains("2) second"))
    }

    /// A heading is a heading, and `#tag` at the start of a line is not.
    @Test func headingsNeedTheirSpace() {
        #expect(plain("## Sources") == "Sources")
        #expect(plain("#tag stays") == "#tag stays")
        #expect(plain("####### seven hashes") == "####### seven hashes")
    }

    /// A fenced block draws its contents, never its fence.
    @Test func fencesDoNotDrawThemselves() {
        let text = plain("before\n```swift\nlet x = 1\n```\nafter")
        #expect(!text.contains("```"))
        #expect(text.contains("let x = 1"))
        #expect(text.contains("before"))
        #expect(text.contains("after"))
        // Inside a fence, `*` is code, not emphasis.
        #expect(plain("```\na * b\n```").contains("a * b"))
    }

    /// Unparseable inline Markdown still shows its text. Showing nothing would
    /// be a worse failure than showing a stray character.
    @Test func aBrokenLineStillReads() {
        let text = plain("an unclosed [link](")
        #expect(text.contains("an unclosed"))
    }

    /// Emphasis really is applied, not merely stripped — a check that removes
    /// the asterisks and forgets the bold would pass every test above.
    @Test func boldIsActuallyBold() throws {
        let s = AnswerMarkdown.attributed("plain **bold** plain")
        let bolded = s.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        #expect(bolded, "asterisks were removed without applying emphasis")
    }
}
