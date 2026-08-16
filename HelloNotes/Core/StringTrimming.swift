//
//  StringTrimming.swift
//  HelloNotes
//
//  Trailing-newline trimming, used wherever something is appended to a note
//  body: a tag line, a `## Related` link, a rewritten paragraph. Every one of
//  those has to answer "does this note already end in a newline?" and they must
//  all answer it the same way, or the same operation produces one blank line in
//  one place and three in another.
//
//  It lived `fileprivate` inside NoteEditorView until the AI actions moved out
//  to the surfaces that offer them and needed it too.
//

import Foundation

extension String {
    /// The string with every trailing `\n` / `\r` removed.
    func trimmingTrailingNewlines() -> String {
        var s = self
        while let last = s.last, last == "\n" || last == "\r" { s.removeLast() }
        return s
    }
}
