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

    /// The smallest a blank line that is *part of a margin* may collapse to.
    ///
    /// It is a floor on the share each line of a run gets, and it only binds
    /// where the margin being divided is smaller than the run — a writer who
    /// left forty blank lines between two paragraphs, where GitHub still leaves
    /// 16. There the hairline is the honest answer: those lines are inside the
    /// gap, the reader can see there is space, and the caret has a run of them
    /// to move through.
    ///
    /// It is *not* the floor at the document's edges. A blank line above the
    /// first painted box or below the last is not part of any margin — see
    /// `isOutsidePaintedContent` — and takes `collapsedLine` instead.
    static let minimumBlankLine: CGFloat = 0.5

    /// The smallest a line the page has nothing for may collapse to — source
    /// the reader never sees, such as a link reference definition, and blank
    /// lines outside everything the page paints.
    ///
    /// It gets no hairline of its own, unlike `minimumBlankLine` above, and the
    /// difference is the caret: a line inside a margin keeps enough height to
    /// say the margin is there, while a line the page draws nothing for is
    /// taken out of the collapsed set the moment the caret is inside it and
    /// lays out at its full height. Nothing is left to see, so it takes no
    /// room — which is what the rendered page does with it.
    ///
    /// Not zero: `maximumLineHeight = 0` means *unlimited* to TextKit, so a
    /// line asked for no height gets its natural one instead.
    static let collapsedLine: CGFloat = 0.01

    // MARK: - Blocks as CSS boxes

    /// Nesting depth of a list item, from its source indent. Markdown nests a
    /// list when the item indents past its parent's marker, which for the
    /// `- ` / `1. ` markers people actually write is two columns per level.
    static func listDepth(_ info: ListInfo) -> Int { max(0, info.indent / 2) }

    private static func isBlank(_ block: Block) -> Bool {
        if case .blank = block.kind { return true }
        return false
    }

    /// Whether the rendered document has nothing at all for this block.
    ///
    /// A link reference definition is the case: cmark consumes `[foo]: /url`
    /// and emits no element, so the Preview shows a gap where the editor showed
    /// two lines of source. `GFMLiveStyle.unrenderedRanges` finds them by
    /// asking cmark what it kept rather than by recognising the construct.
    static func isUnrendered(_ block: Block, text: NSString, unrendered: [NSRange]) -> Bool {
        guard !unrendered.isEmpty, block.range.length > 0 else { return false }
        // Compared on the block's *content* — its first non-blank character to
        // its last. A block's range starts at the line's left margin and ends
        // past a newline, neither of which any node covers, so comparing the
        // raw range never matched an indented definition.
        var lo = block.range.location
        var hi = block.range.location + block.range.length
        func blank(_ i: Int) -> Bool {
            let c = text.character(at: i)
            return c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
        }
        while lo < hi, blank(lo) { lo += 1 }
        while hi > lo, blank(hi - 1) { hi -= 1 }
        guard hi > lo else { return false }
        return unrendered.contains { lo >= $0.location && hi <= $0.location + $0.length }
    }

    /// Whether this block occupies vertical space in the rendered document.
    static func isRendered(_ block: Block, in blocks: [Block], at index: Int,
                           text: NSString, unrendered: [NSRange]) -> Bool {
        !isBlank(block) && !isUnrendered(block, text: text, unrendered: unrendered)
    }

    /// Index of the nearest non-blank block before `i`. Blank *runs* parse as
    /// a single block, so this never looks back further than two.
    static func previousContent(_ i: Int, in blocks: [Block],
                                text: NSString? = nil, unrendered: [NSRange] = []) -> Int? {
        var j = i - 1
        while j >= 0, skips(blocks[j], text, unrendered) { j -= 1 }
        return j >= 0 ? j : nil
    }

    /// Blocks the rendered document shows nothing for are stepped over exactly
    /// as blank ones are — they are part of the space between two boxes, not a
    /// box in their own right.
    private static func skips(_ block: Block, _ text: NSString?, _ unrendered: [NSRange]) -> Bool {
        if isBlank(block) { return true }
        guard let text, !unrendered.isEmpty else { return false }
        return isUnrendered(block, text: text, unrendered: unrendered)
    }

    /// Index of the nearest non-blank block after `i`.
    static func nextContent(_ i: Int, in blocks: [Block],
                            text: NSString? = nil, unrendered: [NSRange] = []) -> Int? {
        var j = i + 1
        while j < blocks.count, skips(blocks[j], text, unrendered) { j += 1 }
        return j < blocks.count ? j : nil
    }

    /// Where one block sits relative to the list an item belongs to.
    ///
    /// One predicate, because four callers needed the same answer and three of
    /// them computed their own. `box(at:)` compared **content columns** —
    /// CommonMark's rule — while `listIsLoose` compared `indent / 2`, so the
    /// two disagreed about which items were in a list: a `1. a` / blank /
    /// `  2. b` pair was one list to `box` (which gave the second item its
    /// `li + li` margin) and two separate lists to `listIsLoose` (which
    /// therefore scored a genuinely loose list tight, and left every item's
    /// text 16pt short of the `<p>` the page wraps it in).
    enum ListMembership: Equatable {
        /// Another item of the same list.
        case sibling
        /// Inside one of this list's items: an item of a list nested in it, a
        /// blank line, or any other block indented to the item's content
        /// column. Part of the list's extent, but not one of its items — which
        /// matters, because CommonMark makes looseness a property of an item's
        /// *own* blank lines and not of anything nested inside it.
        case interior
        /// Past the list's end.
        case outside
    }

    /// How `block` relates to the list whose current item is `member`.
    static func membership(of block: Block, in member: Block,
                           text: NSString) -> ListMembership {
        guard case .listItem(let mine) = member.kind else { return .outside }
        if case .listItem(let theirs) = block.kind {
            // Indented to our own content column: this opens a list *inside*
            // ours. CommonMark's rule, and not `indent / 2` — that guess
            // invents a level for a list stepped one space at a time (`- a` /
            // ` - b` / `  - c`), where every item is a sibling of the last.
            if theirs.indent >= mine.contentColumn { return .interior }
            // …and the mirror: we are the nested one, so this is an item of
            // the list that encloses ours and our list has ended.
            if mine.indent >= theirs.contentColumn { return .outside }
            // Siblings continue the same list only if they were written with
            // the same marker: `1.` after `-` starts a new list, and so does
            // `*` after `-`.
            return marker(block, text: text) == marker(member, text: text) ? .sibling : .outside
        }
        // A blank run is the space between two of the list's boxes, not a box
        // of its own, so it never ends anything.
        if case .blank = block.kind { return .interior }
        // An item with nothing on it has used up the one blank line an item is
        // allowed to begin with, so nothing below it is its content however far
        // it is indented: `-` / blank / `  foo` is an empty item and a
        // paragraph of the document. Read as the item's second block it made a
        // one-item list loose and put a `<p>`'s margins around an empty `<li>`.
        if isEmptyItem(member, text: text) { return .outside }
        // Any other block indented to the item's content column is content of
        // that item — a second paragraph the parser could not keep inside the
        // item's own range because the line dedented out of a *nested* item
        // first (`* foo` / `  * bar` / blank / `  baz`).
        return firstLineIndent(block, text: text) >= mine.contentColumn ? .interior : .outside
    }

    /// An item with nothing on it at all: a marker, and one line.
    static func isEmptyItem(_ block: Block, text: NSString) -> Bool {
        guard case .listItem(let info) = block.kind, block.lineCount == 1 else { return false }
        let end = min(block.range.location + block.range.length, text.length)
        var i = min(block.range.location + info.contentOffset, end)
        while i < end {
            if !isSpace(text.character(at: i)) { return false }
            i += 1
        }
        return true
    }

    /// The CSS box `blocks[i]` renders as, or nil for a blank run (which is not
    /// a box at all — it is the space between two).
    static func box(at i: Int, in blocks: [Block], text: NSString,
                    unrendered: [NSRange] = []) -> GFMBoxMetrics.Box? {
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
        case .htmlBlock:
            // Raw HTML brings its own box: a `<div>` has no margins of its own,
            // a `<p>` inside it has the paragraph's — and those live inside the
            // rendered fragment, which is what the editor measures.
            return .htmlBlock
        case .blockquote:
            return isEmptyQuote(blocks[i], text: text, unrendered: unrendered) ? .emptyQuote : .quote
        case .table:
            return .table
        case .thematicBreak:
            return .thematicBreak
        case .frontMatter:
            return .frontMatter
        case .listItem:
            let prev = previousContent(i, in: blocks)
            let next = nextContent(i, in: blocks)
            // Only another *item* can continue a list; anything else, however
            // it is indented, is the block after it.
            let previousIsItem = prev.map { isListItemBlock(blocks[$0]) } ?? false
            let nextIsItem = next.map { isListItemBlock(blocks[$0]) } ?? false

            /// Is `child` nested *inside* `parent`? `membership` answers it,
            /// which is the point: this used to be its own content-column
            /// comparison and `listIsLoose` used a different one.
            func nested(_ child: Int, in parent: Int) -> Bool {
                membership(of: blocks[child], in: blocks[parent], text: text) == .interior
            }
            let continues = { (other: Int?) -> Bool in
                guard let other, other == prev ? previousIsItem : nextIsItem else { return false }
                // Same list *family*, which is broader than same list: either
                // one being inside the other counts, whatever the markers say,
                // and siblings count when the markers match.
                if nested(i, in: other) { return true }
                return membership(of: blocks[other], in: blocks[i], text: text) != .outside
            }

            let loose = listIsLoose(around: i, in: blocks, text: text, unrendered: unrendered)
            let top: GFMBoxMetrics.ListItemTop
            if previousIsItem, let prev, continues(prev) {
                // Nested inside the item above, or a sibling of it? By the
                // *content column*, which is CommonMark's rule, and not by
                // `listDepth`'s indent/2 guess — that guess invents a level
                // for a list stepped one space at a time (`- a` / ` - b` /
                // `  - c`), so every other item was treated as opening a
                // sub-list and lost its `li + li` margin. Four such items
                // carried two gaps instead of three, on alternate rows.
                if nested(i, in: prev) {
                    // Opening a sub-list inside the item above. The margin
                    // between them belongs to whichever side wraps its text in
                    // a `<p>` — the parent item if the enclosing list is loose,
                    // this item if the sub-list is.
                    top = .opensNestedList(spaced:
                        loose || listIsLoose(around: prev, in: blocks, text: text,
                                             unrendered: unrendered))
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
            // The item that ends the list outright is the one nothing continues
            // it from — asking only whether the *depth* matches missed a next
            // item that sits at a different depth but in a different list, so
            // this one never took the list's bottom margin.
            let last = !nextIsItem || !continues(next)
            return .listItem(top: top, lastInList: last)
        }
    }

    /// Whether the list that owns the item at `i` — that list, not any list
    /// nested inside one of its items — is loose.
    ///
    /// CommonMark: a list is loose when its own items are separated by blank
    /// lines, or when one of its items *directly* contains two blocks with a
    /// blank line between them. Both halves of that sentence were wrong here.
    /// "Its own items" was any block at `indent / 2 >= depth`, so a blank line
    /// belonging to an item two levels down loosened the outermost list;
    /// "directly contains" was any blank line in the item's source, so the
    /// blank lines inside a fenced code block did it too. Getting either wrong
    /// is 16pt of margin per item on an ordinary note, which is why this is
    /// worth the walk.
    ///
    /// Linear in the length of that one list, which is what makes it
    /// affordable on the editing path: a keystroke restyles three blocks and
    /// each walks its own list, never the document.
    ///
    /// `unrendered` is not optional decoration. A reference definition inside
    /// an item is *not* a block-level element — cmark consumes it and emits
    /// nothing — so `- b` / blank / `  [ref]: /url` is an item holding **one**
    /// block, and the page draws a tight `<li>b</li>`. Without the array the
    /// blank line above the definition read as evidence of two, the item's
    /// text was wrapped in a `<p>`'s 16pt margin, and the list stood 16pt
    /// taller than a page that had put nothing there.
    static func listIsLoose(around i: Int, in blocks: [Block], text: NSString,
                            unrendered: [NSRange] = []) -> Bool {
        guard blocks.indices.contains(i), case .listItem = blocks[i].kind else { return false }

        // The list's first item. Walking back, an item deeper than ours is
        // nested inside an *earlier* sibling and steps over; a shallower one
        // encloses us and ends the search.
        var lo = i
        var j = i - 1
        back: while j >= 0 {
            switch membership(of: blocks[j], in: blocks[lo], text: text) {
            case .sibling: lo = j
            case .interior: break          // step over it — a bare `break`
                                           // leaves the switch, not the walk
            case .outside: break back      // …which is what the label is for
            }
            j -= 1
        }

        // Forward from there, over every block — blanks included, because a
        // blank run *is* the evidence. `member` is the item of our list we are
        // inside; `nested` is the deepest item open inside it, which is what
        // says whether a block after a blank run is one of our item's own
        // children or one of a nested item's.
        var member = blocks[lo]
        var nested: ListInfo?
        var blankRun = false
        // Whether the last block seen was one of *our* boxes — an item of this
        // list, or a block directly inside one — rather than something a list
        // nested inside it owns. A blank run makes the list loose when the box
        // on **either** side of it is ours, because it is then a gap between
        // two of one item's own children: `1.  foo` / blank / `    - bar` has
        // the item's text above the gap and a nested list below it, and the
        // text is the half that makes the item loose.
        var previousIsOurs = false
        for k in lo..<blocks.count {
            let block = blocks[k]
            if case .blank = block.kind {
                blankRun = k > lo
                continue
            }
            // Source the page has no element for is not one of the item's two
            // blocks, and it does not *use up* the blank run above it either:
            // `- b` / blank / `[ref]: /url` / blank / `  more` really is loose,
            // on the strength of the second gap. Stepping over it with the run
            // still open is what `skips` does everywhere else.
            if isUnrendered(block, text: text, unrendered: unrendered) { continue }
            let place = membership(of: block, in: member, text: text)
            if place == .outside { break }
            // Ours when it is an item of this list, or a block that dedented
            // out of a nested item back to our own level. With no nested item
            // open there is nothing to have dedented out of, and the parser has
            // already put anything it believed to be the item's own content
            // inside the item's block — so a stray block here is not ours.
            let isOurs = place == .sibling
                || (!isListItemBlock(block) && nested.map {
                        firstLineIndent(block, text: text) < $0.contentColumn
                    } == true)
            if blankRun, previousIsOurs || isOurs { return true }
            blankRun = false
            previousIsOurs = isOurs
            if place == .sibling {
                member = block
                nested = nil
                // An item that swallowed a blank line of its own is loose too,
                // and no blank *block* separates the items in that case — the
                // blank is inside the item (see `BlockParser`'s list
                // continuation rule).
                // A blank line the item *swallowed* is evidence of two blocks
                // only when there is a second block for it to separate — and
                // that block may be the next one along, because the parser
                // splits a quote (or, now, a table) out of the item it is
                // written inside. `1. Second:` / blank / `   > Quoted.` is one
                // item whose blank line is its own last line and whose second
                // block is the block after it, and the page wraps that item's
                // text in a `<p>`.
                var followedInside = false
                var ahead = k + 1
                while ahead < blocks.count {
                    if isBlank(blocks[ahead])
                        || isUnrendered(blocks[ahead], text: text, unrendered: unrendered) {
                        ahead += 1; continue
                    }
                    // Anything still inside the **list** counts, an item of it
                    // as much as a block inside this item. CommonMark loosens a
                    // list whose item ends with a blank line unless that item
                    // is the last, and after a reference definition is consumed
                    // an item can end with one without looking like it does:
                    // spec #297 is `- a` / `- b` / blank / `  [ref]: /url` /
                    // `- d`, where stripping the definition leaves item `b`
                    // ending on the blank and `- d` right underneath with no
                    // blank block between them for the walk below to see.
                    followedInside =
                        membership(of: blocks[ahead], in: block, text: text) != .outside
                    break
                }
                if containsBlankLine(block, text: text, unrendered: unrendered,
                                     trailingBlankCounts: followedInside) { return true }
            } else if case .listItem(let info) = block.kind {
                nested = info
            }
        }
        return false
    }

    /// Does this block contain a line that is blank — a newline with nothing
    /// but spaces or tabs before the next one?
    ///
    /// Not counting the blank lines *inside a fenced code block*. A fence keeps
    /// whatever is written in it, blank lines included, and they are not the
    /// item's own: read as if they were, `- a` / `- ``` ` / `  b` / blank /
    /// blank / `  ``` ` / `- c` came out a loose list, so every item of a list
    /// whose only blank lines the reader never sees (they are inside the code
    /// box) gained 16pt of margin.
    /// `unrendered` is what keeps the answer honest at the end of an item.
    /// `- b` / blank / `  [ref]: /url` looks like two blocks with a gap between
    /// them and is one: cmark consumes the definition and emits nothing, so
    /// GitHub draws a **tight** `<li>b</li>`. Counted loose, the item's text was
    /// wrapped in a `<p>`'s 16pt margin against a page that had drawn none.
    ///
    /// `trailingBlankCounts` answers the other half: a blank run that *ends*
    /// the block separates two blocks only if the second one is outside it.
    static func containsBlankLine(_ block: Block, text: NSString,
                                  unrendered: [NSRange] = [],
                                  trailingBlankCounts: Bool = true) -> Bool {
        var contentOffset = 0
        if case .listItem(let info) = block.kind { contentOffset = info.contentOffset }
        let start = block.range.location
        let end = min(start + block.range.length, text.length)
        var lineStart = start
        var isFirstLine = true
        var openFence: (marker: unichar, count: Int)?
        var sawLine = false
        var blankSeen = false
        while lineStart < end {
            var lineEnd = lineStart
            while lineEnd < end, text.character(at: lineEnd) != 0x0A { lineEnd += 1 }
            // On the item's own first line the content starts past the marker,
            // which is where `- ``` ` writes its fence.
            var from = lineStart
            if isFirstLine { from = min(lineStart + contentOffset, lineEnd) }
            while from < lineEnd, isSpace(text.character(at: from)) { from += 1 }
            var to = lineEnd
            while to > from, isSpace(text.character(at: to - 1)) { to -= 1 }
            let run = fenceRun(from: from, to: to, text: text)
            if let open = openFence {
                if let run, run.marker == open.marker, run.count >= open.count { openFence = nil }
            } else if from >= to {
                if sawLine { blankSeen = true }
            } else {
                if let run { openFence = run }
                // A line with something on it. With a blank line above it the
                // item holds two blocks and the list is loose — unless this is
                // source the page has nothing for, which is no block at all.
                if blankSeen, !unrendered.contains(where: {
                    from >= $0.location && to <= $0.location + $0.length
                }) { return true }
            }
            sawLine = true
            isFirstLine = false
            lineStart = lineEnd + 1
        }
        // Ended on a blank run (or on one holding nothing but dropped source).
        // Whether that is a gap between two blocks is a question about what
        // comes *after* the block, which the caller answers.
        return blankSeen && trailingBlankCounts
    }

    /// A fence delimiter at `from`: three or more of one backtick or tilde,
    /// with nothing but more of the same to `to`.
    private static func fenceRun(from: Int, to: Int,
                                 text: NSString) -> (marker: unichar, count: Int)? {
        guard from < to else { return nil }
        let marker = text.character(at: from)
        guard marker == 0x60 || marker == 0x7E else { return nil }
        var i = from, count = 0
        while i < to, text.character(at: i) == marker { count += 1; i += 1 }
        return count >= 3 ? (marker, count) : nil
    }

    /// What starts this item: its bullet character, or the delimiter after an
    /// ordered marker. CommonMark starts a *new* list when either changes.
    static func marker(_ block: Block, text: NSString) -> unichar {
        guard case .listItem(let info) = block.kind, info.markerLength > 0 else { return 0 }
        let last = block.range.location + info.indent + info.markerLength - 1
        guard last >= 0, last < text.length else { return 0 }
        return text.character(at: last)
    }

    // MARK: - The edges of the painted document

    /// Whether this block puts **ink** on the page: any height at all, or any
    /// padding or border of its own.
    ///
    /// Not the same question as `isRendered`, and the difference is the whole
    /// of the document's bottom edge. cmark emits an element for `### ###` and
    /// for `>` on its own — an `<h3>` and a `<blockquote>` with nothing in
    /// them — so both are "rendered", and both draw nothing: no content, and
    /// (below h2) no padding or border for the box to be made of. A box like
    /// that is not a box the page reserves space *before*. Its own margins are
    /// adjoining, they collapse through it, and the collapsed margin ends up
    /// outside the article's height because nothing paints below it.
    ///
    /// h1 and h2 are the exception and the reason this is a predicate rather
    /// than "is it empty": `padding-bottom: .3em` and a border are 8–11pt of
    /// real ink under an empty `#`, which the page does reserve.
    static func paints(_ block: Block, in blocks: [Block], at i: Int,
                       text: NSString, unrendered: [NSRange]) -> Bool {
        guard isRendered(block, in: blocks, at: i, text: text, unrendered: unrendered) else {
            return false
        }
        switch block.kind {
        case .heading(let level, false):
            return level <= 2 || !isEmptyATXHeading(block, text: text)
        case .blockquote:
            return !isEmptyQuote(block, text: text, unrendered: unrendered)
        case .listItem:
            // An `<li>` with nothing in it. The `li + li` margin above it is
            // real (see `gapThrough`), but it is a margin *inside* the `<ul>`
            // with nothing below it to be a margin of, so at the end of the
            // list it collapses out to the `<ul>`'s own — the one the
            // stylesheet zeroes.
            return !isEmptyItem(block, text: text)
        default:
            return true
        }
    }

    /// The next box after `i` that paints anything, or nil when nothing below
    /// `i` does.
    ///
    /// Walked forward **from `i`**, not backward from the end of the document,
    /// and the difference is a runtime rather than an answer. Both find the
    /// same edge; the walk from the end costs the length of the trailing run
    /// of empty boxes for *every* block in the note, and this one costs it only
    /// for the blocks inside that run. On a note ending in 500 empty list
    /// items the first shape took a whole-document styling pass from 90ms to
    /// 600ms — the same quadratic that took this package's test suite from 26
    /// seconds to five minutes once, in a place where it looked like a
    /// constant.
    static func nextPainted(after i: Int, in blocks: [Block], text: NSString,
                            unrendered: [NSRange]) -> Int? {
        var j = max(0, i + 1)
        while j < blocks.count, !paints(blocks[j], in: blocks, at: j, text: text,
                                        unrendered: unrendered) { j += 1 }
        return j < blocks.count ? j : nil
    }

    /// Whether the rendered page gets an **element** for this block.
    ///
    /// A different question from `paints`, and the one
    /// `.markdown-body > *:last-child { margin-bottom: 0 }` actually asks:
    /// `:last-child` counts *elements*, so a note whose last box is a bare
    /// text node has its margin zeroed one box further up than the source
    /// suggests. cmark passes an HTML block through verbatim, and GitHub's
    /// `tagfilter` extension escapes the leading `<` of `<style`, `<script`,
    /// `<title`, `<textarea` and their kin — the browser is handed
    /// `&lt;style …` and makes *text* of it, with no element anywhere. So the
    /// paragraph above such a block is the article's last element, its
    /// margin-bottom is zeroed, and the block sits straight underneath it.
    ///
    /// Asked of the block's **first** tag, because that is what decides
    /// whether an element opens at all — see
    /// `HTMLBlockShape.opensTagFilteredElement`. Every other kind of block
    /// produces an element (a `<p>`, an `<h2>`, a `<pre>`, a `<blockquote>`);
    /// only raw HTML can be handed to the page as bare characters.
    ///
    /// An *inline* element — a `<span>` left as the article's last child — is
    /// still an element, so it still takes the zeroing, and `margin-bottom: 0`
    /// on an inline box does nothing: the paragraph above it keeps its margin.
    /// That is why this is "is there an element" and not "is there a block
    /// box".
    static func producesElement(_ block: Block, text: NSString) -> Bool {
        guard case .htmlBlock = block.kind else { return true }
        guard block.range.length > 0,
              block.range.location + block.range.length <= text.length else { return true }
        return !HTMLBlockShape.opensTagFilteredElement(text.substring(with: block.range))
    }

    /// The next block after `i` the page gets an element for, or nil when
    /// nothing below `i` gives it one — which makes `blocks[i]` the article's
    /// `:last-child`, whatever is written under it.
    ///
    /// Same forward walk as `nextPainted`, for the same reason: from `i`, so
    /// the cost is paid only by the blocks inside the trailing run.
    static func nextElement(after i: Int, in blocks: [Block], text: NSString,
                            unrendered: [NSRange]) -> Int? {
        var j = max(0, i + 1)
        while j < blocks.count,
              !(isRendered(blocks[j], in: blocks, at: j, text: text, unrendered: unrendered)
                && producesElement(blocks[j], text: text)) { j += 1 }
        return j < blocks.count ? j : nil
    }

    /// The nearest box before `i` that paints anything. Same walk, mirrored.
    static func previousPainted(before i: Int, in blocks: [Block], text: NSString,
                                unrendered: [NSRange]) -> Int? {
        var j = min(i, blocks.count) - 1
        while j >= 0, !paints(blocks[j], in: blocks, at: j, text: text,
                              unrendered: unrendered) { j -= 1 }
        return j >= 0 ? j : nil
    }

    /// Whether `blocks[i]` lies outside everything the page paints — above the
    /// first box that draws anything, or below the last.
    ///
    /// `.markdown-body`'s height runs from the top of its first painted box to
    /// the bottom of its last; the first/last-child rules zero the margins at
    /// those two edges, and a margin or a blank line beyond them has nothing
    /// to be the space *between*. So it is not space at all.
    static func isOutsidePaintedContent(_ i: Int, in blocks: [Block], text: NSString,
                                        unrendered: [NSRange]) -> Bool {
        nextPainted(after: i, in: blocks, text: text, unrendered: unrendered) == nil
            || previousPainted(before: i, in: blocks, text: text, unrendered: unrendered) == nil
    }

    // MARK: - Gaps

    /// The collapsed gap that belongs *below* `blocks[i]`, or 0 when nothing
    /// below it is painted (`> *:last-child { margin-bottom: 0 }`).
    static func gapAfter(_ i: Int, in blocks: [Block], text: NSString,
                         metrics: GFMBoxMetrics, unrendered: [NSRange] = []) -> CGFloat {
        guard let next = nextContent(i, in: blocks, text: text, unrendered: unrendered) else { return 0 }
        // "Last box" has to mean the last box that *paints* one. A note ending
        // in an empty `### ###` or an empty `>` had a whole 24pt margin
        // reserved above a box that draws nothing, and every height gate agreed
        // with it — the editor was measuring a box the page never painted.
        guard nextPainted(after: i, in: blocks, text: text, unrendered: unrendered) != nil
        else { return 0 }
        // …and "last box" is settled by `:last-child`, which counts *elements*.
        // With nothing below this block that the page gets an element for,
        // this block is the last child the stylesheet zeroes — and what is
        // written under it is an anonymous box, which has no margins to
        // collapse with anyway. Both halves point the same way: no gap.
        // A note ending `Above.` / blank / `<style …>` kept 16pt the page had
        // already thrown away (spec #142).
        guard nextElement(after: i, in: blocks, text: text, unrendered: unrendered) != nil
        else { return 0 }
        return gapThrough(i, and: next, in: blocks, text: text, metrics: metrics,
                          unrendered: unrendered)
    }

    /// The gap between two boxes, *through* whatever the walk stepped over.
    ///
    /// `previousContent` and `nextContent` step over source the rendered
    /// document shows nothing for, and for a link reference definition that is
    /// exactly right: cmark emits no element, so the margins either side of it
    /// are adjoining and collapse into one. A concealed **list item** is not
    /// the same thing. cmark still emits an `<li>` for it — empty, of no
    /// height, drawing nothing — and `li + li` still gives the item after it
    /// its margin. So the space across `- <div>` / `- foo` is the 16 above the
    /// list *plus* the 4 between its items; collapsed to one gap it was 4pt
    /// short, once for every such item in the note.
    static func gapThrough(_ i: Int, and j: Int, in blocks: [Block], text: NSString,
                           metrics: GFMBoxMetrics, unrendered: [NSRange] = []) -> CGFloat {
        var total: CGFloat = 0
        var from = i
        guard j > i else { return 0 }
        for k in (i + 1)..<j where isListItemBlock(blocks[k]) {
            total += gapBetween(from, and: k, in: blocks, text: text, metrics: metrics,
                                unrendered: unrendered)
            from = k
        }
        return total + gapBetween(from, and: j, in: blocks, text: text, metrics: metrics,
                                  unrendered: unrendered)
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
                          lines: LineIndex, metrics: GFMBoxMetrics,
                          unrendered: [NSRange] = [])
    -> (tail: CGFloat, blanks: CGFloat) {
        guard let next = nextContent(i, in: blocks, text: text, unrendered: unrendered),
              box(at: next, in: blocks, text: text) != nil else { return (0, 0) }
        // Below the last box that paints anything there is no gap to divide:
        // whatever follows draws nothing, so the space above it is not space
        // between two boxes. (Above the *first* one the same is true, and the
        // `prev == nil` path below already says so.)
        if nextPainted(after: i, in: blocks, text: text, unrendered: unrendered) == nil {
            return (0, 0)
        }
        // The same for the blank lines inside a margin `:last-child` has
        // zeroed: with no element below, the block above is the last child and
        // has no margin-bottom left for this run to be holding. `gapAfter`,
        // `gapShares` and `blankRunHeight` have to answer this identically —
        // one of the three left behind puts the gap back on a line nobody
        // measured, and nothing says so.
        if nextElement(after: i, in: blocks, text: text, unrendered: unrendered) == nil {
            return (0, 0)
        }
        let prev = previousContent(i, in: blocks, text: text, unrendered: unrendered)
            .flatMap { box(at: $0, in: blocks, text: text) != nil ? $0 : nil }
        let start = prev.map { $0 + 1 } ?? 0
        let gap: CGFloat
        if let prev {
            gap = gapThrough(prev, and: next, in: blocks, text: text, metrics: metrics,
                             unrendered: unrendered)
        } else if let opening = (start..<next).last(where: { isListItemBlock(blocks[$0]) }) {
            // Nothing above. The `:first-child` rules zero the margin at the
            // top of the document, so a run of blank lines there holds nothing
            // — but a concealed list item in that run is not nothing. It is an
            // empty `<li>`, and the `li + li` margin the item below it takes is
            // real; with no block above to park it on, it goes here. A note
            // opening with `- <div>` / `- foo` was 4pt short of its Preview and
            // no measurement upstream could see why: the region reported zero.
            gap = gapThrough(opening, and: next, in: blocks, text: text, metrics: metrics,
                             unrendered: unrendered)
        } else {
            return (0, 0)
        }
        // Everything between the two boxes shares the one gap — blank lines and
        // any source the rendered document drops. Counted as a region rather
        // than per block, or a reference definition with a blank line on each
        // side would be handed the gap twice over.
        var regionLines = 0
        for j in start..<next { regionLines += max(1, blocks[j].lineCount) }
        let tailLines = prev.map { collapsedTail(blocks[$0], text: text, lines: lines) } ?? 0
        let each = gap / CGFloat(max(1, tailLines + regionLines))
        return (each * CGFloat(tailLines), each * CGFloat(max(1, blocks[i].lineCount)))
    }

    /// Total height a blank run — or a run of dropped source — must occupy:
    /// its share of the gap between the boxes it separates. Nothing at the
    /// document's edges, where the first/last-child rules zero the margin.
    static func blankRunHeight(_ i: Int, in blocks: [Block], text: NSString,
                               lines: LineIndex, metrics: GFMBoxMetrics,
                               unrendered: [NSRange] = []) -> CGFloat {
        gapShares(blankRunAt: i, in: blocks, text: text, lines: lines,
                  metrics: metrics, unrendered: unrendered).blanks
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

    /// Half of a line's leading — the space CSS puts *above* the glyphs, and
    /// which TextKit would otherwise put there in full.
    ///
    /// The content height is the font's ascent and descent each **rounded to a
    /// whole point**, not their exact sum. That is not a tidying-up: it is what
    /// both engines measured. TextKit's unpinned line height is exactly
    /// `round(ascender) + round(-descender)` — 18pt for the 16pt system font,
    /// whose exact extent is 18.85 — and WebKit's content box came out at the
    /// same 18. Using the exact sum puts the correction 0.4pt out at body size.
    static func halfLeading(_ box: GFMBoxMetrics.Box, theme: EditorTheme) -> CGFloat {
        let font = font(for: box, theme: theme)
        let content = font.ascender.rounded() + (-font.descender).rounded()
        return max(0, (lineHeight(box, theme.metrics) - content) / 2)
    }

    /// The font a box's own text is set in.
    static func font(for box: GFMBoxMetrics.Box, theme: EditorTheme) -> PlatformFont {
        switch box {
        case .heading(let level): theme.headingFont(level: level)
        case .codeBlock: theme.mono
        default: theme.body
        }
    }

    /// The height of a line box that has to seat an inline **replaced
    /// element** — an `<img>`, a `![alt](url)` — `height` points tall.
    ///
    /// CSS aligns a replaced element on the baseline, so the box has to reach
    /// the whole of the element's height *above* the baseline while the strut
    /// still hangs its descender and half-leading below it. That is why the
    /// answer is neither `max(lineHeight, height)` nor `height`: a 20pt picture
    /// on a 24pt body line makes the box 26. The two engines disagreed by
    /// exactly that 2pt on every example with a picture inside a sentence,
    /// which reads as a rounding error and is a missing box.
    ///
    /// An element shorter than the strut's own ascent changes nothing — the
    /// `max` is the whole of the rule, and it is why a small icon in a
    /// paragraph must *not* move the line.
    static func lineHeight(seating height: CGFloat, box: GFMBoxMetrics.Box,
                           theme: EditorTheme) -> CGFloat {
        let font = font(for: box, theme: theme)
        let lead = halfLeading(box, theme: theme)
        return max(height, font.ascender.rounded() + lead) + (-font.descender).rounded() + lead
    }

    /// Line height for a box — `line-height` in the stylesheet.
    static func lineHeight(_ box: GFMBoxMetrics.Box, _ m: GFMBoxMetrics) -> CGFloat {
        switch box {
        case .heading(let level): m.headingLineHeight(level)
        case .codeBlock: m.codeLineHeight
        case .emptyQuote: collapsedLine
        default: m.bodyLineHeight
        }
    }

    /// The collapsed margin between two content blocks.
    ///
    /// One place, because two callers need the same answer: `gapAfter` puts it
    /// on the block above, and `gapShares` divides it among the blank lines
    /// between them. They used to compute it separately, so a rule added to one
    /// was silently absent from the other — and which one applied depended on
    /// whether the writer had left a blank line.
    /// The indent, in columns, of a block's first line — tabs to the next
    /// multiple of four, as CommonMark counts them.
    static func firstLineIndent(_ block: Block, text: NSString) -> Int {
        var i = block.range.location
        let end = block.range.location + block.range.length
        var column = 0
        while i < end {
            let c = text.character(at: i)
            if c == 0x20 { column += 1 } else if c == 0x09 { column += 4 - (column % 4) } else { break }
            i += 1
        }
        return column
    }

    static func isListItemBlock(_ block: Block) -> Bool {
        if case .listItem = block.kind { return true }
        return false
    }

    /// Does this item's last content line hold a thematic break? `- * * *` is
    /// an `<hr>` inside the `<li>`, and the rule's own margins are what the
    /// gap below the list is made of.
    static func closesWithThematicBreak(_ block: Block, text: NSString) -> Bool {
        guard case .listItem(let info) = block.kind else { return false }
        let start = block.range.location
        var end = block.range.location + block.range.length
        // Back over the block's trailing newline and any blank tail.
        while end > start, isSpace(text.character(at: end - 1)) { end -= 1 }
        var lineStart = end
        while lineStart > start, text.character(at: lineStart - 1) != 0x0A { lineStart -= 1 }
        var i = lineStart
        // On the item's own first line the content sits past the marker.
        if lineStart == start { i = min(start + info.contentOffset, end) }
        while i < end, text.character(at: i) == 0x20 { i += 1 }
        guard i < end else { return false }
        let marker = text.character(at: i)
        guard marker == 0x2D || marker == 0x2A || marker == 0x5F else { return false }
        var marks = 0
        while i < end {
            let c = text.character(at: i)
            if c == marker { marks += 1 } else if c != 0x20 && c != 0x09 { return false }
            i += 1
        }
        return marks >= 3
    }

    /// Whitespace, including the newline a block range ends on.
    private static func isSpace(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
    }

    /// The level of a heading written as a list item's first content —
    /// `- # Foo`, or `- Bar` over `  ---`. The heading is a block *inside* the
    /// `<li>`, and its margins behave like any other block's, which is what
    /// makes them collapse out.
    ///
    /// A heading has two spellings and this only knew one. `StyleApplier`
    /// already gives `- Bar` over `  ---` the h2 line height, so the item
    /// *looked* like a heading and still exported a plain item's margin — the
    /// disagreement is invisible until two such items sit next to each other
    /// and the gap between them is 8pt short of the page.
    static func openingHeadingLevel(_ block: Block, text: NSString) -> Int? {
        guard case .listItem(let info) = block.kind else { return nil }
        let content = block.range
        let end = content.location + content.length
        var i = min(content.location + info.contentOffset, end)
        let firstContent = i
        while i < end, text.character(at: i) == 0x20 { i += 1 }
        var level = 0
        while i < end, text.character(at: i) == 0x23, level < 7 { level += 1; i += 1 }
        if level >= 1, level <= 6,
           i == end || text.character(at: i) == 0x20 || text.character(at: i) == 0x0A {
            return level
        }
        return setextLevel(afterFirstLineAt: firstContent, end: end, text: text)
    }

    /// The level of a setext underline on the item's *second* line, given the
    /// first line's content starts at `start`. Kept in step with
    /// `StyleApplier.applyNestedSetext`, which is what actually draws the
    /// heading: if one of them accepts a line the other does not, the line
    /// height and the margin describe two different documents.
    private static func setextLevel(afterFirstLineAt start: Int, end: Int,
                                    text: NSString) -> Int? {
        var i = start
        var sawText = false
        while i < end, text.character(at: i) != 0x0A {
            if !isSpace(text.character(at: i)) { sawText = true }
            i += 1
        }
        // `-` on its own line is an empty item, and the `---` below it is then a
        // thematic break rather than an underline of anything.
        guard sawText, i < end else { return nil }
        i += 1
        while i < end, text.character(at: i) == 0x20 { i += 1 }
        guard i < end else { return nil }
        let marker = text.character(at: i)
        guard marker == 0x2D || marker == 0x3D else { return nil }        // `-` or `=`
        var marks = 0
        while i < end, text.character(at: i) != 0x0A {
            let c = text.character(at: i)
            if c == marker { marks += 1 } else if c != 0x20 && c != 0x09 && c != 0x0D { return nil }
            i += 1
        }
        guard marks >= 1 else { return nil }
        return marker == 0x3D ? 1 : 2
    }

    static func gapBetween(_ i: Int, and j: Int, in blocks: [Block], text: NSString,
                           metrics: GFMBoxMetrics, unrendered: [NSRange] = []) -> CGFloat {
        guard let mine = box(at: i, in: blocks, text: text, unrendered: unrendered),
              let theirs = box(at: j, in: blocks, text: text, unrendered: unrendered) else { return 0 }
        // An empty h3–h6 has no height, no padding and no border, so its own
        // top and bottom margins collapse into one, together with the margins
        // of the blocks on either side. (h1 and h2 have a rule, and a border
        // stops the collapse.) Mid-note the margin above it is the largest of
        // those and it belongs to the block before, so the gap below is
        // whatever the next block asks for.
        //
        // Opening the note it is not, and the rule is **not symmetric at the
        // two edges**. `.markdown-body > *:first-child { margin-top: 0 }` takes
        // the heading's own top margin away, but the article's `padding-top`
        // stops the collapse from escaping upward — so what is left, the
        // heading's 16pt margin-bottom, is real page that the reader sees.
        // Returning the next block's `margin-top` gave 0 and the note opened
        // 16pt high. At the bottom edge the mirror case is right for the
        // opposite reason: there the collapsed margin falls past the last ink
        // and `paintedContentBottom` correctly stops short of it.
        if case .heading(let level) = mine, level > 2, isEmptyATXHeading(blocks[i], text: text) {
            let opensNote = !blocks[..<i].enumerated().contains { k, earlier in
                isRendered(earlier, in: blocks, at: k, text: text, unrendered: unrendered)
            }
            return opensNote
                ? max(metrics.marginTop(theirs), metrics.marginBottom(mine))
                : metrics.marginTop(theirs)
        }
        // A block *inside* the item — indented to its content column — is not
        // the next thing after the list: the item has not ended, so it carries
        // no bottom margin here. GitHub gives `blockquote`, `pre` and `table`
        // `margin-top: 0`, and a **tight** item's own text is not a `<p>`, so
        // nothing separates them at all. A *loose* item wraps its text in a
        // `<p>`, and that paragraph's margin is the gap.
        // Only when it *immediately* follows: with a blank line between them the
        // item may well have ended — `-` / blank / `  foo` is an empty item and
        // a separate paragraph, because an item may begin with at most one
        // blank line — and the blank run is already holding the gap either way.
        if j == i + 1,
           case .listItem(let info) = blocks[i].kind,
           !isListItemBlock(blocks[j]),
           firstLineIndent(blocks[j], text: text) >= info.contentColumn {
            return metrics.marginTop(theirs)
        }
        // An item of a **loose** list has 16pt below it however the list ends.
        // Between two of its own items that is the next item's `li > p`
        // margin-top, which `marginTop` already knows. Where the list *ends* it
        // is the last `<p>`'s own margin-bottom, and `ul ul { margin-bottom: 0 }`
        // does not stop that one: with no padding or border on the `<li>`, the
        // nested `<ul>` or the item holding them, it collapses straight out and
        // lands wherever the nesting runs out. Only the outermost list was ever
        // given it, so a loose sub-list closed 12pt tight against the item
        // below — the mirror of the margin `.opensNestedList(spaced:)` puts
        // above it.
        var floor: CGFloat = 0
        if case .listItem = mine, listIsLoose(around: i, in: blocks, text: text,
                                              unrendered: unrendered) {
            floor = metrics.blockGap
        }
        // An item *ending* in a thematic break exports the rule's bottom margin
        // — the mirror of the heading margin below. An `<hr>` has no padding or
        // border for a margin to stop at either, so 24pt collapses out through
        // the `<li>` and the `<ul>`, where it is larger than the list's own 16.
        if case .listItem = mine, closesWithThematicBreak(blocks[i], text: text) {
            return max(floor, metrics.gap(after: mine, before: theirs),
                       metrics.gap(after: .thematicBreak, before: theirs))
        }
        // An item opening with a heading takes that heading's top margin.
        // Neither the `<li>` nor the `<ul>` has padding or a border, so the
        // heading's margin collapses straight out through both — landing above
        // the list when the item opens one, and between the items otherwise.
        if case .listItem = theirs,
           let level = openingHeadingLevel(blocks[j], text: text) {
            return max(floor, metrics.gap(after: mine, before: theirs),
                       metrics.gap(after: mine, before: .heading(level: level)))
        }
        return max(floor, metrics.gap(after: mine, before: theirs))
    }

    /// An ATX heading whose `#`s are followed by nothing — `##`, `# `, `### ###`.
    static func isEmptyATXHeading(_ block: Block, text: NSString) -> Bool {
        guard case .heading(_, false) = block.kind else { return false }
        let start = block.range.location
        let end = min(start + block.range.length, text.length)
        var i = start
        while i < end {
            let c = text.character(at: i)
            if c != 0x23 && c != 0x20 && c != 0x09 && c != 0x0A && c != 0x0D { return false }
            i += 1
        }
        return true
    }

    /// A blockquote with nothing in it — `>` on its own, however many lines of
    /// it. Only the markers, spaces and line breaks.
    static func isEmptyQuote(_ block: Block, text: NSString,
                             unrendered: [NSRange] = []) -> Bool {
        guard case .blockquote(nil) = block.kind else { return false }
        let start = block.range.location
        let end = min(start + block.range.length, text.length)
        var runStart: Int?
        var i = start
        // Every run of real characters between the markers has to be source the
        // reader never sees. A quote holding nothing but a reference definition
        // renders as an empty `<blockquote>`, so it is as much "not a box" as
        // one holding nothing at all.
        while i <= end {
            let c = i < end ? text.character(at: i) : 0x0A
            let isMarkerOrSpace = c == 0x3E || c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
            if isMarkerOrSpace {
                if let from = runStart {
                    let run = NSRange(location: from, length: i - from)
                    guard unrendered.contains(where: {
                        NSIntersectionRange($0, run).length == run.length
                    }) else { return false }
                    runStart = nil
                }
            } else if runStart == nil {
                runStart = i
            }
            i += 1
        }
        return true
    }

    /// The style every line of the block gets: line height and indents, and no
    /// spacing at all — the gap belongs to the last line alone.
    static func baseStyle(for block: Block, box: GFMBoxMetrics.Box,
                          text: NSString, theme: EditorTheme) -> NSMutableParagraphStyle {
        let m = theme.metrics
        let style = NSMutableParagraphStyle()
        let height = lineHeight(box, m)
        // A line box is taller than the glyphs in it, and the two engines used
        // to disagree about where in that box the glyphs sit: CSS splits the
        // leftover space evenly above and below, TextKit puts all of it above a
        // line pinned with `min`/`maximumLineHeight`. Every line of body text
        // in Edit therefore sat a half-leading — 3pt at 16pt — below its
        // Preview twin, while the boxes themselves agreed to a hundredth of a
        // point. That is the layout shift you could see and no box measurement
        // could find.
        //
        // The box keeps its full height; the glyphs inside it are lifted by a
        // half-leading with `.baselineOffset`, applied alongside this style in
        // `StyleApplier.applyBase`. Nothing here moves, which is the point:
        // line boxes, line pitch and layout-fragment frames are all bit-for-bit
        // what they were, so every band, bar and rule drawn from them is too.
        //
        // Two other routes were measured and rejected (scratchpad/LeadingLab):
        //
        // - Pinning to `height - halfLeading` and putting the rest in
        //   `lineSpacing` puts the glyphs in the right place, but a line box is
        //   then a half-leading short and TextKit carries the remainder onto
        //   the *next* fragment's frame — so code backgrounds and quote bars
        //   gain a gap between every line and stop a half-leading short at the
        //   bottom of the block.
        // - A *positive* `.baselineOffset` collapses the line pitch from
        //   `height` to `height - offset`, which is why this looked like it
        //   made things worse the first time it was tried. The offset is
        //   negative: y grows downward here, so lifting the glyphs lowers it.
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
        case .paragraph, .heading, .table, .thematicBreak, .frontMatter, .htmlBlock, .emptyQuote:
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
