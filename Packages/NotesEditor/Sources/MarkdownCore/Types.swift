//
//  Types.swift
//  MarkdownCore
//
//  Shared value types for the editing kernel. Everything here is a plain
//  Sendable value in **UTF-16 offsets** — the coordinate system NSString,
//  NSTextStorage and TextKit use — so no conversion layer ever sits between
//  the parser and the text view.
//

import Foundation

/// A single text mutation: `range` in the *old* text was replaced by
/// `replacementLength` UTF-16 units. This is exactly the shape
/// `NSTextStorage` reports edits in, so the editor forwards them verbatim.
public struct TextEdit: Sendable, Equatable {
    public let range: NSRange
    public let replacementLength: Int

    public init(range: NSRange, replacementLength: Int) {
        self.range = range
        self.replacementLength = replacementLength
    }

    /// How much every offset after the edit shifted.
    public var delta: Int { replacementLength - range.length }

    /// The range the replacement occupies in the *new* text.
    public var newRange: NSRange { NSRange(location: range.location, length: replacementLength) }
}

/// The parsed shape of a document: its line table and block list. Produced
/// by ``BlockParser`` and updated incrementally per edit — the kernel's
/// invariant is that `incremental(applying:)` always equals a full reparse
/// (enforced by fuzz tests).
public struct ParseResult: Sendable {
    public var lines: LineIndex
    public var blocks: [Block]

    public init(lines: LineIndex, blocks: [Block]) {
        self.lines = lines
        self.blocks = blocks
    }

    /// The block containing `offset` (binary search; blocks tile the text).
    public func blockIndex(at offset: Int) -> Int? {
        var lo = 0, hi = blocks.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = blocks[mid].range
            if offset < r.location { hi = mid - 1 }
            else if offset >= r.location + r.length {
                // The final block also owns the end-of-document position.
                if mid == blocks.count - 1 && offset == r.location + r.length { return mid }
                lo = mid + 1
            } else { return mid }
        }
        return blocks.isEmpty ? nil : (lo < blocks.count ? lo : blocks.count - 1)
    }
}
