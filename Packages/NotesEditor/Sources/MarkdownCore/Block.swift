//
//  Block.swift
//  MarkdownCore
//
//  Block-level structure. A document is a tiling of blocks — every UTF-16
//  position belongs to exactly one block, blanks included. Blocks carry the
//  information the styler and the layout system need; inline structure is
//  parsed separately, per block, on demand.
//

import Foundation

/// Task-list checkbox state on a list item.
public enum TaskState: Sendable, Equatable {
    case unchecked
    case checked
}

/// Everything the styler needs about a list item's marker line.
public struct ListInfo: Sendable, Equatable {
    /// Leading spaces before the marker (nesting depth indicator).
    public var indent: Int
    /// UTF-16 length of the marker itself (`-` = 1, `12.` = 3).
    public var markerLength: Int
    public var isOrdered: Bool
    /// Present when the item starts with a `[ ]` / `[x]` checkbox.
    public var task: TaskState?
    /// Offset from the line start to the item's content (after marker,
    /// space, and any checkbox).
    public var contentOffset: Int
}

public enum BlockKind: Sendable, Equatable {
    /// One or more consecutive text lines.
    case paragraph
    /// ATX (`# …`) or setext (underlined) heading. A setext block spans the
    /// text line(s) plus the underline line.
    case heading(level: Int, setext: Bool)
    /// ``` / ~~~ fence, open line through close line (or EOF when unclosed).
    case fencedCode(info: String, closed: Bool)
    /// `$$` display-math fence.
    case mathBlock(closed: Bool)
    /// A run of consecutive `>` lines. `callout` holds the `[!type]` when
    /// the first line declares one (Obsidian-style callout).
    case blockquote(callout: String?)
    /// One list item: its marker line plus indented continuation lines.
    case listItem(ListInfo)
    /// Pipe table: header, delimiter row, data rows.
    case table
    case thematicBreak
    /// YAML front matter (`---` fences at the very top of the document).
    case frontMatter
    /// A run of blank (whitespace-only) lines.
    case blank
}

public struct Block: Sendable, Equatable {
    public var kind: BlockKind
    /// Absolute UTF-16 range, including the trailing newline of its last line.
    public var range: NSRange
    /// First line number and line count (kept in sync by the splicer).
    public var firstLine: Int
    public var lineCount: Int

    public init(kind: BlockKind, range: NSRange, firstLine: Int, lineCount: Int) {
        self.kind = kind
        self.range = range
        self.firstLine = firstLine
        self.lineCount = lineCount
    }

    /// Whether inline Markdown is parsed inside this block's content.
    public var hasInlineContent: Bool {
        switch kind {
        case .paragraph, .heading, .blockquote, .listItem, .table: true
        case .fencedCode, .mathBlock, .thematicBreak, .frontMatter, .blank: false
        }
    }
}
