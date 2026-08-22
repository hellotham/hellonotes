//
//  BlockBoxes.swift
//  MarkdownEditor
//
//  The parsed document, seen as CSS boxes — and the `NSParagraphStyle`s that
//  make TextKit lay those boxes out the way WebKit does.
//
//  Two things here are easy to get wrong and were both wrong:
//
//  **Margins collapse.** In CSS the space between a paragraph
//  (`margin-bottom: 16`) and the heading after it (`margin-top: 24`) is 24 —
//  the larger of the two, not their sum. TextKit's `paragraphSpacing` and
//  `paragraphSpacingBefore` just add. So the editor never sets both: it asks
//  `GFMBoxMetrics.gap(after:before:)` for the one collapsed number and puts it
//  below the earlier block.
//
//  **A blank line is not a margin.** The editor's storage is raw Markdown, so
//  the blank line a writer types between two paragraphs is a real line with a
//  real height — about 24pt at the default size, where GitHub's margin is 16,
//  and 48 where the writer left two blank lines and GitHub still shows 16.
//  That single fact accounted for most of the drift down a long note: every
//  paragraph break was 8pt out, and the error accumulated. Here a run of blank
//  lines is given exactly the gap the stylesheet would have left, divided
//  between its lines — so the source is unchanged, the caret still has
//  somewhere to sit on each blank line, and the rendered result matches.
//
//  `paragraphSpacing` is per *paragraph*, not per block: TextKit ends a
//  paragraph at every newline, so setting it over a five-line blockquote would
//  space all five lines apart. Every gap therefore lands on the block's last
//  line only.
//

import Foundation
import MarkdownCore
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

nonisolated enum BlockBoxes {

    /// The smallest a blank line may collapse to. Zero would be right for
    /// leading and trailing blank lines (GitHub renders nothing for them), but
    /// a zero-height line is one the caret cannot be seen on, so it keeps a
    /// hairline of its own.
    static let minimumBlankLine: CGFloat = 0.5

    // MARK: - Blocks as CSS boxes

    /// Nesting depth of a list item, from its source indent. Markdown nests a
    /// list when the item indents past its parent's marker, which for the
    /// `- ` / `1. ` markers people actually write is two columns per level.
    static func listDepth(_ info: ListInfo) -> Int { max(0, info.indent / 2) }

    private static func isBlank(_ block: Block) -> Bool {
        if case .blank = block.kind { return true }
        return false
    }

    /// Index of the nearest non-blank block before `i`. Blank *runs* parse as
    /// a single block, so this never looks back further than two.
    static func previousContent(_ i: Int, in blocks: [Block]) -> Int? {
        var j = i - 1
        while j >= 0, isBlank(blocks[j]) { j -= 1 }
        return j >= 0 ? j : nil
    }

    /// Index of the nearest non-blank block after `i`.
    static func nextContent(_ i: Int, in blocks: [Block]) -> Int? {
        var j = i + 1
        while j < blocks.count, isBlank(blocks[j]) { j += 1 }
        return j < blocks.count ? j : nil
    }

    /// The CSS box `blocks[i]` renders as, or nil for a blank run (which is not
    /// a box at all — it is the space between two).
    static func box(at i: Int, in blocks: [Block], text: NSString) -> GFMBoxMetrics.Box? {
        guard blocks.indices.contains(i) else { return nil }
        switch blocks[i].kind {
        case .blank:
            return nil
        case .paragraph:
            return .paragraph
        case .heading(let level, _):
            return .heading(level: level)
        case .fencedCode, .indentedCode, .mathBlock:
            return .codeBlock
        case .blockquote:
            return .quote
        case .table:
            return .table
        case .thematicBreak:
            return .thematicBreak
        case .frontMatter:
            return .frontMatter
        case .listItem(let info):
            let depth = listDepth(info)
            let prev = previousContent(i, in: blocks)
            let next = nextContent(i, in: blocks)
            var previousDepth: Int?
            if let prev, case .listItem(let p) = blocks[prev].kind { previousDepth = listDepth(p) }
            var nextDepth: Int?
            if let next, case .listItem(let n) = blocks[next].kind { nextDepth = listDepth(n) }

            // Two adjacent items at the same depth belong to the same list only
            // if they were written with the same marker: `1.` after `-` starts
            // a new list, and so does `*` after `-`.
            let continues = { (other: Int?) -> Bool in
                guard let other, let d = other == prev ? previousDepth : nextDepth else { return false }
                if d != depth { return true }
                return marker(blocks[other], text: text) == marker(blocks[i], text: text)
            }

            let loose = listIsLoose(around: i, depth: depth, in: blocks, text: text)
            let top: GFMBoxMetrics.ListItemTop
            if let previousDepth, continues(prev) {
                if previousDepth < depth {
                    // Opening a sub-list inside the item above: whether there is
                    // a margin between them is the *parent* list's looseness.
                    top = .opensNestedList(looseParent:
                        listIsLoose(around: prev!, depth: previousDepth, in: blocks, text: text))
                } else {
                    top = .sibling(loose: loose)
                }
            } else {
                top = .opensList
            }
            // `ul ul { margin-bottom: 0 }`, so only the item that ends the list
            // outright carries the list's bottom margin. An item followed by a
            // shallower one is closing a nested list; the gap there is the next
            // item's `li + li`, not this one's.
            let last = nextDepth == nil || (nextDepth! == depth && !continues(next))
            return .listItem(top: top, lastInList: last)
        }
    }

    /// Whether the list that owns the item at `i` — the one at `depth`, not any
    /// list nested inside it — is loose.
    ///
    /// Linear in the length of that one list, which is what makes it affordable
    /// on the editing path: a keystroke restyles three blocks and each walks
    /// its own list, never the document.
    static func listIsLoose(around i: Int, depth: Int, in blocks: [Block], text: NSString) -> Bool {
        let mine = marker(blocks[i], text: text)
        /// Is `j` still inside *this* list? An item shallower than us belongs to
        /// the list that encloses ours and ends it; an item at our own depth
        /// with a different marker starts a new list rather than continuing
        /// this one — `1.` after `-`, or `*` after `-`. Missing that ran two
        /// adjacent lists together, so a blank line between them loosened both.
        func inList(_ j: Int) -> Bool {
            guard case .listItem(let info) = blocks[j].kind else { return false }
            let d = listDepth(info)
            if d < depth { return false }
            if d == depth, marker(blocks[j], text: text) != mine { return false }
            return true
        }
        var lo = i, hi = i
        while let p = previousContent(lo, in: blocks), inList(p) { lo = p }
        while let n = nextContent(hi, in: blocks), inList(n) { hi = n }
        var j = lo
        while let n = nextContent(j, in: blocks), n <= hi {
            // `n > j + 1` means at least one blank block sits between them.
            if n > j + 1,
               case .listItem(let a) = blocks[j].kind,
               case .listItem(let b) = blocks[n].kind,
               min(listDepth(a), listDepth(b)) == depth {
                return true
            }
            j = n
        }
        return false
    }

    /// What starts this item: its bullet character, or the delimiter after an
    /// ordered marker. CommonMark starts a *new* list when either changes.
    static func marker(_ block: Block, text: NSString) -> unichar {
        guard case .listItem(let info) = block.kind, info.markerLength > 0 else { return 0 }
        let last = block.range.location + info.indent + info.markerLength - 1
        guard last >= 0, last < text.length else { return 0 }
        return text.character(at: last)
    }

    // MARK: - Gaps

    /// The collapsed gap that belongs *below* `blocks[i]`, or 0 when it is the
    /// document's last box (`> *:last-child { margin-bottom: 0 }`).
    static func gapAfter(_ i: Int, in blocks: [Block], text: NSString,
                         metrics: GFMBoxMetrics) -> CGFloat {
        guard let mine = box(at: i, in: blocks, text: text),
              let next = nextContent(i, in: blocks),
              let theirs = box(at: next, in: blocks, text: text) else { return 0 }
        return metrics.gap(after: mine, before: theirs)
    }

    /// How the gap between two boxes is shared out between the blank lines
    /// that separate them and any lines at the end of the block above that the
    /// renderer collapses away — a setext heading's `===` underline, the blank
    /// lines a parser leaves inside an indented code block.
    ///
    /// Shared, rather than "the collapsed lines get a hairline and the blanks
    /// get the rest", for two reasons. A hairline only ever *adds*, so it drifts
    /// once per setext heading down a long document; and a sub-point line
    /// height is one TextKit rounds, which it did differently at different pane
    /// widths, so the same note was half a point out at one width and exact at
    /// another. Split evenly there are no sub-point lines at all, and the
    /// collapsed line becomes something the caret can actually be seen on.
    static func gapShares(blankRunAt i: Int, in blocks: [Block], text: NSString,
                          lines: LineIndex, metrics: GFMBoxMetrics)
    -> (tail: CGFloat, blanks: CGFloat) {
        guard let prev = previousContent(i, in: blocks),
              let next = nextContent(i, in: blocks),
              let a = box(at: prev, in: blocks, text: text),
              let b = box(at: next, in: blocks, text: text) else { return (0, 0) }
        let gap = metrics.gap(after: a, before: b)
        let tailLines = collapsedTail(blocks[prev], text: text, lines: lines)
        guard tailLines > 0 else { return (0, gap) }
        let blankLines = max(1, blocks[i].lineCount)
        let each = gap / CGFloat(tailLines + blankLines)
        return (each * CGFloat(tailLines), each * CGFloat(blankLines))
    }

    /// Total height a blank run must occupy — its share of the gap between the
    /// boxes it separates. Nothing at the document's edges, where the
    /// first/last-child rules zero the margin.
    static func blankRunHeight(_ i: Int, in blocks: [Block], text: NSString,
                               lines: LineIndex, metrics: GFMBoxMetrics) -> CGFloat {
        gapShares(blankRunAt: i, in: blocks, text: text, lines: lines, metrics: metrics).blanks
    }

    /// How many lines at the end of `block` the renderer collapses away.
    static func collapsedTail(_ block: Block, text: NSString, lines: LineIndex) -> Int {
        let last = block.firstLine + block.lineCount - 1
        switch block.kind {
        case .heading(_, let setext):
            return setext && last > block.firstLine ? 1 : 0
        case .indentedCode:
            var line = last
            while line > block.firstLine, isBlankLine(line, text: text, lines: lines) { line -= 1 }
            return last - line
        default:
            return 0
        }
    }

    /// Whether a source line holds nothing but spaces and tabs.
    static func isBlankLine(_ lineNumber: Int, text: NSString, lines: LineIndex) -> Bool {
        let content = lines.contentRange(lineNumber, in: text)
        for offset in 0..<content.length {
            let c = text.character(at: content.location + offset)
            if c != 0x20 && c != 0x09 { return false }
        }
        return true
    }

    // MARK: - Paragraph styles

    /// Line height for a box — `line-height` in the stylesheet.
    static func lineHeight(_ box: GFMBoxMetrics.Box, _ m: GFMBoxMetrics) -> CGFloat {
        switch box {
        case .heading(let level): m.headingLineHeight(level)
        case .codeBlock: m.codeLineHeight
        default: m.bodyLineHeight
        }
    }

    /// The style every line of the block gets: line height and indents, and no
    /// spacing at all — the gap belongs to the last line alone.
    static func baseStyle(for block: Block, box: GFMBoxMetrics.Box,
                          text: NSString, theme: EditorTheme) -> NSMutableParagraphStyle {
        let m = theme.metrics
        let style = NSMutableParagraphStyle()
        let height = lineHeight(box, m)
        style.minimumLineHeight = height
        style.maximumLineHeight = height

        switch box {
        case .listItem:
            guard case .listItem(let info) = block.kind else { break }
            // `ul { padding-left: 2em }`, once per nesting level: the item's
            // text starts there and wrapped lines line up under it.
            let content = m.listIndent * CGFloat(listDepth(info) + 1)
            style.headIndent = content
            // The marker sits in the padding to the left of the content, so the
            // first line starts by however wide the marker actually draws.
            style.firstLineHeadIndent = max(0, content - markerWidth(info, block: block, text: text, theme: theme))
        case .codeBlock:
            // `pre { padding: 16px }` — the horizontal half. The vertical half
            // is the collapsed fence lines (see `StyleApplier`).
            style.headIndent = m.codePadding
            style.firstLineHeadIndent = m.codePadding
            style.tailIndent = -m.codePadding
        case .quote:
            // Per line, in `StyleApplier.applyQuoteBars` — a blockquote's
            // indent is its `>` nesting, which varies line by line.
            break
        case .paragraph, .heading, .table, .thematicBreak, .frontMatter:
            break
        }
        return style
    }

    /// How far the item's own text is pushed right of `firstLineHeadIndent` by
    /// the marker that precedes it — measured, not assumed, because `1.` and
    /// `-` and `[x]` are three different widths and the content has to land on
    /// the same column whichever one was typed.
    private static func markerWidth(_ info: ListInfo, block: Block,
                                    text: NSString, theme: EditorTheme) -> CGFloat {
        let lineStart = block.range.location + info.indent
        let prefixLength = max(0, info.contentOffset - info.indent)
        guard prefixLength > 0, lineStart + prefixLength <= text.length else { return 0 }
        let prefix = NSMutableAttributedString(
            string: text.substring(with: NSRange(location: lineStart, length: prefixLength)),
            attributes: [.font: theme.body])
        // The `-` before a checkbox is concealed to nothing, the `[ ]` is drawn
        // as a box in the monospaced width it reserves, and the space after it
        // is concealed too — measured exactly as `StyleSpec` styles it, because
        // a measurement that disagrees with the drawing puts the text on a
        // column the Preview never uses.
        if info.task != nil {
            let markerRange = NSRange(location: 0, length: min(info.markerLength, prefix.length))
            if markerRange.length > 0 {
                prefix.addAttribute(.font, value: theme.concealed, range: markerRange)
            }
            let boxStart = info.markerLength + 1
            if boxStart + 3 <= prefix.length {
                prefix.addAttribute(.font, value: theme.mono,
                                    range: NSRange(location: boxStart, length: 3))
            }
            if boxStart + 4 <= prefix.length {
                prefix.addAttribute(.font, value: theme.concealed,
                                    range: NSRange(location: boxStart + 3, length: 1))
            }
        }
        return prefix.size().width
    }
}
