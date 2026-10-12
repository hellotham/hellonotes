//
//  CompletionChoice.swift
//  HelloNotes
//
//  The keyboard's part in the list of suggestions by the caret.
//
//  The list of notes and tags offered while a `[[link` or a `#tag` is typed
//  could only be clicked or tapped — its own comment said why: the text view
//  keeps first responder, so the list never had a key. The editor asks the
//  host before it acts on ↑, ↓, Return, Tab or Escape now
//  (`CompletionKeyHandler`), and this is what the host answers from
//  (implemented.md §51.44).
//
//  Two rules, each there to keep a key from being taken that was meant for
//  the text:
//
//  - **Nothing is chosen until an arrow chooses it**, so Return is Return. A
//    line that ends in a tag — `#todo`, Return — is the commonest thing typed
//    beside this list, and a list that opened with its first row chosen would
//    take that Return and write `#todo-list `.
//  - **The arrows are the list's only while it is being typed into.** The
//    list also shows when the caret merely stands in a link that is already
//    there, and ↓ through a paragraph must go on down the paragraph. So the
//    arrows wait for something typed in the construct, and are given back
//    when the caret leaves it.
//
//  Escape sends the list away until the next thing typed.
//

import Foundation
import MarkdownEditor

@MainActor
@Observable
final class CompletionChoice {
    /// The row the arrows have chosen, if they have chosen one.
    private(set) var row: Int?
    /// Sent away with Escape, until the next thing typed.
    private(set) var isDismissed = false

    /// Whether the list is one being typed into, so the arrows are its.
    ///
    /// Not observed, with the rest below: they change on keystrokes that draw
    /// nothing, and the editor's host is not to be drawn again for those.
    @ObservationIgnored private(set) var isLive = false
    @ObservationIgnored private var anchor: Int?
    @ObservationIgnored private var kind: EditorDocument.InlineContext.Kind?
    @ObservationIgnored private var query = ""
    /// The document's revision when the editor last reported — a report at
    /// another revision is one that followed typing.
    @ObservationIgnored private var lastRevision: Int?

    /// The editor's report of what the caret is in, on every caret move.
    func report(_ context: EditorDocument.InlineContext?, revision: Int) {
        defer { lastRevision = revision }
        guard let context else {
            leave()
            return
        }
        let typed = lastRevision.map { $0 != revision } ?? false
        if anchor != context.range.location || kind != context.kind {
            // Another construct, or this one just entered: live only if it
            // was typed into being.
            anchor = context.range.location
            kind = context.kind
            query = context.query
            isLive = typed
            row = nil
            isDismissed = false
            return
        }
        if typed {
            isLive = true
            isDismissed = false
        }
        // Other words, other rows: a row chosen among the old ones is not a
        // choice among the new.
        if context.query != query {
            query = context.query
            row = nil
        }
    }

    /// The caret has left the construct, or the note has changed.
    func leave() {
        anchor = nil
        kind = nil
        query = ""
        isLive = false
        row = nil
        isDismissed = false
    }

    /// Whether `key` is the list's now, given the `count` of rows it shows.
    /// Asked by the editor before every key, so it changes nothing.
    func wants(_ key: CompletionKey, count: Int) -> Bool {
        // No construct, no list — whatever count is passed.
        guard anchor != nil, count > 0, !isDismissed else { return false }
        switch key {
        case .up, .down: return isLive
        case .accept: return row.map { $0 < count } ?? false
        case .dismiss: return true
        }
    }

    /// Take `key`. Returns the row to accept, for `.accept`.
    func take(_ key: CompletionKey, count: Int) -> Int? {
        guard wants(key, count: count) else { return nil }
        switch key {
        case .down:
            row = row.map { min($0 + 1, count - 1) } ?? 0
        case .up:
            row = row.map { max($0 - 1, 0) } ?? count - 1
        case .accept:
            return row
        case .dismiss:
            isDismissed = true
            row = nil
        }
        return nil
    }
}

/// The suggestions for what the caret is in, ranked once.
///
/// Ranking is every title and alias in the collection, folded and sorted —
/// 3.4 ms at 2,500 titles, 12 ms at 10,000 — and the editor's host asked for
/// it again each time it drew, and then each time the editor asked whether a
/// key was the list's: five times for one read of an iOS text view's key
/// commands, all to learn a count (found in review, implemented.md §51.44).
/// The list is the same list until the words typed change, so it is kept
/// until they do. Not observed: it is read while the host draws, and filling
/// it is not a reason to draw again.
@MainActor
final class CompletionMemo {
    private var kind: EditorDocument.InlineContext.Kind?
    private var query: String?
    private var kept: [WikiCompletion] = []
    /// How many times the list has been ranked — for a test to count.
    private(set) var rankings = 0

    /// The suggestions for `context`: the ones kept if it asks what the last
    /// did, and otherwise `rank`ed now.
    func matches(for context: EditorDocument.InlineContext, rank: () -> [WikiCompletion]) -> [WikiCompletion] {
        if kind == context.kind, query == context.query { return kept }
        kind = context.kind
        query = context.query
        kept = rank()
        rankings += 1
        return kept
    }

    /// The caret has left, or the note has changed: what was kept answers
    /// nothing now. The next list is ranked afresh, which is also when new
    /// notes and tags are taken up.
    func forget() {
        kind = nil
        query = nil
        kept = []
    }
}
