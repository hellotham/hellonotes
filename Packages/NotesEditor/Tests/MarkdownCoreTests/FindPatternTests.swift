//
//  FindPatternTests.swift
//  MarkdownCoreTests
//
//  The find bar's patterns: a phrase as it always was, and a regular expression
//  — its matching, its replacement template, and the time limit that keeps a
//  runaway pattern from freezing the window.
//

import Foundation
import Testing
@testable import MarkdownCore

@Suite struct FindPatternTests {
    /// The text of each match.
    private func found(_ pattern: FindPattern, in text: String) -> [String] {
        let string = text as NSString
        guard case .success(let ranges) = pattern.matches(in: string) else { return [] }
        return ranges.map { string.substring(with: $0) }
    }

    /// `text` with every match replaced, back to front as the editor does.
    private func replaced(_ pattern: FindPattern, in text: String, with replacement: String) -> String? {
        let string = NSMutableString(string: text)
        guard case .success(let all) = pattern.replacements(in: string, with: replacement) else { return nil }
        for match in all.reversed() { string.replaceCharacters(in: match.range, with: match.text) }
        return string as String
    }

    private func regex(_ text: String) -> FindPattern { FindPattern(text, isRegularExpression: true) }

    @Test func aPhraseMatchesAnywhereIgnoringCase() {
        #expect(found(FindPattern("note"), in: "Note, notes, NOTE.") == ["Note", "note", "NOTE"])
        // A phrase's punctuation is itself, not a pattern.
        #expect(found(FindPattern("a.c"), in: "abc a.c") == ["a.c"])
    }

    @Test func aRegularExpressionMatchesItsPattern() {
        #expect(found(regex("\\d+"), in: "a1 b22 c333") == ["1", "22", "333"])
        #expect(found(regex("a.c"), in: "abc a.c") == ["abc", "a.c"])
    }

    @Test func caseIsIgnoredUnlessThePatternSaysOtherwise() {
        #expect(found(regex("[a-z]+"), in: "ABC") == ["ABC"])
        #expect(found(regex("(?-i)[a-z]+"), in: "ABC def") == ["def"])
    }

    @Test func anchorsMatchAtEveryLine() {
        #expect(found(regex("^\\w+"), in: "one two\nthree four") == ["one", "three"])
        #expect(found(regex("\\w+$"), in: "one two\nthree four") == ["two", "four"])
    }

    @Test func aPatternThatCannotBeReadSaysSo() {
        #expect(regex("(").matches(in: "a(b" as NSString) == .failure(.invalid))
        // The same text as a phrase is only a parenthesis.
        #expect(found(FindPattern("("), in: "a(b") == ["("])
    }

    @Test func aRunawayPatternStopsAtItsTimeLimit() {
        // `(a*)*b` backtracks exponentially over a run of `a`s with no `b`: in
        // a probe it was still running after five seconds without a limit.
        let text = String(repeating: "a", count: 28) as NSString
        let clock = ContinuousClock()
        let start = clock.now
        #expect(regex("(a*)*b").matches(in: text, timeLimit: 0.1) == .failure(.tooSlow))
        #expect(clock.now - start < .seconds(2), "the time limit did not stop the search")
    }

    @Test func aReplacementExpandsEachMatchsGroups() {
        let swap = regex("(\\w+)@(\\w+)")
        #expect(replaced(swap, in: "me@home, you@work", with: "$2 for $1") == "home for me, work for you")
        #expect(replaced(swap, in: "me@home", with: "[$0]") == "[me@home]")
    }

    @Test func aReplacementCanBreakALineOrTab() {
        #expect(replaced(regex(",\\s*"), in: "a, b,c", with: "\\n") == "a\nb\nc")
        #expect(replaced(regex(",\\s*"), in: "a, b", with: "\\t") == "a\tb")
    }

    @Test func aTemplatesOwnEscapesAreKept() {
        #expect(replaced(regex("(\\w+)"), in: "x", with: "\\$1") == "$1")
        #expect(replaced(regex("(\\w+)"), in: "x", with: "\\\\$1") == "\\x")
        #expect(replaced(regex("(\\w+)"), in: "x", with: "$1\\") == "x\\")
    }

    @Test func anEmptyMatchInsertsWithoutRemovingAnything() {
        // `^` matches before every line: a prefix for each.
        #expect(replaced(regex("^"), in: "one\ntwo", with: "- ") == "- one\n- two")
    }

    @Test func aPhrasesReplacementIsItsOwnText() {
        #expect(replaced(FindPattern("x"), in: "x x", with: "$1\\n") == "$1\\n $1\\n")
    }

    @Test func anEmptyPatternFindsNothing() {
        #expect(regex("").matches(in: "abc" as NSString) == .success([]))
        #expect(FindPattern("").matches(in: "abc" as NSString) == .success([]))
    }
}
