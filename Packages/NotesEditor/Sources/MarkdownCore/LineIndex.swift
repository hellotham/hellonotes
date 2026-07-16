//
//  LineIndex.swift
//  MarkdownCore
//
//  The line table: UTF-16 start offsets of every line in the document.
//  Built once with a raw buffer scan, then *spliced* per edit — an edit
//  re-scans only its own replacement text; every following line start is
//  shifted by the edit's delta. That keeps per-keystroke cost proportional
//  to the edit, with one O(lines-after-edit) integer shift (a memmove-class
//  operation — ~microseconds even at 100k lines).
//

import Foundation

public struct LineIndex: Sendable, Equatable {
    /// Start offset of each line. Always contains at least [0]; a trailing
    /// newline yields a final empty line, matching NSString's line model.
    public private(set) var starts: [Int]

    /// Total UTF-16 length of the indexed text.
    public private(set) var length: Int

    public var lineCount: Int { starts.count }

    // MARK: - Construction

    public init(text: NSString) {
        length = text.length
        starts = [0]
        starts.reserveCapacity(max(16, length / 32))
        // Bulk-copy into a raw buffer once: scanning unichar-by-unichar via
        // NSString.character(at:) would pay an objc_msgSend per character.
        let buffer = UnsafeMutablePointer<unichar>.allocate(capacity: max(length, 1))
        defer { buffer.deallocate() }
        text.getCharacters(buffer, range: NSRange(location: 0, length: length))
        for i in 0..<length where buffer[i] == 0x0A {
            starts.append(i + 1)
        }
    }

    // MARK: - Queries

    /// Index of the line containing `offset` (the end-of-text position
    /// belongs to the last line).
    public func lineNumber(at offset: Int) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// The full range of line `i`, including its trailing newline (if any).
    public func lineRange(_ i: Int) -> NSRange {
        let start = starts[i]
        let end = i + 1 < starts.count ? starts[i + 1] : length
        return NSRange(location: start, length: end - start)
    }

    /// The range of line `i` without its trailing newline.
    public func contentRange(_ i: Int, in text: NSString) -> NSRange {
        var r = lineRange(i)
        if r.length > 0 && text.character(at: r.location + r.length - 1) == 0x0A {
            r.length -= 1
        }
        return r
    }

    // MARK: - Splice

    /// Update the table for `edit`, given the *new* text. Only the
    /// replacement region is re-scanned for newlines.
    public mutating func apply(_ edit: TextEdit, newText: NSString) {
        let delta = edit.delta
        let oldEditEnd = edit.range.location + edit.range.length

        // Line entries strictly inside the edited region disappear; find the
        // splice window [firstRemoved, firstKept) in the starts array.
        let editLine = lineNumber(at: edit.range.location)
        var firstRemoved = editLine + 1
        // (entries ≤ edit start stay; entries in (start, oldEnd] go)
        var firstKept = firstRemoved
        while firstKept < starts.count && starts[firstKept] <= oldEditEnd {
            firstKept += 1
        }

        // New line starts introduced by the replacement text.
        var inserted: [Int] = []
        let newRange = edit.newRange
        if newRange.length > 0 {
            let buffer = UnsafeMutablePointer<unichar>.allocate(capacity: newRange.length)
            defer { buffer.deallocate() }
            newText.getCharacters(buffer, range: newRange)
            for i in 0..<newRange.length where buffer[i] == 0x0A {
                inserted.append(newRange.location + i + 1)
            }
        }

        // Kept tail shifts by delta.
        if delta != 0 {
            for i in firstKept..<starts.count { starts[i] += delta }
        }
        if firstRemoved <= firstKept {
            starts.replaceSubrange(firstRemoved..<firstKept, with: inserted)
        }
        length += delta

        // An edit that removed the text's final newline can leave a stale
        // trailing entry; an edit at the very end can also make the last
        // entry equal to length (legitimate: trailing newline → empty line).
        while let last = starts.last, last > length { starts.removeLast() }
        if starts.isEmpty { starts = [0] }
    }
}
