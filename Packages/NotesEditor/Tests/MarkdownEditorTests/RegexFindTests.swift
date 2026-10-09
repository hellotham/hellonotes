//
//  RegexFindTests.swift
//  MarkdownEditorTests
//
//  A regular-expression find through the bus, as the find bar sends it: the
//  count comes back, Replace and Replace All expand each match's own groups, a
//  pattern that cannot be read comes back as a problem rather than a count, and
//  a phrase is still a phrase. AppKit here under `swift test`, UIKit under the
//  iOS `xcodebuild test` — the coordinator's bus is written twice, in two gates.
//

import Foundation
import Testing
import MarkdownCore
@testable import MarkdownEditor

@MainActor
@Suite struct RegexFindTests {
    static let sample = "Call 555-1234 or 555-9876.\n"
    typealias Editor = EditorBusTests.Editor

    private func post(_ name: Notification.Name, _ info: [String: Any] = [:]) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: info)
    }

    /// What the editor answered a find with — its count, and its problem if it
    /// had one.
    private func find(_ query: String, regex: Bool, in editor: Editor) -> (count: Int?, problem: String?) {
        final class Answer: @unchecked Sendable { var count: Int?; var problem: String? }
        let answer = Answer()
        let token = NotificationCenter.default.addObserver(forName: EditorBus.findResults(editor: editor.id),
                                                           object: nil, queue: nil) { note in
            answer.count = note.userInfo?["count"] as? Int
            answer.problem = note.userInfo?["problem"] as? String
        }
        defer { NotificationCenter.default.removeObserver(token) }
        post(EditorBus.findQuery(editor: editor.id), ["query": query, "regex": regex, "currentIndex": 0])
        return (answer.count, answer.problem)
    }

    @Test("A regular-expression find counts its matches and selects the first")
    func aRegularExpressionFindCountsAndSelects() {
        let editor = Editor(text: Self.sample)
        defer { editor.close() }
        let answer = find("\\d{3}-\\d{4}", regex: true, in: editor)
        #expect(answer.count == 2)
        #expect(answer.problem == nil)
        #expect(editor.selected == "555-1234")
    }

    @Test("Replace All expands each match's own groups")
    func replaceAllExpandsEachMatchsGroups() {
        let editor = Editor(text: Self.sample)
        defer { editor.close() }
        _ = find("(\\d{3})-(\\d{4})", regex: true, in: editor)
        post(EditorBus.replaceAll(editor: editor.id), ["replacement": "$2-$1"])
        #expect(editor.document.text == "Call 1234-555 or 9876-555.\n")
    }

    @Test("Replace expands the selected match's groups, and only that match")
    func replaceExpandsTheSelectedMatch() {
        let editor = Editor(text: Self.sample)
        defer { editor.close() }
        _ = find("(\\d{3})-(\\d{4})", regex: true, in: editor)
        post(EditorBus.replaceCurrent(editor: editor.id), ["replacement": "($1) $2"])
        #expect(editor.document.text == "Call (555) 1234 or 555-9876.\n")
        // And the find moves on to the next match.
        #expect(editor.selected == "555-9876")
    }

    @Test("A pattern that cannot be read comes back as a problem, and selects nothing")
    func anUnreadablePatternIsAProblem() {
        let editor = Editor(text: Self.sample)
        defer { editor.close() }
        let answer = find("(\\d{3}", regex: true, in: editor)
        #expect(answer.count == 0)
        #expect(answer.problem == FindPattern.Problem.invalid.rawValue)
        #expect(editor.selection.length == 0)
        // Replace All with nothing found leaves the note alone.
        post(EditorBus.replaceAll(editor: editor.id), ["replacement": "x"])
        #expect(editor.document.text == Self.sample)
    }

    @Test("Without the flag a query is a phrase, punctuation and all")
    func withoutTheFlagItIsAPhrase() {
        let editor = Editor(text: "a.c abc\n")
        defer { editor.close() }
        #expect(find("a.c", regex: false, in: editor).count == 1)
        #expect(find("a.c", regex: true, in: editor).count == 2)
        // A phrase's replacement is its own text, `$1` included.
        _ = find("abc", regex: false, in: editor)
        post(EditorBus.replaceAll(editor: editor.id), ["replacement": "$1"])
        #expect(editor.document.text == "a.c $1\n")
    }
}
