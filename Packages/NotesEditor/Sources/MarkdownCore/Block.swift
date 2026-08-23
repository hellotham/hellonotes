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
    /// space, and any checkbox) — a count of *characters*.
    public var contentOffset: Int
    /// The same place as a *column*, with tabs expanded to the next multiple of
    /// four. The two differ the moment a tab is involved, and conflating them
    /// is what made `-\t\tfoo` — an item holding indented code — read as an
    /// item holding the word `foo`.
    public var contentColumn: Int
}

public enum BlockKind: Sendable, Equatable {
    /// One or more consecutive text lines.
    case paragraph
    /// ATX (`# …`) or setext (underlined) heading. A setext block spans the
    /// text line(s) plus the underline line.
    case heading(level: Int, setext: Bool)
    /// ``` / ~~~ fence, open line through close line (or EOF when unclosed).
    case fencedCode(info: String, closed: Bool)
    /// A run of 4-space (or tab) indented lines forming a code block.
    case indentedCode
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
    /// A raw HTML block. `condition` is CommonMark's start-condition number
    /// (1…7, §4.6), because it is also what decides where the block *ends* —
    /// types 1–5 close on a matching end string, 6 and 7 on a blank line.
    /// `closed` is false when the end condition never arrived (EOF, or a
    /// half-typed `<!--`), which is the normal state while you are typing one.
    case htmlBlock(condition: Int, closed: Bool)
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
        // An HTML *block* is raw: CommonMark does not parse Markdown inside
        // one, so `<div>\n*foo*\n</div>` keeps its asterisks. (An inline
        // `<span>` inside a paragraph is a different thing and still does.)
        case .fencedCode, .indentedCode, .mathBlock, .thematicBreak, .frontMatter,
             .blank, .htmlBlock: false
        }
    }
}
