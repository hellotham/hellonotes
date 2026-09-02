//
//  StyleApplier.swift
//  MarkdownEditor
//
//  Turns MarkdownCore's semantic style runs into attributed-string
//  attributes. Pure and nonisolated: the open path runs it off the main
//  actor over a scratch NSMutableAttributedString; the editing path runs it
//  on the main actor over the live NSTextStorage for damaged blocks only.
//

import Foundation
import MarkdownCore
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Custom attribute carrying a wiki link's target so the view can route
/// clicks without re-parsing.
nonisolated public let wikiTargetAttribute = NSAttributedString.Key("hn.wikiTarget")
/// Marks concealable marker ranges (for potential future use by hit-testing).
nonisolated let markerAttribute = NSAttributedString.Key("hn.marker")

nonisolated enum StyleApplier {

    /// Wiki-link existence resolution, injected by the app.
    typealias WikiResolver = @Sendable (String) -> Bool

    /// Restyle `blocks` of `parse` in `target`.
    ///
    /// Reveal works at two granularities, deliberately:
    ///
    ///  * `revealedLines` drives **inline syntax** — a marker is shown raw only
    ///    on the line the caret is on, the way Bear and Obsidian behave. Block
    ///    granularity was wrong here: a blockquote is one block, so a caret
    ///    anywhere in a five-line quote revealed `>` on all five lines and
    ///    dropped every gutter bar, which reads as the formatting breaking.
    ///  * whole-block presentation — folds, and the embeds that replace a block
    ///    with a rendered image (tables, math, transclusions) — stays block-
    ///    scoped and is handled by `EditorDocument`, because it has no per-line
    ///    meaning: you reveal the source of a rendered table, not one row of it.
    static func apply(
        blockIndices: some Sequence<Int>,
        parse: ParseResult,
        text: NSString,
        to target: NSMutableAttributedString,
        theme: EditorTheme,
        revealedLines: Set<Int>,
        resolveWiki: WikiResolver?,
        gfmRuns: [StyleRun] = [],
        unrendered: [NSRange] = []
    ) {
        target.beginEditing()
        for index in blockIndices where index >= 0 && index < parse.blocks.count {
            let block = parse.blocks[index]
            guard block.range.length > 0,
                  block.range.location + block.range.length <= target.length else { continue }
            applyBase(for: block, at: index, in: parse.blocks, text: text,
                      lines: parse.lines, to: target, theme: theme,
                      revealedLines: revealedLines, unrendered: unrendered)
            let runs = StyleSpec.runs(for: block, text: text, lines: parse.lines)
            /// Is this run on a line the caret is on?
            func revealsRun(_ run: StyleRun) -> Bool {
                revealedLines.contains(parse.lines.lineNumber(at: run.range.location))
            }
            /// Is this run over source the reader never sees?
            ///
            /// `applyBase` has already concealed it — `theme.concealed`, a
            /// clear colour, a hairline of a line box — and then this loop put
            /// the styling straight back on top: an unrendered `<div class="x">`
            /// kept the raw-HTML run's monospace and its grey and was painted at
            /// full size into a line box 0.01pt tall, i.e. overprinted onto the
            /// paragraph above it. Every height was right throughout, which is
            /// exactly why `--spec` could not see it and a `--png` could.
            ///
            /// A reference definition never showed the fault because
            /// `StyleSpec` emits no run for one. Anything that *does* carry a
            /// run — raw HTML, a table's pipes — did.
            func isConcealed(_ run: StyleRun) -> Bool {
                guard !unrendered.isEmpty, !revealsRun(run) else { return false }
                return unrendered.contains {
                    NSIntersectionRange($0, run.range).length == run.range.length
                }
            }
            for run in runs where !isConcealed(run) {
                apply(run, to: target, theme: theme, revealed: revealsRun(run), resolveWiki: resolveWiki)
            }
            // Overlay spec-accurate GFM inline styling from cmark-gfm — the same
            // engine the Preview renders with — so emphasis/links/code match the
            // spec exactly across paragraphs, headings, lists AND blockquotes.
            // `gfmRuns` are whole-document runs (cmark had full block context, so
            // a `    - x` list item is read as a list item, not indented code —
            // the isolation bug a per-block parse would hit). Additive: cmark
            // only emits runs for GFM inline constructs, so the Obsidian
            // extensions and structural styling above are untouched. Skip code /
            // math blocks (their content is literal, not inline Markdown, and
            // fenced code carries syntax-highlight colours we must not disturb).
            if overlayGFM(block.kind) {
                let blockEnd = block.range.location + block.range.length
                for run in gfmRuns
                where run.range.location >= block.range.location
                   && run.range.location + run.range.length <= blockEnd
                   && !isConcealed(run) {
                    apply(run, to: target, theme: theme, revealed: revealsRun(run), resolveWiki: resolveWiki)
                }
            }
            // Plain-blockquote gutter bars are per-line (nesting depth), and so
            // is the decision to draw them: a line showing its raw `>` sits at
            // its natural indent with no bar, while every other line of the same
            // quote keeps its bar.
            // Whether this quote is the first thing the reader sees, which
            // decides whether a margin escaping out of it has anything above to
            // collapse into. Computed only for a quote and abandoned at the
            // first rendered block it meets, so it is a comparison rather than
            // a scan of the note — asking it of every block was how the styler
            // went quadratic once already.
            var quoteOpensDocument = false
            if case .blockquote(nil) = block.kind {
                quoteOpensDocument = !parse.blocks[..<index].enumerated()
                    .contains { i, earlier in
                        BlockBoxes.isRendered(earlier, in: parse.blocks, at: i,
                                              text: text, unrendered: unrendered)
                    }
            }
            // Whether this quote sits inside a list item, which decides what
            // a list *inside* the quote does to the margin below it — see the
            // blank-run arithmetic in `applyQuoteBars`. Short-circuited on the
            // quote's own indent, so a quote at the document level costs one
            // comparison and the walk is bounded by the item that holds it.
            var quoteInsideListItem = false
            var quoteListInset: CGFloat = 0
            if case .blockquote(nil) = block.kind,
               BlockBoxes.firstLineIndent(block, text: text) > 0 {
                let mine = BlockBoxes.firstLineIndent(block, text: text)
                var j = index - 1
                while j >= 0 {
                    let earlier = parse.blocks[j]
                    if case .listItem(let holder) = earlier.kind {
                        quoteInsideListItem =
                            BlockBoxes.membership(of: block, in: earlier, text: text) == .interior
                        // …and how much `ul`/`ol` padding it inherits. CSS gives
                        // every list level 2em of `padding-left` whatever the
                        // writer indented by, and the quote pass *overwrites*
                        // the base style's indent rather than adding to it — so
                        // without this a quote inside an item drew its bar at
                        // the page margin and handed its text 32pt more width
                        // per level than the page does. Only a wrap can show
                        // that, and nothing in 672 one-construct examples wraps.
                        if quoteInsideListItem {
                            quoteListInset = CGFloat(BlockBoxes.listDepth(holder) + 1)
                                * theme.metrics.listIndent
                        }
                        break
                    }
                    if case .blank = earlier.kind { j -= 1; continue }
                    guard BlockBoxes.firstLineIndent(earlier, text: text) >= mine else { break }
                    j -= 1
                }
            }
            applyQuoteBars(for: block, lines: parse.lines, text: text,
                           to: target, theme: theme, revealedLines: revealedLines,
                           unrendered: unrendered, opensDocument: quoteOpensDocument,
                           insideListItem: quoteInsideListItem, listInset: quoteListInset)
            carryListBullets(for: block, lines: parse.lines, text: text, to: target)
            concealNestedFences(for: block, lines: parse.lines, text: text, to: target,
                                theme: theme, revealedLines: revealedLines)
            concealNestedCodeIndent(for: block, lines: parse.lines, text: text, to: target,
                                    theme: theme, revealedLines: revealedLines)
            // Last, because it reads what every pass above wrote: a line is
            // only collapsible once the inline runs have concealed it.
            collapseConcealedLines(block: block, lines: parse.lines, text: text,
                                   to: target, revealedLines: revealedLines)
            // And after that, for the same reason: whether a line draws
            // anything is the question this one turns on.
            markJoinedLines(block: block, lines: parse.lines, text: text,
                            to: target, revealedLines: revealedLines)
        }
        target.endEditing()
    }

    /// Whether to overlay cmark GFM inline styling on this block. Code and math
    /// blocks are literal content (no inline Markdown); fenced code also carries
    /// syntax-highlight colours we must not disturb. Everything with inline
    /// Markdown — paragraphs, headings, list items, blockquotes, tables — gets
    /// the cmark overlay, because the runs come from a whole-document parse that
    /// has full block context (no per-block isolation misreads).
    static let gfmOverlayMaxLength = 200_000

    private static func overlayGFM(_ kind: BlockKind) -> Bool {
        switch kind {
        case .paragraph, .heading, .listItem, .blockquote: true
        // Tables render as native image fragments; changing the underlying
        // text's fonts would perturb the fragment's line metrics. Code / math /
        // front-matter are literal content, not inline Markdown.
        case .table, .fencedCode, .indentedCode, .mathBlock, .frontMatter, .thematicBreak,
             .blank, .htmlBlock: false
        }
    }

    /// Reset a block to its base look (clears stale attributes from previous
    /// structure — a heading demoted to a paragraph must lose its font), then
    /// lay out its CSS box.
    ///
    /// "Lay out its box" is the part that is new, and the part the Preview was
    /// always doing on its own: a line height, indents, and the collapsed
    /// margin below. See `BlockBoxes` for why the margin lands on the last
    /// line and why a blank line is a margin rather than a line.
    private static func applyBase(
        for block: Block, at index: Int, in blocks: [Block],
        text: NSString, lines: LineIndex,
        to target: NSMutableAttributedString, theme: EditorTheme,
        revealedLines: Set<Int>, unrendered: [NSRange]
    ) {
        let m = theme.metrics
        var base: [NSAttributedString.Key: Any] = [
            .font: theme.body,
            .foregroundColor: theme.text,
            // The base size, carried on the text itself, so the fragment
            // drawing chrome (heading rules, quote bars, code bands) can derive
            // the same metrics without a theme it has no way to reach.
            gfmBaseAttribute: m.base,
        ]
        if case .fencedCode = block.kind {
            base[.font] = theme.mono
        }
        target.setAttributes(base, range: block.range)

        // NOTE: the glyphs sit ~2.5pt lower inside the line box than the
        // Preview's do — CSS splits a line's leading evenly above and below the
        // text, TextKit puts it all above. The boxes agree to a hundredth of a
        // point; what differs is where the text sits inside them, which is why
        // every box-position measurement said the two were identical.
        //
        // `.baselineOffset` is *not* the fix: it feeds back into TextKit's line
        // metrics rather than moving glyphs inside a pinned box, and applying
        // half the leading that way moved the boxes 12.89pt and left the
        // baseline where it was. Measured, both before and after. Needs a
        // different mechanism.

        let lastLineNumber = block.firstLine + block.lineCount - 1
        // Which line carries the block's trailing gap. Normally the last, but a
        // block whose parser range runs past its rendered content — an indented
        // code block keeps the blank lines that follow it — hands the gap to
        // the last line that actually renders.
        var gapLine = lastLineNumber

        // Source the rendered document has no equivalent for — a link
        // reference definition — is not a box either. It is treated exactly as
        // a blank run: it holds part of the gap between the boxes on either
        // side of it, and shows nothing.
        let isUnrendered = BlockBoxes.isUnrendered(block, text: text, unrendered: unrendered)
        if isUnrendered {
            target.addAttributes([.font: theme.concealed,
                                  .foregroundColor: PlatformColor.clear,
                                  markerAttribute: true], range: block.range)
        }

        // A blank run is not a box: it is the gap between the two boxes it
        // separates, and it gets exactly that much height, shared out over
        // however many blank lines were typed.
        guard !isUnrendered,
              let box = BlockBoxes.box(at: index, in: blocks, text: text,
                                       unrendered: unrendered) else {
            let total = BlockBoxes.blankRunHeight(index, in: blocks, text: text,
                                                  lines: lines, metrics: m,
                                                  unrendered: unrendered)
            // A blank line *outside* everything the page paints — above the
            // first box that draws anything, below the last — is not a margin
            // either. It has nothing to be the space between, so it gets the
            // same nothing an unrendered block gets, and the hairline the
            // floor keeps is only ever the space between two boxes.
            //
            // …and neither is a run inside a margin that has already been
            // zeroed, which is a *second* way for the run to be holding
            // nothing and is not the same question. `Above.` / blank /
            // `<style …>` ends the article in a bare text node, so
            // `:last-child` lands on the paragraph and the gap between the two
            // is 0 — while the run sits squarely between two things the page
            // paints, which is why `isOutsidePaintedContent` says no (spec
            // #142). The two are kept as a union rather than folded into
            // `total <= 0`, which looks like the same statement and is not:
            // outside the painted content the gap is often *not* zero, because
            // an unpainted first box still hands the run below it the margin
            // of whatever comes next — `### ###` / blank / `## Heading` is
            // 24pt held by one blank line. Fold the two together and the
            // hairline floor puts back space the page does not have, a tenth
            // of a point at a time down however many blank lines were typed:
            // measured at 61 of them, +6.52pt against a page that had not
            // moved.
            //
            // The hairline was never the caret's answer anyway: 0.5pt of line
            // is 0.5pt of insertion point, which is invisible at any zoom. The
            // caret is answered below, by reopening the line it is actually on
            // — the same thing a reference definition does.
            let outside = BlockBoxes.isOutsidePaintedContent(index, in: blocks, text: text,
                                                             unrendered: unrendered)
            let holdsNoGap = outside || total <= 0
            let floor = (isUnrendered || holdsNoGap)
                ? BlockBoxes.collapsedLine : BlockBoxes.minimumBlankLine
            let each = max(floor, total / CGFloat(max(1, block.lineCount)))
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = each
            style.maximumLineHeight = each
            target.addAttribute(.paragraphStyle, value: style, range: block.range)
            // …and the line the caret is on comes back to full height, so a
            // blank run is still something you can type in.
            //
            // **Every blank run, not only collapsed ones.** The condition used
            // to be `holdsNoGap`, on the reasoning that a run holding a real
            // margin already has height to show a caret in. It has height, but
            // it is *shared*: a run's margin is divided by its line count, so
            // pressing Return four times between two paragraphs gave four lines
            // a quarter of one gap each and the caret did not appear to move.
            // Typing Return and watching nothing happen is the clearest
            // possible way for an editor to feel broken.
            //
            // Parity is unaffected by construction: `revealedLines` is empty
            // when there is no caret, which is every document the render-parity
            // harness lays out.
            if !revealedLines.isEmpty {
                let last = block.firstLine + block.lineCount - 1
                for lineNumber in block.firstLine...max(block.firstLine, last)
                where revealedLines.contains(lineNumber) {
                    let range = lines.lineRange(lineNumber)
                    guard range.length > 0, range.location + range.length <= target.length else { continue }
                    let open = NSMutableParagraphStyle()
                    open.minimumLineHeight = m.bodyLineHeight
                    open.maximumLineHeight = m.bodyLineHeight
                    target.addAttribute(.paragraphStyle, value: open, range: range)
                }
            }
            return
        }

        let style = BlockBoxes.baseStyle(for: block, box: box, text: text, theme: theme)
        target.addAttribute(.paragraphStyle, value: style, range: block.range)
        // Where the glyphs sit *inside* that box. CSS splits a line's leftover
        // space evenly above and below the text; TextKit puts all of it above.
        // Lifting by a half-leading is what makes the two agree, and it is the
        // only part of the box model that is a property of the glyphs rather
        // than of the box — hence an attribute and not a paragraph style. See
        // `BlockBoxes.baseStyle` for why the other two routes were rejected.
        let lift = BlockBoxes.halfLeading(box, theme: theme)
        if lift > 0 {
            target.addAttribute(.baselineOffset, value: -lift, range: block.range)
        }

        // The gap below this block — unless the next block is a blank run,
        // which is already holding it.
        let nextIsBlank = blocks.indices.contains(index + 1)
            && !BlockBoxes.isRendered(blocks[index + 1], in: blocks, at: index + 1,
                                      text: text, unrendered: unrendered)
        var extraTrailing: CGFloat = 0
        var trailing = nextIsBlank ? 0 : BlockBoxes.gapAfter(index, in: blocks, text: text,
                                                            metrics: m, unrendered: unrendered)
        // When a blank run follows, it is holding the gap — except for the
        // share that belongs to this block's own collapsed tail lines.
        let collapsedTotal = nextIsBlank
            ? BlockBoxes.gapShares(blankRunAt: index + 1, in: blocks, text: text,
                                   lines: lines, metrics: m, unrendered: unrendered).tail
            : trailing

        switch block.kind {
        case .heading(let level, let setext):
            if setext, lastLineNumber > block.firstLine {
                // A setext heading is two lines of source and one line of
                // heading: the `===` underline conceals, and has to collapse
                // with it or the block stands a whole heading-line taller than
                // the Preview's. The margin below the heading is what the
                // collapsed line is given to hold.
                collapseLines(from: lastLineNumber, through: lastLineNumber,
                              total: collapsedTotal, lines: lines, to: target)
                gapLine = lastLineNumber - 1
                // The underline is now holding the margin — either all of it,
                // or the share `gapShares` took out of the blank run below.
                trailing = 0
            }
            // An ATX heading with no text has no line box at all on the page —
            // `<h2></h2>` is an empty block, and only its margins and (for
            // h1/h2) its rule survive. The editor stood a whole heading line
            // there: 40pt of nothing under an empty `#`.
            if !setext, headingIsEmpty(block, lines: lines, text: text),
               !revealedLines.contains(block.firstLine) {
                // An empty block with no height, padding or border has its own
                // top and bottom margins collapse into one — so an empty h3
                // contributes a single margin, not one above and one below.
                // h1 and h2 keep both, because their rule is a border and a
                // border stops the collapse.
                if level > 2 { trailing = 0 }
                let range = lines.lineRange(block.firstLine)
                if range.length > 0, range.location + range.length <= target.length {
                    let flat = (style.mutableCopy() as! NSMutableParagraphStyle)
                    flat.minimumLineHeight = BlockBoxes.collapsedLine
                    flat.maximumLineHeight = BlockBoxes.collapsedLine
                    target.addAttribute(.paragraphStyle, value: flat, range: range)
                }
            }
            if level <= 2 {
                // GitHub's h1/h2 rule: `padding-bottom: .3em` then a 1px
                // border. Padding is inside the box, so it adds to the
                // collapsed margin rather than collapsing with it — and it
                // stays above a setext underline that is now holding the
                // margin, which is where CSS puts the padding too.
                //
                // The inset is *not* added to `trailing` here, and this is the
                // one number in the block that must not be: `paragraphSpacing`
                // is margin-bottom, and TextKit drops it on the document's last
                // paragraph — correctly, because GitHub zeroes `:last-child`'s
                // margin-bottom too. Parked there, the padding went with it, so
                // a note ending in an h1/h2 stood ~11pt short of its Preview
                // and clipped its own rule. The marker below is now the whole
                // instruction: `RenderedBlockFragment.bottomMargin` reserves the
                // inset inside the fragment, where padding lives and where EOF
                // cannot reach it. See that override for why the line height
                // was the wrong place to move it to.
                target.addAttribute(headingRuleAttribute, value: level,
                                    range: NSRange(location: block.range.location,
                                                   length: min(1, block.range.length)))
            }

        case .fencedCode(_, let closed), .mathBlock(let closed):
            // `pre { padding: 16px }`, vertically. The fence lines are exactly
            // where that padding goes: concealed they are an empty band of the
            // right height, revealed they show the fence you are editing.
            //
            // An *unclosed* fence has no closing line — it runs to the end of
            // the note, and its last line is code. Treating that line as a
            // fence collapsed a line of the listing into a 16pt band, so the
            // block lost a line and gained nothing; the padding below has to be
            // made out of the last line's own height instead.
            applyFenceBand(block: block, closed: closed, lines: lines, to: target, metrics: m)
            applyCodeBand(block: block, lines: lines, to: target)
            if !closed, block.lineCount > 1 {
                padCodeLine(block.firstLine + block.lineCount - 1, top: false, bottom: true,
                            style: style, lines: lines, to: target, metrics: m)
            }

        case .indentedCode:
            // `pre { padding: 16px }`, vertically — as *line height*, not as
            // paragraph spacing.
            //
            // `paragraphSpacingBefore` and `paragraphSpacing` are dropped by
            // TextKit at the edges of the document, so a note that began or
            // ended with an indented code block lost that side's padding
            // outright. The fenced case never had the problem because its
            // fence lines *are* the padding; this gives the indented case the
            // same treatment by growing its first and last lines instead, and
            // pushing the glyphs to the far side of the space with a baseline
            // offset so the listing still sits where it should inside the box.
            let contentLast = lastContentLine(of: block, lines: lines, text: text)
            collapseLines(from: contentLast + 1, through: lastLineNumber,
                          total: collapsedTotal, lines: lines, to: target)
            if contentLast < lastLineNumber { trailing = 0 }
            applyCodeBand(block: block, through: contentLast, lines: lines, to: target)
            padCodeLine(block.firstLine, top: true,
                        bottom: contentLast == block.firstLine,
                        style: style, lines: lines, to: target, metrics: m)
            if contentLast > block.firstLine {
                padCodeLine(contentLast, top: false, bottom: true,
                            style: style, lines: lines, to: target, metrics: m)
            }
            gapLine = contentLast

        case .listItem(let listInfo):
            // Nothing precedes the first block, so a margin above it has no
            // gap to collapse into and has to be part of the line itself.
            let opensDocument = !blocks[..<index].enumerated().contains { i, earlier in
                BlockBoxes.isRendered(earlier, in: blocks, at: i, text: text, unrendered: unrendered)
            }
            extraTrailing = applyListItemInterior(block: block, info: listInfo, lines: lines,
                                                  text: text, to: target, theme: theme, metrics: m,
                                                  opensDocument: opensDocument,
                                                  loose: BlockBoxes.listIsLoose(
                                                    around: index, in: blocks, text: text,
                                                    unrendered: unrendered),
                                                  revealedLines: revealedLines)

        case .thematicBreak:
            applyThematicBreak(block: block, lines: lines, to: target,
                               theme: theme, revealedLines: revealedLines)

        default:
            break
        }

        // Obsidian callout chrome: tinted band + gutter bar + header icon.
        // (Plain blockquotes are handled per-line in `applyQuoteBars` so they
        // can nest.)
        if case .blockquote(let callout?) = block.kind {
            let (tint, icon) = calloutStyle(for: callout, theme: theme)
            target.addAttribute(calloutTintAttribute, value: tint, range: block.range)
            let indent = style.mutableCopy() as! NSMutableParagraphStyle
            indent.headIndent = m.quoteIndent + m.quotePadding
            indent.firstLineHeadIndent = indent.headIndent
            target.addAttribute(.paragraphStyle, value: indent, range: block.range)
            let header = NSRange(location: block.range.location, length: min(1, block.range.length))
            if header.length > 0 {
                target.addAttribute(calloutIconAttribute, value: icon, range: header)
            }
        }

        // Lines the reader never sees, inside a block that is otherwise content.
        applyUnrenderedLines(block: block, lines: lines, text: text, to: target,
                             theme: theme, unrendered: unrendered,
                             revealedLines: revealedLines,
                             nothingFollows: BlockBoxes.nextContent(
                                index, in: blocks, text: text, unrendered: unrendered) == nil)

        // The collapsed margin goes on the last line and nowhere else:
        // `paragraphSpacing` ends every *paragraph*, and TextKit ends one at
        // each newline, so a block-wide value would space a five-line
        // blockquote's own lines apart.
        let lastLine = lines.lineRange(gapLine)
        guard lastLine.length > 0,
              lastLine.location + lastLine.length <= target.length else { return }
        if trailing > 0 || extraTrailing > 0 {
            let existing = target.attribute(.paragraphStyle, at: lastLine.location,
                                            effectiveRange: nil) as? NSParagraphStyle ?? style
            let closing = (existing.mutableCopy() as! NSMutableParagraphStyle)
            // With a blank line below, the collapsed blank *fragment* already
            // stands for the margin between the blocks — adding the item's own
            // on top of it would count the same gap twice. Everything here is
            // margin: the one thing that used to be *padding* — an h1/h2's rule
            // inset — is reserved by `RenderedBlockFragment.bottomMargin` now,
            // inside the heading's own fragment, which is where padding belongs
            // and is the only place TextKit will not drop it at the end of the
            // note.
            closing.paragraphSpacing = max(trailing, nextIsBlank ? 0 : extraTrailing)
            target.addAttribute(.paragraphStyle, value: closing, range: lastLine)
        }
        keepARulesBottomMargin(block: block, at: index, in: blocks, line: lastLine,
                               text: text, to: target, unrendered: unrendered)
    }

    /// An `<hr>`'s bottom margin survives the end of the note. Nothing else's
    /// does, and that is not the inconsistency it looks like.
    ///
    /// TextKit drops the last paragraph's `paragraphSpacing` unconditionally,
    /// and for almost every block that is exactly right: a bottom margin at
    /// the end of the note collapses out through whatever contains it —
    /// neither `<li>` nor `<blockquote>` has padding or a border on those
    /// edges to stop it — and lands on `.markdown-body > *:last-child`, whose
    /// `margin-bottom` the stylesheet zeroes `!important`.
    ///
    /// A thematic break is the one element that cannot collapse at all:
    /// `hr::before` and `hr::after` are `display: table`, a clearfix, so the
    /// rule's own margins are sealed inside its box. Inside a list item the
    /// `:last-child` being zeroed is the `<ul>` two levels up and not the rule
    /// itself, so the page keeps 24pt below it and the editor threw it away —
    /// a note ending `- Foo` / `- * * *` stood 24pt short, and the pixel
    /// version of that is a note you cannot scroll to the bottom of.
    ///
    /// At the top level the hr *is* the `:last-child` whose margin is being
    /// zeroed, so TextKit's drop is already right — hence the container test
    /// as well as the end-of-note one. Read off the line rather than
    /// recomputed: `applyNestedRule` decides what an `<hr>` in an item is
    /// worth, and two opinions about that is one too many.
    private static func keepARulesBottomMargin(block: Block, at index: Int, in blocks: [Block],
                                               line: NSRange, text: NSString,
                                               to target: NSMutableAttributedString,
                                               unrendered: [NSRange]) {
        switch block.kind {
        case .listItem, .blockquote: break
        default: return
        }
        guard target.attribute(thematicBreakAttribute, at: line.location,
                               effectiveRange: nil) != nil else { return }
        // Walked *backwards* from the end, which stops at the first rendered
        // block it meets — a handful of trailing blank lines at most. Asking
        // "is anything after me rendered?" forwards, per block, is the same
        // answer and O(n) each time; over a whole note that is quadratic, and
        // it took the editor's own test suite from 26 seconds to five minutes.
        var lastRendered = blocks.count - 1
        while lastRendered > index,
              !BlockBoxes.isRendered(blocks[lastRendered], in: blocks, at: lastRendered,
                                     text: text, unrendered: unrendered) {
            lastRendered -= 1
        }
        guard lastRendered == index,
              let para = target.attribute(.paragraphStyle, at: line.location,
                                          effectiveRange: nil) as? NSParagraphStyle,
              para.paragraphSpacing > 0 else { return }
        // Moved, not copied. With a trailing blank run below this is not the
        // last paragraph after all, the spacing would still apply, and the two
        // would be counted together; the fragment is where the space lives now.
        let flat = (para.mutableCopy() as! NSMutableParagraphStyle)
        let escaping = para.paragraphSpacing
        flat.paragraphSpacing = 0
        target.addAttribute(.paragraphStyle, value: flat, range: line)
        target.addAttribute(escapingMarginAttribute, value: escaping,
                            range: NSRange(location: line.location, length: 1))
    }

    /// Lines with no glyphs left on them, inside a block that still has some.
    ///
    /// A code span may be written across lines — ```` ``\nfoo\n`` ```` is one
    /// `<code>` on one line of the page — and its delimiter lines conceal
    /// whole. Concealment is a *font* transform, though: the characters shrink
    /// to 0.01pt and the line box they sit in stays a full body line, so the
    /// editor drew three 24pt lines against a page that drew one. The same
    /// shape reaches any construct whose markers occupy a line alone.
    ///
    /// The block's trailing gap moves with them. `applyBase` parked it on the
    /// last line, which is exactly the line that is about to stop existing, so
    /// the margin below the block would have vanished with it — the trap the
    /// setext branch already had to step around.
    private static func collapseConcealedLines(block: Block, lines: LineIndex, text: NSString,
                                               to target: NSMutableAttributedString,
                                               revealedLines: Set<Int>) {
        switch block.kind {
        case .paragraph: break
        // Everything else already owns its own line geometry: a fence line is
        // the code box's padding, a setext underline is the heading's margin, a
        // quote line is rewritten by `applyQuoteBars` after this runs. Reaching
        // into those would be collapsing a line that is doing a job.
        default: return
        }
        let last = block.firstLine + block.lineCount - 1
        guard last > block.firstLine else { return }
        var blanked: [Int] = []
        var lastSurviving: Int?
        for line in block.firstLine...last {
            let content = lines.contentRange(line, in: text)
            if content.length > 0, !revealedLines.contains(line),
               hasNoGlyphs(content, in: target) {
                blanked.append(line)
            } else {
                lastSurviving = line
            }
        }
        // A block with nothing left is not this pass's business — that is what
        // `BlockBoxes.isUnrendered` decides, and it decides it for the whole
        // block, margins included.
        guard !blanked.isEmpty, let keep = lastSurviving else { return }

        var carried: CGFloat = 0
        for line in blanked {
            let range = lines.lineRange(line)
            guard range.length > 0, range.location + range.length <= target.length else { continue }
            let existing = target.attribute(.paragraphStyle, at: range.location,
                                            effectiveRange: nil) as? NSParagraphStyle
            if line > keep { carried = max(carried, existing?.paragraphSpacing ?? 0) }
            let flat = (existing?.mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            flat.minimumLineHeight = BlockBoxes.collapsedLine
            flat.maximumLineHeight = BlockBoxes.collapsedLine
            flat.paragraphSpacing = 0
            target.addAttribute(.paragraphStyle, value: flat, range: range)
        }
        guard carried > 0 else { return }
        let keepRange = lines.lineRange(keep)
        guard keepRange.length > 0, keepRange.location + keepRange.length <= target.length,
              let existing = target.attribute(.paragraphStyle, at: keepRange.location,
                                              effectiveRange: nil) as? NSParagraphStyle,
              let style = existing.mutableCopy() as? NSMutableParagraphStyle else { return }
        // A margin, not a sum: two adjoining margins collapse to the larger.
        style.paragraphSpacing = max(style.paragraphSpacing, carried)
        target.addAttribute(.paragraphStyle, value: style, range: keepRange)
    }

    /// The line endings inside this block that the page does not break at.
    ///
    /// Preview renders with hard breaks on, so a newline between two words is a
    /// `<br>` and the editor's line-for-line layout is right. A newline cmark
    /// has already eaten into a token is not: inside a code span, inside a
    /// link's `(…)`, inside a raw tag or an HTML comment, it is a space, the
    /// construct is one token, and the page draws one line where the editor
    /// drew two. `JoinedLines` turns the mark into one content element; this is
    /// the only place that decides where one goes.
    ///
    /// Three restrictions, each of which is a bug avoided rather than caution.
    ///
    ///   * **Paragraphs only.** Everything else owns its own line geometry — a
    ///     quote line is rewritten by `applyQuoteBars` after this runs and
    ///     carries a per-line indent and a gutter bar that a merged element
    ///     would have to draw once for two lines. Same restriction, same
    ///     reason, as `collapseConcealedLines`.
    ///   * **Both sides must draw ink.** A line the reader cannot see has
    ///     already been collapsed to a hairline above, so it is not a line of
    ///     the page and there is nothing to join it to; worse, a merged element
    ///     takes its paragraph style from its *first* character, so a run
    ///     headed by a collapsed line would pin the whole construct to 0.01pt.
    ///     `` ``⏎foo⏎bar⏎`` `` joins `foo` to `bar` and leaves both fence lines
    ///     exactly where `collapseConcealedLines` put them.
    ///   * **Not while the caret is in it.** Arriving reveals, like every other
    ///     concealment here — and revealing a join means the source comes back
    ///     apart onto the lines it is actually stored on, which is the only way
    ///     to type into it.
    ///
    /// The mark goes on the newline itself, and not into a set held beside the
    /// document, so that it can never disagree with the text: it is written by
    /// the restyle that would change it, inside the same `beginEditing`, which
    /// is exactly the edit `NSTextContentStorage` re-reads its elements on.
    private static func markJoinedLines(block: Block, lines: LineIndex, text: NSString,
                                        to target: NSMutableAttributedString,
                                        revealedLines: Set<Int>) {
        guard case .paragraph = block.kind, block.lineCount > 1 else { return }
        let first = block.firstLine, last = block.firstLine + block.lineCount - 1
        // `applyBase` has already cleared the mark for this block (it resets
        // the whole range), so a revealed block simply does not get one back.
        if (first...last).contains(where: revealedLines.contains) { return }

        var drawsInk: [Int: Bool] = [:]
        func ink(_ line: Int) -> Bool {
            if let known = drawsInk[line] { return known }
            let content = lines.contentRange(line, in: text)
            let value = content.length > 0 && !hasNoGlyphs(content, in: target)
            drawsInk[line] = value
            return value
        }

        for node in InlineParser.parse(text, in: trimmed(block, text: text)) {
            switch node.kind {
            case .code, .link, .rawHTML: break
            // Everything else either cannot span a line ending (the scanners
            // stop at one) or spans it without cmark eating it: `**a⏎b**` is
            // `<strong>` around a `<br>`, and the page breaks there too.
            default: continue
            }
            let start = node.range.location, end = start + node.range.length
            var i = start
            while i < end - 1 {
                if text.character(at: i) == 0x0A {
                    let above = lines.lineNumber(at: i)
                    if ink(above), ink(above + 1) {
                        target.addAttribute(joinedNewlineAttribute, value: true,
                                            range: NSRange(location: i, length: 1))
                    }
                }
                i += 1
            }
        }
    }

    /// The block's content without its final newline — the span the inline
    /// scanner is given everywhere else.
    private static func trimmed(_ block: Block, text: NSString) -> NSRange {
        var r = block.range
        if r.length > 0, text.character(at: r.location + r.length - 1) == 0x0A { r.length -= 1 }
        return r
    }

    /// Does every character of `content` draw nothing? Asked of the concealed
    /// *font* rather than of `markerAttribute`, which a revealed marker carries
    /// too — it is set on every syntax character, visible or not, and a line of
    /// visible `#`s is not a line of nothing.
    private static func hasNoGlyphs(_ content: NSRange, in target: NSMutableAttributedString) -> Bool {
        guard content.length > 0, content.location + content.length <= target.length else { return false }
        var allConcealed = true
        target.enumerateAttribute(.font, in: content, options: []) { value, _, stop in
            guard let font = value as? PlatformFont,
                  font.pointSize == EditorTheme.concealedSize else {
                allConcealed = false
                stop.pointee = true
                return
            }
        }
        return allConcealed
    }

    /// A list marker at the start of a quote line's content — `- `, `* `, `+ `,
    /// `1. `, `1) ` — with the width it draws at.
    private static func quoteListMarker(_ content: NSRange, in text: NSString)
    -> (range: NSRange, ordered: Bool, width: CGFloat)? {
        var i = content.location
        let end = content.location + content.length
        while i < end, text.character(at: i) == 0x20 { i += 1 }
        guard i < end else { return nil }
        let start = i
        let c = text.character(at: i)
        var ordered = false
        if c == 0x2D || c == 0x2A || c == 0x2B {                 // `-` `*` `+`
            i += 1
        } else if c >= 0x30, c <= 0x39 {
            var digits = 0
            while i < end, text.character(at: i) >= 0x30, text.character(at: i) <= 0x39, digits < 9 {
                digits += 1; i += 1
            }
            guard i < end, text.character(at: i) == 0x2E || text.character(at: i) == 0x29 else { return nil }
            i += 1
            ordered = true
        } else {
            return nil
        }
        // A marker needs a space after it, and content after that.
        guard i < end, text.character(at: i) == 0x20 else { return nil }
        i += 1
        guard i < end else { return nil }
        let range = NSRange(location: start, length: i - start)
        let width = ordered
            ? text.substring(with: range).size(withAttributes: [.font: PlatformFont.systemFont(ofSize: 16)]).width
            : 0
        return (range, ordered, width)
    }

    /// Is this content range wholly inside a range the renderer drops?
    private static func isUnrenderedContent(_ content: NSRange, in unrendered: [NSRange]) -> Bool {
        guard !unrendered.isEmpty, content.length > 0 else { return false }
        return unrendered.contains { NSIntersectionRange($0, content).length == content.length }
    }

    /// An ATX heading whose `#`s are followed by nothing — `##`, `# `, `### ###`.
    private static func headingIsEmpty(_ block: Block, lines: LineIndex, text: NSString) -> Bool {
        let content = lines.contentRange(block.firstLine, in: text)
        var i = content.location
        let end = content.location + content.length
        while i < end, text.character(at: i) == 0x20 { i += 1 }
        while i < end, text.character(at: i) == 0x23 { i += 1 }          // `#`
        // A closing sequence is still nothing: `### ###` is an empty h3.
        while i < end {
            let c = text.character(at: i)
            if c != 0x20 && c != 0x09 && c != 0x23 && c != 0x0D { return false }
            i += 1
        }
        return true
    }

    /// Collapse individual lines that the rendered page has no equivalent for,
    /// inside a block that is otherwise content.
    ///
    /// `BlockBoxes.isUnrendered` asks the question of a whole block, which is
    /// the right question when the block *is* the reference definition. It is
    /// the wrong one whenever the definition shares a block with something
    /// visible — `[foo]: /url` on the line above a paragraph, or a definition
    /// indented inside a list item — and then the line stayed at full height
    /// against a Preview that drew nothing at all.
    ///
    /// Caret entry brings the line back, exactly as it does for a definition
    /// that has a block to itself.
    private static func applyUnrenderedLines(block: Block, lines: LineIndex, text: NSString,
                                             to target: NSMutableAttributedString,
                                             theme: EditorTheme, unrendered: [NSRange],
                                             revealedLines: Set<Int>,
                                             nothingFollows: Bool = true) {
        // Single-line blocks included, because a block can be one line and
        // still hold source the reader never sees.
        //
        // KNOWN GAP: this does not reach a *blockquote* holding nothing but a
        // reference definition. `applyQuoteBars` runs after this and rewrites
        // the paragraph style of every quote line, so the collapse is undone —
        // and it has no `unrendered` to consult. Threading it through is the
        // fix; it is not a one-line one.
        guard !unrendered.isEmpty, block.lineCount >= 1 else { return }
        let first = block.firstLine, last = block.firstLine + block.lineCount - 1
        // Lines the per-kind switch above has already dealt with. An indented
        // code block keeps the blank lines that follow it, and `applyBase`
        // hands them the block's share of the gap below the `<pre>`; a setext
        // underline holds the heading's margin the same way. This pass ran
        // afterwards and flattened them to a hairline, so the margin under
        // every indented code block with a blank line in its range was thrown
        // away — 16pt that no measurement of the *block* could see, because the
        // block was the right height and the space beneath it was gone.
        let collapsedTail = BlockBoxes.collapsedTail(block, text: text, lines: lines)

        /// Does this line put anything on the page?
        func rendered(_ lineNumber: Int) -> Bool {
            let content = lines.contentRange(lineNumber, in: text)
            var lo = content.location, hi = content.location + content.length
            func blank(_ i: Int) -> Bool {
                let c = text.character(at: i)
                return c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
            }
            while lo < hi, blank(lo) { lo += 1 }
            while hi > lo, blank(hi - 1) { hi -= 1 }
            guard hi > lo else { return false }
            let trimmed = NSRange(location: lo, length: hi - lo)
            return !unrendered.contains {
                NSIntersectionRange($0, trimmed).length == trimmed.length
            }
        }
        // The last line of this block the reader actually sees. A blank line
        // after it is holding a margin above nothing: `- b` / blank /
        // `[ref]: /url` is one visible line, and the blank stood for the gap
        // between a paragraph and a definition that never appears — so the
        // item measured a whole block margin taller than the page.
        let lastRendered = (first...last).last(where: rendered)

        /// What the page makes of one line of this block.
        enum Kind { case blank, dropped, content }
        func kind(_ lineNumber: Int) -> Kind {
            let content = lines.contentRange(lineNumber, in: text)
            var lo = content.location
            var hi = content.location + content.length
            func blank(_ i: Int) -> Bool {
                let c = text.character(at: i)
                return c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
            }
            while lo < hi, blank(lo) { lo += 1 }
            while hi > lo, blank(hi - 1) { hi -= 1 }
            if hi <= lo { return .blank }
            let trimmed = NSRange(location: lo, length: hi - lo)
            return unrendered.contains(where: {
                NSIntersectionRange($0, trimmed).length == trimmed.length
            }) ? .dropped : .content
        }

        var collapse = Set<Int>()
        // **One region, one margin.** Blank lines and dropped source between
        // two of the item's own blocks are the same collapsed margin, not one
        // each: `- b` / blank / `  [ref]: /url` / blank / `  more` is a `<p>`'s
        // 16 above and a `<p>`'s 16 below, collapsed by CSS to 16 — and the
        // item's interior pass had given each blank line the whole of it, so
        // the item stood 16pt taller than the page. `BlockBoxes.gapShares`
        // has divided a *top-level* region this way since the reference
        // definitions were first hidden; inside a list item nothing did.
        var line = first
        while line <= last {
            guard kind(line) != .content else { line += 1; continue }
            var end = line
            while end + 1 <= last, kind(end + 1) != .content { end += 1 }
            if (line...end).contains(where: { kind($0) == .dropped }) {
                let keep = (line...end).first { kind($0) == .blank }
                for n in line...end where n != keep { collapse.insert(n) }
            }
            line = end + 1
        }
        // …and the block's own tail: everything below its last visible line,
        // which is holding a margin above nothing.
        //
        // Asked of the block alone that was wrong at the last line. An item's
        // lines are `1. Second:` and a blank, and the thing the blank is a
        // margin *to* — a quote, a fence, a table indented under the item's
        // text — is the next block along. So the 16pt `applyListItemInterior`
        // had just put there was flattened to a hairline and a numbered step
        // with anything under its text stood 16pt short. It took a note with
        // front matter or a reference definition in it to show, because the
        // whole pass is gated on there being unrendered source *somewhere*,
        // which is as good as a hidden flag.
        if let lastRendered, lastRendered < last {
            for n in (lastRendered + 1)...last where n != last || nothingFollows {
                collapse.insert(n)
            }
        }

        for lineNumber in first...last where !revealedLines.contains(lineNumber) {
            guard lineNumber <= last - collapsedTail else { continue }
            guard collapse.contains(lineNumber) || kind(lineNumber) == .dropped else { continue }
            let lineRange = lines.lineRange(lineNumber)
            guard lineRange.length > 0,
                  lineRange.location + lineRange.length <= target.length else { continue }
            let flat = NSMutableParagraphStyle()
            flat.minimumLineHeight = BlockBoxes.collapsedLine
            flat.maximumLineHeight = BlockBoxes.collapsedLine
            target.addAttributes([
                .paragraphStyle: flat,
                .font: theme.concealed,
                .foregroundColor: PlatformColor.clear,
                markerAttribute: true,
            ], range: lineRange)
        }
    }

    /// A blank line *inside* a list item is the margin between that item's own
    /// paragraphs, not a line of text.
    ///
    /// CommonMark keeps such a line in the item (see `BlockParser`'s blank-line
    /// rule) and renders the item's children as `<p>`s with the document's
    /// block margin between them. Left at the body line height, each one stood
    /// a third taller than the gap it stands for.
    ///
    /// Returns the margin the item's *last* line still needs from the
    /// block's trailing gap. A margin, and only a margin: it **collapses**
    /// with the gap the block already carries (CSS takes the larger of two
    /// adjoining margins, never their sum). It used to be a pair, the second
    /// half being an h1/h2's rule inset — padding, which adds instead of
    /// collapsing — and that half is now reserved by the heading fragment's
    /// own `bottomMargin`, so nothing here is padding any more.
    /// It cannot be applied here either way: `applyBase` writes the trailing
    /// spacing onto that same line afterwards and would overwrite it — the
    /// ordering that already caught the quote indent.
    @discardableResult
    private static func applyListItemInterior(block: Block, info: ListInfo,
                                              lines: LineIndex, text: NSString,
                                              to target: NSMutableAttributedString,
                                              theme: EditorTheme, metrics m: GFMBoxMetrics,
                                              opensDocument: Bool = false,
                                              loose: Bool = false,
                                              revealedLines: Set<Int> = [])
    -> CGFloat {
        let first = block.firstLine, last = block.firstLine + block.lineCount - 1
        /// The `ul`/`ol` padding every block inside this item inherits. CSS
        /// gives each list level 2em whatever the writer indented by.
        let itemListInset = CGFloat(BlockBoxes.listDepth(info) + 1) * m.listIndent
        var extraTrailing: CGFloat = 0
        // Where the item's own content sits — `ul { padding-left: 2em }`, once
        // per nesting level, the same number `BlockBoxes.baseStyle` gives the
        // item's text. A block *inside* the item starts there too.
        let itemContentIndent = m.listIndent * CGFloat(BlockBoxes.listDepth(info) + 1)
        // No early return for a one-line item: `- # Foo` is a single line and
        // still holds a block of its own.

        // A line indented four past the item's own content column is an
        // indented code block *inside* the item — cmark nests a `<pre>` in the
        // `<li>` and GitHub gives it the code box, padding and all. The editor
        // read it as one more line of the item's text, 28pt short of the box
        // it stands for.
        let codeColumn = info.contentColumn + 4
        /// The line's indent in *columns*, with tabs expanded to the next
        /// multiple of four as CommonMark defines them.
        ///
        /// Index and column are two different numbers, and conflating them
        /// meant a tab advanced the read position four characters instead of
        /// one: `\t\tbar` was read from the middle of the word and came back
        /// under-indented, so tab-indented code inside a list item was styled
        /// as list text.
        func indent(of lineNumber: Int) -> Int {
            let content = lines.contentRange(lineNumber, in: text)
            var i = 0, column = 0
            while i < content.length {
                let c = text.character(at: content.location + i)
                if c == 0x20 { column += 1 } else if c == 0x09 { column += 4 - (column % 4) } else { break }
                i += 1
            }
            return column
        }
        /// The column the line's own content starts at. On the item's first
        /// line that is measured *past the marker*: `1.     code` puts its
        /// content four columns beyond the item's content column, which makes
        /// it a code block even though the line itself has no indent at all.
        func contentColumn(of lineNumber: Int) -> Int {
            guard lineNumber == first else { return indent(of: lineNumber) }
            let content = lines.contentRange(lineNumber, in: text)
            // Walked from the end of the *marker*, not from `contentOffset`.
            // A tab straddles the boundary — one column of it is the item's
            // padding and the rest belongs to the content — so starting past it
            // throws those columns away, and `-\t\tfoo` came back four columns
            // short of the code block it is.
            var i = info.indent + info.markerLength
            var column = i
            while i < content.length {
                let c = text.character(at: content.location + i)
                if c == 0x20 { column += 1 } else if c == 0x09 { column += 4 - (column % 4) } else { break }
                i += 1
            }
            return column
        }
        /// A fence delimiter on this line — measured past the item's marker on
        /// the first line, which is where `1. ``` ` puts it.
        func fenceDelimiter(_ lineNumber: Int) -> (marker: unichar, count: Int)? {
            let content = lines.contentRange(lineNumber, in: text)
            var i = content.location
            let end = content.location + content.length
            if lineNumber == first { i = min(i + info.contentOffset, end) }
            while i < end, text.character(at: i) == 0x20 { i += 1 }
            guard i < end else { return nil }
            let marker = text.character(at: i)
            guard marker == 0x60 || marker == 0x7E else { return nil }
            var count = 0
            while i < end, text.character(at: i) == marker { count += 1; i += 1 }
            return count >= 3 ? (marker, count) : nil
        }
        func isCode(_ lineNumber: Int) -> Bool {
            !BlockBoxes.isBlankLine(lineNumber, text: text, lines: lines)
                && contentColumn(of: lineNumber) >= codeColumn
        }

        // The line the `<li>`'s marker is actually laid into — which is not
        // always the line that *writes* it. An item whose marker line carries
        // nothing collapses that line to a hairline and the bullet moves down
        // to the first line that draws (`carryListBullets`), so the block
        // starting *there* is the one whose first line box has to make room for
        // a marker set in the item's own font. Keyed on `first` instead, a
        // code block written as `-` / `  ``` ` measured a line of code where
        // the page had drawn a line of prose — 4pt per item, and invisible in
        // any item whose marker line has text on it.
        let markerLine: Int = {
            guard block.lineCount > 1,
                  itemMarkerLineIsEmpty(block, info: info, lines: lines, text: text)
            else { return first }
            return (first + 1...last).first {
                !BlockBoxes.isBlankLine($0, text: text, lines: lines)
            } ?? first
        }()

        // An item whose marker line carries nothing — `-   ` with the content on
        // the line below — renders as a single line: the marker belongs beside
        // that content, and the empty line is not a line of the document at
        // all. Collapse it and move the bullet down, or the item stands a whole
        // body line taller than the one Preview draws.
        if block.lineCount > 1, itemMarkerLineIsEmpty(block, info: info, lines: lines, text: text) {
            let markerRange = lines.lineRange(first)
            if markerRange.length > 0, markerRange.location + markerRange.length <= target.length {
                let flat = NSMutableParagraphStyle()
                flat.minimumLineHeight = BlockBoxes.collapsedLine
                flat.maximumLineHeight = BlockBoxes.collapsedLine
                target.addAttributes([
                    .paragraphStyle: flat,
                    .font: theme.concealed,
                    .foregroundColor: PlatformColor.clear,
                    markerAttribute: true,
                ], range: markerRange)
                // Carry the bullet to the first line that has something to sit
                // beside. Left behind it drew inside a hundredth-of-a-point
                // line, which is to say not at all.
                // The bullet moves too — but not from here. `StyleSpec`'s
                // marker run is applied *after* this, and puts the attribute
                // straight back on the line we just collapsed, so a carry made
                // during the block pass is undone before anything draws. It
                // happens in `carryListBullets`, at the end of the block.
                target.removeAttribute(listBulletAttribute, range: markerRange)
            }
        }

        // Consumed by the item's first line of prose, and cleared unused by
        // any other kind of opening block: a heading reserves its own margin
        // (`applyNestedHeading(opensDocument:)`), and `pre`, `blockquote`,
        // `ul` and `table` all have `margin-top: 0`, so nothing escapes.
        var pendingTopMargin = opensDocument && loose
        func growLineHeight(_ lineNumber: Int, by amount: CGFloat) {
            let range = lines.lineRange(lineNumber)
            guard range.length > 0, range.location + range.length <= target.length else { return }
            // The fragment's own `topMargin`, not the line height and not
            // `paragraphSpacingBefore`. TextKit drops the latter on the
            // document's very first paragraph, which is the only place this is
            // ever needed — and a *line height* is per **wrapped visual line**,
            // so an opening item long enough to wrap paid the margin once per
            // line. This file styles without knowing the pane's width, so
            // nothing here could have noticed; a 420pt sweep of whole documents
            // did, at +16pt on the first item of three of them.
            target.addAttribute(openingMarginAttribute, value: amount,
                                range: NSRange(location: range.location, length: 1))
        }

        var line = first
        while line <= last {
            if BlockBoxes.isBlankLine(line, text: text, lines: lines) {
                var run = 1
                while line + run <= last,
                      BlockBoxes.isBlankLine(line + run, text: text, lines: lines) { run += 1 }
                // A blank run that only separates code from more code belongs
                // to the code box and keeps the code's own line height.
                let bridgesCode = line > first && isCode(line - 1)
                    && line + run <= last && isCode(line + run)
                // One margin, however many blank lines were typed to make it —
                // the same rule a blank run between two blocks follows.
                let each = bridgesCode
                    ? m.codeLineHeight
                    : max(BlockBoxes.minimumBlankLine, m.blockGap / CGFloat(run))
                for i in line..<(line + run) {
                    let range = lines.lineRange(i)
                    guard range.length > 0, range.location + range.length <= target.length else { continue }
                    let para = NSMutableParagraphStyle()
                    para.minimumLineHeight = each
                    para.maximumLineHeight = each
                    if bridgesCode {
                        para.firstLineHeadIndent = CGFloat(info.contentOffset) * 0 + m.codePadding
                        para.headIndent = m.codePadding
                        target.addAttribute(codeBandAttribute, value: 1, range: range)
                    }
                    target.addAttribute(.paragraphStyle, value: para, range: range)
                }
                line += run
                continue
            }
            // An ATX heading is a block inside the item, exactly as it is
            // inside a blockquote — `- # Foo` is an `<h1>` in the `<li>`, and
            // the editor read it as one more line of the item's prose.
            if applyNestedHeading(line, block: block, info: info, lines: lines,
                                  text: text, to: target, theme: theme, metrics: m,
                                  opensDocument: opensDocument && line == first) != nil {
                pendingTopMargin = false
                if line == last {
                    // The margin only — the level no longer matters here.
                    // `applyNestedHeading` marked the line with
                    // `headingRuleAttribute`, and the rule's inset is padding
                    // the fragment reserves for itself; asking for it here as
                    // well counted the same space twice.
                    extraTrailing = m.blockGap
                }
                line += 1
                continue
            }
            // `- Bar` over `  ---` is a setext h2 inside the item: the text
            // line takes the heading's box and the underline collapses to hold
            // the margin, exactly as a top-level setext heading does.
            if applyNestedSetext(line, block: block, info: info, lines: lines, text: text,
                                 to: target, theme: theme, metrics: m) {
                pendingTopMargin = false
                line += 1
                continue
            }
            // `- * * *` is an `<hr>` inside the `<li>`, not a line of prose.
            if applyNestedRule(line, block: block, info: info, lines: lines, text: text,
                               to: target, theme: theme, metrics: m) {
                pendingTopMargin = false
                line += 1
                continue
            }
            // A fenced code block inside the item. The delimiters are the
            // box's 16pt padding, exactly as they are at the top level; the
            // lines between are the listing. Left unstyled they drew as raw
            // backticks and body text where the page draws a code box.
            if let fence = fenceDelimiter(line) {
                pendingTopMargin = false
                var close = line + 1
                while close <= last {
                    if let d = fenceDelimiter(close), d.marker == fence.marker,
                       d.count >= fence.count { break }
                    close += 1
                }
                let closed = close <= last
                let contentEnd = closed ? close - 1 : last
                for delimiter in [line] + (closed ? [close] : []) {
                    let range = lines.lineRange(delimiter)
                    guard range.length > 0,
                          range.location + range.length <= target.length else { continue }
                    let band = NSMutableParagraphStyle()
                    band.minimumLineHeight = m.codePadding
                    band.maximumLineHeight = m.codePadding
                    // The padding rows are part of the same box, so they start
                    // where the box starts. `drawCodeBand` reads the panel's
                    // left edge off `headIndent - codePadding`, so leaving
                    // these two at zero painted the top and bottom 16pt of the
                    // box across the whole column while the listing between
                    // them was inset — a notch cut out of the panel's left
                    // side, exactly the width of the list's indent.
                    band.firstLineHeadIndent = itemContentIndent + m.codePadding
                    band.headIndent = itemContentIndent + m.codePadding
                    band.tailIndent = -m.codePadding
                    target.addAttribute(.paragraphStyle, value: band, range: range)
                    target.addAttribute(codeBandAttribute, value: delimiter == line ? 0 : 2,
                                        range: range)
                }
                if contentEnd >= line + 1 {
                    applyNestedCode(from: line + 1, through: contentEnd, lines: lines,
                                    to: target, theme: theme, metrics: m, interior: true,
                                    carriesMarker: line == markerLine,
                                    itemIndent: itemContentIndent)
                }
                // A code block that *ends* the item exports its own
                // `margin-bottom`. The stylesheet zeroes that margin only on
                // `.markdown-body > *:last-child` — a direct child of the
                // article — so a `<pre>` inside an `<li>` keeps its 16, and
                // with no padding or border on either the `<li>` or the `<ul>`
                // to stop it, it collapses straight out to meet whatever comes
                // next. Between two tight items that is `li + li`'s 4pt, so
                // the gap there is 16 and not 4 — the same shape as the
                // thematic-break rule in `BlockBoxes.gapBetween`.
                if (closed ? close : last) == last { extraTrailing = m.blockGap }
                line = (closed ? close : last) + 1
                continue
            }
            guard isCode(line) else {
                // A **loose** item wraps its own text in a `<p>`, and that
                // paragraph's `margin-top` collapses straight out through the
                // `<li>` and the `<ul>` — neither has padding or a border to
                // stop it. Anywhere else it meets the margin below whatever
                // precedes the list and disappears into it, which is why this
                // is invisible until the list is the first thing in the note:
                // there is nothing above for it to collapse into, so the page
                // simply starts 16pt lower. (`.markdown-body > *:first-child`
                // zeroes the *list's* top margin, not the paragraph's — the
                // same asymmetry that lets a closing `<pre>`'s bottom margin
                // escape below.) TextKit drops `paragraphSpacingBefore` on the
                // document's first paragraph outright, so as with a heading
                // that opens the document it goes into the line box, where the
                // pinned height puts spare space above the glyphs.
                if pendingTopMargin {
                    pendingTopMargin = false
                    growLineHeight(line, by: m.blockGap)
                }
                line += 1
                continue
            }
            pendingTopMargin = false
            // Extend the run over blank lines of *any* length, as long as code
            // resumes after them: a code block keeps its blank lines, and one
            // that looked only a single line ahead split `bar` / blank / blank
            // / `baz` into two boxes, each paying for its own padding.
            var run = 1
            while line + run <= last {
                if isCode(line + run) { run += 1; continue }
                var ahead = run
                while line + ahead <= last,
                      BlockBoxes.isBlankLine(line + ahead, text: text, lines: lines) { ahead += 1 }
                guard ahead > run, line + ahead <= last, isCode(line + ahead) else { break }
                run = ahead + 1
            }
            applyNestedCode(from: line, through: line + run - 1, lines: lines,
                            to: target, theme: theme, metrics: m,
                            // The marker stays a marker: on the item's first
                            // line the code box starts past it, so the `1.` is
                            // not set in the code font or pulled into the band.
                            skipOnFirst: line == first ? info.contentOffset : 0,
                            carriesMarker: line == markerLine,
                            itemIndent: itemContentIndent)
            // Indented code closing the item, same escaping margin as the
            // fenced case above.
            if line + run - 1 == last { extraTrailing = m.blockGap }
            line += run
        }
        return extraTrailing
    }

    /// Hide the fence delimiters of a code block written inside a list item.
    ///
    /// A delimiter line *is* the code box's 16pt padding — there has to be
    /// nothing in it. At the top level `StyleSpec` conceals the fence and the
    /// band is what is left over; inside an item nothing did, so the ``` and,
    /// far more visibly, its info string were drawn as the first line of the
    /// listing. `1. Install:` over an indented ```bash block — every README
    /// ever written — put the word "bash" inside the code box. Every height
    /// agreed, which is why only a picture found it.
    ///
    /// Like `carryListBullets` this is a pass of its own, and for the same
    /// reason: `StyleSpec`'s runs are applied *after* the block pass and put
    /// the font and colour straight back. Done during the interior pass, the
    /// concealment was silently undone before anything drew.
    ///
    /// The record of which lines are delimiters is the `codeBandAttribute` the
    /// interior pass already wrote — 0 for the opening band and 2 for the
    /// closing one, 1 for the listing between them.
    private static func concealNestedFences(for block: Block, lines: LineIndex, text: NSString,
                                            to target: NSMutableAttributedString,
                                            theme: EditorTheme, revealedLines: Set<Int>) {
        guard case .listItem(let info) = block.kind else { return }
        let first = block.firstLine, last = first + block.lineCount - 1
        for lineNumber in first...last where !revealedLines.contains(lineNumber) {
            let range = lines.lineRange(lineNumber)
            guard range.length > 0, range.location + range.length <= target.length,
                  let band = target.attribute(codeBandAttribute, at: range.location,
                                              effectiveRange: nil) as? Int,
                  band == 0 || band == 2 else { continue }
            // On the item's own line the marker is not part of the fence:
            // `1. ``` ` still has to show its `1.`.
            var hidden = range
            if lineNumber == first {
                let skip = min(info.contentOffset, range.length)
                hidden = NSRange(location: range.location + skip, length: range.length - skip)
            }
            guard hidden.length > 0 else { continue }
            target.addAttributes([.font: theme.concealed,
                                  .foregroundColor: PlatformColor.clear,
                                  markerAttribute: true], range: hidden)
        }
    }

    /// The item's own indent, on the lines of a code block inside it.
    ///
    /// cmark strips those columns before the `<pre>` ever sees the line, so
    /// Preview's listing starts at the box's padding and the editor's started
    /// two or three columns further right — the item's indent drawn as leading
    /// whitespace *inside* the code box. It is not only crooked: those columns
    /// take width, so the editor's code column is that much narrower and wraps
    /// a line earlier than the page does. At 800pt nothing wraps and nothing
    /// shows; at 640 a 61-character line was two lines in Edit and one in
    /// Preview.
    ///
    /// A pass of its own, run **after** the cmark overlay, for the same reason
    /// `concealNestedFences` is one: `GFMLiveStyle.emitCodeBlock` paints a
    /// `.codeBlock` run across the whole body of the block, indent included,
    /// and it runs after `applyBase` — so concealing the columns down in
    /// `applyNestedCode` was undone a few lines later, silently and completely.
    /// (Measured both ways: the wrap threshold moved with the item's content
    /// column either way, which is what says the concealment never took.)
    ///
    /// Only the item's *own* columns. Whatever the program indents itself by
    /// past them is the program's, and an indented code block's four columns
    /// are its own marker — neither is hidden here.
    private static func concealNestedCodeIndent(for block: Block, lines: LineIndex, text: NSString,
                                                to target: NSMutableAttributedString,
                                                theme: EditorTheme, revealedLines: Set<Int>) {
        guard case .listItem(let info) = block.kind, info.contentColumn > 0,
              block.lineCount > 1 else { return }
        let first = block.firstLine, last = first + block.lineCount - 1
        for lineNumber in (first + 1)...last where !revealedLines.contains(lineNumber) {
            let range = lines.lineRange(lineNumber)
            guard range.length > 0, range.location + range.length <= target.length,
                  target.attribute(codeBandAttribute, at: range.location,
                                   effectiveRange: nil) != nil else { continue }
            var i = range.location, column = 0
            let end = range.location + range.length
            while i < end, column < info.contentColumn {
                let c = text.character(at: i)
                if c == 0x20 { column += 1 } else if c == 0x09 { column += 4 - (column % 4) }
                else { break }
                i += 1
            }
            guard i > range.location else { continue }
            target.addAttributes([.font: theme.concealed,
                                  .foregroundColor: PlatformColor.clear,
                                  markerAttribute: true],
                                 range: NSRange(location: range.location, length: i - range.location))
        }
    }

    /// Move an item's bullet from the line that *writes* the marker to the line
    /// the rendered page draws it beside.
    ///
    /// They are the same line for ordinary text, and different whenever the
    /// marker line renders as something with no line box of its own: an empty
    /// marker line (`-` with its content below), or an opening fence, which
    /// stands in for the code box's top padding. `<li>` puts its marker in the
    /// first line box of its first child, and a padding band is not one.
    ///
    /// A separate pass because `StyleSpec`'s own marker run runs *after* the
    /// block pass and re-adds the attribute where the author typed it. Carried
    /// during the block pass, the move was silently undone — which is why `-`
    /// over `  foo` drew no bullet at all: the attribute went back onto a line
    /// collapsed to a hundredth of a point.
    private static func carryListBullets(for block: Block, lines: LineIndex, text: NSString,
                                         to target: NSMutableAttributedString) {
        guard case .listItem(let info) = block.kind, block.lineCount > 1 else { return }
        let first = block.firstLine, last = first + block.lineCount - 1
        var destination: Int?
        if itemMarkerLineIsEmpty(block, info: info, lines: lines, text: text) {
            destination = (first + 1...last).first {
                !BlockBoxes.isBlankLine($0, text: text, lines: lines)
            }
        } else if openingFenceLength(block, info: info, lines: lines, text: text) != nil {
            destination = first + 1
        }
        guard let destination, destination <= last else { return }
        let markerRange = lines.lineRange(first)
        guard markerRange.length > 0, markerRange.location + markerRange.length <= target.length,
              let bullet = target.attribute(listBulletAttribute, at: markerRange.location,
                                            effectiveRange: nil) else { return }
        target.removeAttribute(listBulletAttribute, range: markerRange)
        let range = lines.lineRange(destination)
        guard range.length > 0, range.location + range.length <= target.length else { return }
        target.addAttribute(listBulletAttribute, value: bullet,
                            range: NSRange(location: range.location, length: 1))
    }

    /// The length of a code fence written on the item's own marker line —
    /// `1. ``` ` — or nil when the line carries something else.
    private static func openingFenceLength(_ block: Block, info: ListInfo, lines: LineIndex,
                                           text: NSString) -> Int? {
        let content = lines.contentRange(block.firstLine, in: text)
        let end = content.location + content.length
        var i = min(content.location + info.contentOffset, end)
        while i < end, text.character(at: i) == 0x20 { i += 1 }
        guard i < end else { return nil }
        let marker = text.character(at: i)
        guard marker == 0x60 || marker == 0x7E else { return nil }
        var count = 0
        while i < end, text.character(at: i) == marker { count += 1; i += 1 }
        return count >= 3 ? count : nil
    }

    /// Does the item's marker line carry nothing after the marker?
    private static func itemMarkerLineIsEmpty(_ block: Block, info: ListInfo,
                                              lines: LineIndex, text: NSString) -> Bool {
        let content = lines.contentRange(block.firstLine, in: text)
        var i = min(content.location + info.contentOffset, content.location + content.length)
        let end = content.location + content.length
        while i < end {
            let c = text.character(at: i)
            if c != 0x20 && c != 0x09 && c != 0x0D { return false }
            i += 1
        }
        return true
    }

    /// A setext underline inside a list item — `---` or `===` on the line below
    /// the item's text. Styles the *text* line as the heading and collapses the
    /// underline. Returns whether `lineNumber` was such an underline.
    @discardableResult
    private static func applyNestedSetext(_ lineNumber: Int, block: Block, info: ListInfo,
                                          lines: LineIndex, text: NSString,
                                          to target: NSMutableAttributedString,
                                          theme: EditorTheme, metrics m: GFMBoxMetrics) -> Bool {
        guard lineNumber > block.firstLine else { return false }
        let content = lines.contentRange(lineNumber, in: text)
        var i = content.location
        let end = content.location + content.length
        while i < end, text.character(at: i) == 0x20 { i += 1 }
        guard i < end else { return false }
        let marker = text.character(at: i)
        guard marker == 0x2D || marker == 0x3D else { return false }
        var marks = 0
        var j = i
        while j < end {
            let c = text.character(at: j)
            if c == marker { marks += 1 } else if c != 0x20 && c != 0x09 && c != 0x0D { return false }
            j += 1
        }
        guard marks >= 1 else { return false }
        // The line above has to carry the heading's text.
        let above = lineNumber - 1
        guard !BlockBoxes.isBlankLine(above, text: text, lines: lines) else { return false }
        let level = marker == 0x3D ? 1 : 2

        // The heading's own box on the text line.
        let aboveRange = lines.lineRange(above)
        guard aboveRange.length > 0, aboveRange.location + aboveRange.length <= target.length,
              let existing = target.attribute(.paragraphStyle, at: aboveRange.location,
                                              effectiveRange: nil) as? NSParagraphStyle,
              let para = existing.mutableCopy() as? NSMutableParagraphStyle else { return false }
        para.minimumLineHeight = m.headingLineHeight(level)
        para.maximumLineHeight = m.headingLineHeight(level)
        target.addAttribute(.paragraphStyle, value: para, range: aboveRange)
        if level <= 2 {
            target.addAttribute(headingRuleAttribute, value: level,
                                range: NSRange(location: aboveRange.location, length: 1))
        }

        let aboveContent = lines.contentRange(above, in: text)
        var textStart = aboveContent.location
        if above == block.firstLine {
            textStart = min(textStart + info.contentOffset, aboveContent.location + aboveContent.length)
        }
        let textRange = NSRange(location: textStart,
                                length: aboveContent.location + aboveContent.length - textStart)
        if textRange.length > 0 {
            target.addAttributes([
                .font: theme.headingFont(level: level),
                .foregroundColor: theme.headingColor(level: level),
            ], range: textRange)
            let lift = BlockBoxes.halfLeading(.heading(level: level), theme: theme)
            if lift > 0 { target.addAttribute(.baselineOffset, value: -lift, range: textRange) }
        }

        // The underline holds the heading's bottom **margin**, and only that.
        // It used to hold the rule's inset as well, which put the padding
        // *below* the border box instead of inside it — invisible while the
        // two are adjacent and wrong the moment anything is drawn from either
        // edge. The inset is the heading fragment's own `bottomMargin` now,
        // reserved above this line, exactly as `padding-bottom` sits above
        // `margin-bottom` in CSS.
        let lineRange = lines.lineRange(lineNumber)
        guard lineRange.length > 0, lineRange.location + lineRange.length <= target.length else { return false }
        let flat = NSMutableParagraphStyle()
        flat.minimumLineHeight = max(BlockBoxes.collapsedLine, m.blockGap)
        flat.maximumLineHeight = flat.minimumLineHeight
        target.addAttributes([
            .paragraphStyle: flat,
            .font: theme.concealed,
            .foregroundColor: PlatformColor.clear,
            markerAttribute: true,
        ], range: lineRange)
        return true
    }

    /// A thematic break inside a list item: the rule's own 4pt bar with the
    /// margins CSS gives an `<hr>`, in place of a line of text.
    @discardableResult
    private static func applyNestedRule(_ lineNumber: Int, block: Block, info: ListInfo,
                                        lines: LineIndex, text: NSString,
                                        to target: NSMutableAttributedString,
                                        theme: EditorTheme, metrics m: GFMBoxMetrics) -> Bool {
        let content = lines.contentRange(lineNumber, in: text)
        var i = content.location
        let end = content.location + content.length
        if lineNumber == block.firstLine { i = min(i + info.contentOffset, end) }
        while i < end, text.character(at: i) == 0x20 { i += 1 }
        guard i < end else { return false }
        let marker = text.character(at: i)
        guard marker == 0x2D || marker == 0x2A || marker == 0x5F else { return false }
        var marks = 0
        var j = i
        while j < end {
            let c = text.character(at: j)
            if c == marker { marks += 1 } else if c != 0x20 && c != 0x09 && c != 0x0D { return false }
            j += 1
        }
        guard marks >= 3 else { return false }

        let lineRange = lines.lineRange(lineNumber)
        guard lineRange.length > 0, lineRange.location + lineRange.length <= target.length else { return false }
        let existing = target.attribute(.paragraphStyle, at: lineRange.location,
                                        effectiveRange: nil) as? NSParagraphStyle
        let para = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        para.minimumLineHeight = m.ruleThickness
        para.maximumLineHeight = m.ruleThickness
        para.paragraphSpacingBefore = m.ruleGap
        para.paragraphSpacing += m.ruleGap
        target.addAttributes([
            .paragraphStyle: para,
            .font: theme.concealed,
            .foregroundColor: PlatformColor.clear,
        ], range: NSRange(location: i, length: end - i))
        target.addAttribute(.paragraphStyle, value: para, range: lineRange)
        // The fragment looks for this at its *first* character, which inside a
        // list item is the marker — so an `<hr>` in an item reserved its 4pt
        // and then drew nothing at all.
        target.addAttribute(thematicBreakAttribute, value: m.ruleThickness,
                            range: NSRange(location: lineRange.location, length: 1))
        return true
    }

    /// Give an ATX heading inside a list item its own box — line height, font,
    /// concealed `#` marker and the h1/h2 rule inset. Returns whether the line
    /// was one.
    @discardableResult
    private static func applyNestedHeading(_ lineNumber: Int, block: Block, info: ListInfo,
                                           lines: LineIndex, text: NSString,
                                           to target: NSMutableAttributedString,
                                           theme: EditorTheme, metrics m: GFMBoxMetrics,
                                           opensDocument: Bool = false) -> Int? {
        let content = lines.contentRange(lineNumber, in: text)
        var i = content.location
        let end = content.location + content.length
        if lineNumber == block.firstLine { i = min(i + info.contentOffset, end) }
        while i < end, text.character(at: i) == 0x20 { i += 1 }
        let markerStart = i
        var level = 0
        while i < end, text.character(at: i) == 0x23, level < 7 { level += 1; i += 1 }
        guard level >= 1, level <= 6, i == end || text.character(at: i) == 0x20 else { return nil }
        while i < end, text.character(at: i) == 0x20 { i += 1 }

        let lineRange = lines.lineRange(lineNumber)
        guard lineRange.length > 0, lineRange.location + lineRange.length <= target.length else { return nil }
        let existing = target.attribute(.paragraphStyle, at: lineRange.location,
                                        effectiveRange: nil) as? NSParagraphStyle
        let para = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        let lineHeight = m.headingLineHeight(level)
        para.minimumLineHeight = lineHeight
        para.maximumLineHeight = lineHeight
        // Opening the document, the heading's top margin has nothing above it
        // to collapse into, and TextKit drops `paragraphSpacingBefore` on the
        // first paragraph outright — the same edge that cost an indented code
        // block its top padding. So it goes on the **fragment**, which counts
        // it once however many visual lines the heading wraps to.
        //
        // It used to be added to the line height, on the reasoning that a
        // pinned line height puts every bit of spare height above the glyphs.
        // That is true, and it is why it looked right: at a pane wide enough
        // for the heading to fit, one line box holds one margin and the answer
        // is exact. A line height applies to every *wrapped* line, though, and
        // this file styles without knowing the pane's width — so `- # <a
        // heading long enough to wrap>` opening a note measured +24.01pt at
        // 800, +48.01 at 560 and +72.01 at 420, one whole `headingTopGap` per
        // line the pane took away. The fragment attribute that replaces it did
        // not exist when the line-height version was written; it does now, and
        // it is the same one the loose item's own opening paragraph uses.
        if opensDocument {
            target.addAttribute(openingMarginAttribute, value: m.headingTopGap,
                                range: NSRange(location: lineRange.location, length: 1))
        }
        // A heading inside an item is a *block* in it: it carries the margins
        // a heading carries anywhere, not just the space for its rule. The
        // caller adds the bottom margin when this is the item's last line —
        // `applyBase` writes the trailing gap there afterwards and would
        // otherwise overwrite it.
        if lineNumber > block.firstLine { para.paragraphSpacingBefore = m.headingTopGap }
        para.paragraphSpacing += m.blockGap
        if level <= 2 {
            // GitHub draws h1/h2's border inside the item too. The space it
            // needs is not added to `paragraphSpacing`: that is margin-bottom,
            // and the rule's `padding-bottom` + border is inside the box.
            // `RenderedBlockFragment.bottomMargin` reserves it off this very
            // attribute, so marking the line is the whole instruction.
            target.addAttribute(headingRuleAttribute, value: level,
                                range: NSRange(location: lineRange.location, length: 1))
        }
        target.addAttribute(.paragraphStyle, value: para, range: lineRange)

        if i < end {
            let textRange = NSRange(location: i, length: end - i)
            target.addAttributes([
                .font: theme.headingFont(level: level),
                .foregroundColor: theme.headingColor(level: level),
            ], range: textRange)
            let lift = BlockBoxes.halfLeading(.heading(level: level), theme: theme)
            if lift > 0 { target.addAttribute(.baselineOffset, value: -lift, range: textRange) }
        }
        if i > markerStart {
            target.addAttributes([
                .font: theme.concealed,
                .foregroundColor: PlatformColor.clear,
                markerAttribute: true,
            ], range: NSRange(location: markerStart, length: i - markerStart))
        }
        return level
    }

    /// The `pre` box for an indented code block nested inside a list item:
    /// the code line height and font, `pre { padding: 16px }` on all four
    /// sides, and the band the fragment paints behind it.
    /// - Parameter carriesMarker: whether the list marker is laid into this
    ///   run's first line box. A `<li>` whose first child is a block puts its
    ///   marker in that block's first line box, and the marker is set in the
    ///   *item's* font at the item's line height — so a code block opening a
    ///   list item has a first line as tall as a line of prose, not as tall as
    ///   a line of code. It is the one place a code box is not uniform.
    /// - Parameter itemIndent: how far the enclosing `<li>`'s content is pushed
    ///   right — `ul { padding-left: 2em }`, once per nesting level. The style
    ///   built below is a **fresh** one, so whatever the item's own lines carry
    ///   is not inherited: without this the `<pre>` inside a numbered step was
    ///   laid out at the document's left margin, 32pt left of the page's and
    ///   32pt wider. No height could see it at a comfortable pane width —
    ///   a wider box is the same height until something in it wraps — and at
    ///   420pt it showed up as whole code lines that wrapped on one side and
    ///   not the other. In the picture it is unmistakable: the box starts under
    ///   the marker in Edit and under the item's text in Preview.
    private static func applyNestedCode(from first: Int, through last: Int,
                                        lines: LineIndex,
                                        to target: NSMutableAttributedString,
                                        theme: EditorTheme, metrics m: GFMBoxMetrics,
                                        skipOnFirst: Int = 0, interior: Bool = false,
                                        carriesMarker: Bool = false,
                                        itemIndent: CGFloat = 0) {
        for lineNumber in first...last {
            var range = lines.lineRange(lineNumber)
            guard range.length > 0, range.location + range.length <= target.length else { continue }
            let styleRange = range
            if lineNumber == first, skipOnFirst > 0, skipOnFirst < range.length {
                range = NSRange(location: range.location + skipOnFirst,
                                length: range.length - skipOnFirst)
            }
            // In `interior` mode the padding lives on the fence delimiters,
            // which are their own lines — these are the listing itself.
            let top = !interior && lineNumber == first
            let bottom = !interior && lineNumber == last
            let para = NSMutableParagraphStyle()
            let listing = lineNumber == first && carriesMarker
                ? max(m.codeLineHeight, m.bodyLineHeight) : m.codeLineHeight
            // Top padding only: the bottom half is reserved below the line box.
            // See `padCodeLine` for why the two are not symmetrical.
            para.minimumLineHeight = listing + (top ? m.codePadding : 0)
            para.maximumLineHeight = para.minimumLineHeight
            para.firstLineHeadIndent = itemIndent + m.codePadding
            para.headIndent = itemIndent + m.codePadding
            para.tailIndent = -m.codePadding
            target.addAttribute(.paragraphStyle, value: para, range: styleRange)
            target.addAttributes([
                .font: theme.mono,
                .foregroundColor: theme.text,
            ], range: range)
            let position = interior ? 1 : (first == last ? 3 : (top ? 0 : (bottom ? 2 : 1)))
            target.addAttribute(codeBandAttribute, value: position, range: styleRange)
            // On the *style* range, not the marker-skipped one: the fragment
            // reads its bottom padding at its own first character, which is the
            // start of the line however much of it the item's marker took.
            if bottom {
                target.addAttribute(codeBottomPadAttribute, value: m.codePadding, range: styleRange)
            }
        }
    }

    /// Give a fenced block's opening and closing fence lines the height of the
    /// code box's vertical padding. Concealed (caret away) they draw nothing,
    /// so what is left is exactly `pre { padding: 16px }`; revealed, the fence
    /// is there to edit.
    private static func applyFenceBand(block: Block, closed: Bool, lines: LineIndex,
                                       to target: NSMutableAttributedString,
                                       metrics m: GFMBoxMetrics) {
        let last = block.firstLine + block.lineCount - 1
        var fenceLines = [block.firstLine]
        if closed, last > block.firstLine { fenceLines.append(last) }
        // An unclosed fence with nothing under it — a note that ends in a bare
        // ``` , which is every fence for the moment between typing it and
        // typing the next line — is an *empty* `<pre>`, and GitHub draws that
        // at its full 32pt of padding rather than at 16. There is no closing
        // delimiter to carry the bottom padding and no listing line for
        // `padCodeLine` to grow, so the one line the block has holds both. Only
        // a fence: `$$` is `mathBlock` through the same call, and an unclosed
        // one draws no box at all in the Preview this is measured against.
        var whole = false
        if case .fencedCode = block.kind { whole = !closed && block.lineCount == 1 }
        for lineNumber in fenceLines {
            let range = lines.lineRange(lineNumber)
            guard range.length > 0, range.location + range.length <= target.length else { continue }
            let band = NSMutableParagraphStyle()
            band.minimumLineHeight = whole ? 2 * m.codePadding : m.codePadding
            band.maximumLineHeight = band.minimumLineHeight
            band.firstLineHeadIndent = m.codePadding
            band.headIndent = m.codePadding
            band.tailIndent = -m.codePadding
            target.addAttribute(.paragraphStyle, value: band, range: range)
        }
    }

    /// The last line of `block` that carries content — trailing blank lines
    /// belong to the parser's block, not to the rendered box.
    private static func lastContentLine(of block: Block, lines: LineIndex, text: NSString) -> Int {
        let first = block.firstLine
        var line = first + block.lineCount - 1
        while line > first, BlockBoxes.isBlankLine(line, text: text, lines: lines) { line -= 1 }
        return line
    }

    /// Collapse a run of lines that the source has and the rendered document
    /// does not — a setext underline, the blank lines the parser leaves inside
    /// an indented code block — into `total` points, shared between them.
    ///
    /// Those lines are the natural place to *put* the block's trailing margin,
    /// exactly as an ordinary blank run holds the margin between two
    /// paragraphs. Collapsing them to a hairline and adding the margin
    /// separately left the hairline over, which is a fraction of a point of
    /// drift for every such block.
    ///
    /// The floor is `collapsedLine` and not `minimumBlankLine`, which is the
    /// difference between the two constants doing its job: these are lines of
    /// *source the reader never sees*, not blank lines the writer typed, so
    /// where there is no margin to hold they hold nothing. It only ever binds
    /// at the end of the note — anywhere else the margin being shared out is
    /// larger than either floor — and there it was 0.5pt of page below the
    /// last thing the page paints, once per line the parser had swept into the
    /// block.
    private static func collapseLines(from firstLine: Int, through lastLine: Int,
                                      total: CGFloat, lines: LineIndex,
                                      to target: NSMutableAttributedString) {
        guard lastLine >= firstLine else { return }
        let each = max(BlockBoxes.collapsedLine, total / CGFloat(lastLine - firstLine + 1))
        for lineNumber in firstLine...lastLine {
            let range = lines.lineRange(lineNumber)
            guard range.length > 0, range.location + range.length <= target.length else { continue }
            let flat = NSMutableParagraphStyle()
            flat.minimumLineHeight = each
            flat.maximumLineHeight = each
            target.addAttribute(.paragraphStyle, value: flat, range: range)
        }
    }

    /// Give a code block's first or last line the box's vertical padding.
    ///
    /// The two halves are not symmetrical, and that is the whole of it.
    /// **Top padding is line height**: TextKit puts a pinned line's spare
    /// height above the glyphs, so growing the line puts the space exactly
    /// where `padding-top` goes. **Bottom padding is not**, and cannot be:
    /// growing the line puts that space above the glyphs too.
    ///
    /// The repair here used to be a negative `.baselineOffset` "lifting the
    /// glyphs off" the extra height — and that moves the *reported* baseline
    /// and not the ink, so the two cancelled and the listing sat hard against
    /// the bottom of its box. Measured on a 2× dump: a 20pt change to the
    /// value moved the glyph zero pixels. The space is reserved outside the
    /// line box instead, as `codeBottomPadAttribute`, which
    /// `RenderedBlockFragment` turns into `bottomMargin` and paints over. The
    /// box is the same height either way, which is why nothing that measures
    /// heights ever noticed.
    private static func padCodeLine(_ lineNumber: Int, top: Bool, bottom: Bool,
                                    style: NSParagraphStyle, lines: LineIndex,
                                    to target: NSMutableAttributedString,
                                    metrics m: GFMBoxMetrics) {
        let range = lines.lineRange(lineNumber)
        guard range.length > 0, range.location + range.length <= target.length else { return }
        let padded = (style.mutableCopy() as! NSMutableParagraphStyle)
        padded.minimumLineHeight = m.codeLineHeight + (top ? m.codePadding : 0)
        padded.maximumLineHeight = padded.minimumLineHeight
        target.addAttribute(.paragraphStyle, value: padded, range: range)
        if bottom {
            target.addAttribute(codeBottomPadAttribute, value: m.codePadding, range: range)
        }
    }

    /// Mark each line of a code block with its position in the box, so the
    /// fragment that paints `pre`'s background knows which corners to round.
    private static func applyCodeBand(block: Block, through end: Int? = nil, lines: LineIndex,
                                      to target: NSMutableAttributedString) {
        let first = block.firstLine, last = end ?? (block.firstLine + block.lineCount - 1)
        for lineNumber in first...last {
            let range = lines.lineRange(lineNumber)
            guard range.length > 0, range.location + range.length <= target.length else { continue }
            let position = first == last ? 3 : (lineNumber == first ? 0 : (lineNumber == last ? 2 : 1))
            target.addAttribute(codeBandAttribute, value: position, range: range)
        }
    }

    /// `hr` is a 4pt bar, not a line of text: the `---` collapses to the bar's
    /// height and the fragment fills it, unless the caret is on the line, when
    /// the source comes back at its natural height to be edited.
    private static func applyThematicBreak(block: Block, lines: LineIndex,
                                           to target: NSMutableAttributedString,
                                           theme: EditorTheme, revealedLines: Set<Int>) {
        let range = lines.lineRange(block.firstLine)
        guard range.length > 0, range.location + range.length <= target.length else { return }
        guard !revealedLines.contains(block.firstLine) else { return }
        let m = theme.metrics
        let bar = NSMutableParagraphStyle()
        bar.minimumLineHeight = m.ruleThickness
        bar.maximumLineHeight = m.ruleThickness
        target.addAttributes([
            .paragraphStyle: bar,
            .font: theme.concealed,
            .foregroundColor: PlatformColor.clear,
            thematicBreakAttribute: m.ruleThickness,
        ], range: range)
    }

    /// Per-line gutter bars for a plain (non-callout) blockquote — one bar per
    /// `>` nesting level, with the text indented to clear them. Called from
    /// the main loop, which has the line index.
    static func applyQuoteBars(
        for block: Block, lines: LineIndex, text: NSString,
        to target: NSMutableAttributedString, theme: EditorTheme,
        revealedLines: Set<Int> = [], unrendered: [NSRange] = [],
        opensDocument: Bool = false, insideListItem: Bool = false,
        listInset: CGFloat = 0
    ) {
        guard case .blockquote(nil) = block.kind else { return }
        // An empty quote is a box of no height (see `BlockBoxes.emptyQuote`);
        // there is nothing to put a bar beside, and the base style has already
        // collapsed it. Reveal brings the `>` back at its natural height.
        let firstLine = block.firstLine, lastLine = block.firstLine + block.lineCount - 1
        if BlockBoxes.isEmptyQuote(block, text: text, unrendered: unrendered),
           !(firstLine...lastLine).contains(where: { revealedLines.contains($0) }) { return }
        let m = theme.metrics
        let first = block.firstLine, last = block.firstLine + block.lineCount - 1

        // A blockquote has a box model *inside* it: its paragraphs are 16 apart
        // and a nested quote is a box of its own. The editor treated every line
        // of a quote as one more line of text, so a `>`-only line stood a full
        // 24pt line high where CSS leaves a 16pt margin, and a nested quote
        // opened flush against the paragraph above it instead of 16 below.
        struct QuoteLine {
            var depth = 0
            var isBlank = false
            var content = NSRange(location: 0, length: 0)
            var marker = NSRange(location: 0, length: 0)
            /// Indent of the content in columns, past the `>` markers — four
            /// or more makes it an indented code block *inside* the quote.
            var contentIndent = 0
            /// ATX heading level of the content, when the quote holds one.
            /// A blockquote contains *blocks*, and `> # Foo` is an `<h1>` in
            /// the rendered page — not a quoted line of body text, which is
            /// what it was here: the whole quote stood 43pt short of Preview.
            var heading: Int?
            /// The `#`s and the space after them, which conceal like any
            /// other heading's marker.
            var headingMarker = NSRange(location: 0, length: 0)
            /// A code-fence run at the head of the content — ``` or ~~~ — with
            /// the character, how many of it, and whether the rest of the line
            /// is blank. `bare` is the difference between the two ends of a
            /// fence: an opening one may carry an info string, a closing one
            /// may not, so `> ```swift` closes nothing.
            var fence: (marker: unichar, count: Int, bare: Bool)?
        }
        var parsed: [QuoteLine] = []
        parsed.reserveCapacity(last - first + 1)
        for lineNo in first...last {
            let line = lines.contentRange(lineNo, in: text)
            var i = line.location
            let end = line.location + line.length
            var info = QuoteLine()
            while i < end, text.character(at: i) == 0x20 { i += 1 }
            while i < end, text.character(at: i) == 0x3E {   // '>'
                info.depth += 1; i += 1
                if i < end, text.character(at: i) == 0x20 { i += 1 }
            }
            info.marker = NSRange(location: line.location, length: i - line.location)
            info.content = NSRange(location: i, length: end - i)
            // Whitespace only is still blank: `>  ` and `> ` are the same
            // empty quote line as `>`, and counting their trailing spaces as
            // content left them standing as lines of text.
            var onlySpace = true
            for k in info.content.location..<(info.content.location + info.content.length) {
                let ch = text.character(at: k)
                if ch != 0x20 && ch != 0x09 && ch != 0x0D { onlySpace = false; break }
            }
            info.isBlank = onlySpace
            var k = info.content.location, column = 0
            while k < end {
                let ch = text.character(at: k)
                if ch == 0x20 { column += 1 } else if ch == 0x09 { column += 4 - (column % 4) } else { break }
                k += 1
            }
            info.contentIndent = column
            // The fence run, measured from the first non-space of the content.
            // A backtick fence whose info string contains a backtick is not a
            // fence at all (CommonMark §4.5), which is what keeps `> ``a`b` `
            // — an inline code span with two of them — out of the code box.
            if k < end {
                let marker = text.character(at: k)
                if marker == 0x60 || marker == 0x7E {            // ` or ~
                    var run = 0, j = k
                    while j < end, text.character(at: j) == marker { run += 1; j += 1 }
                    var bare = true, backtick = false
                    var t = j
                    while t < end {
                        let c = text.character(at: t)
                        if c == 0x60 { backtick = true }
                        if c != 0x20 && c != 0x09 && c != 0x0D { bare = false }
                        t += 1
                    }
                    if run >= 3, !(marker == 0x60 && backtick) {
                        info.fence = (marker, run, bare)
                    }
                }
            }
            // `#`…`#` then a space, up to six, exactly as `LineCursor` reads an
            // ATX heading at the top level.
            var h = i, level = 0
            while h < end, text.character(at: h) == 0x23, level < 7 { level += 1; h += 1 }
            if level >= 1, level <= 6, h == end || text.character(at: h) == 0x20 {
                while h < end, text.character(at: h) == 0x20 { h += 1 }
                info.heading = level
                info.headingMarker = NSRange(location: i, length: h - i)
            }
            parsed.append(info)
        }

        // The deepest nesting reached since the last blank line. A box opens
        // only when a line goes deeper than the paragraph has been — once it is
        // continuing lazily, `>>> foo` / `> bar` / `>>baz` is one paragraph and
        // none of its markers start anything.
        var deepestInParagraph: [Int] = []
        var runningMax = 0
        for info in parsed {
            if info.isBlank { runningMax = 0 } else { runningMax = max(runningMax, info.depth) }
            deepestInParagraph.append(runningMax)
        }

        // A container stack for the quote's interior — the one piece of state
        // this pass never had.
        //
        // Everything above reads a quote line on its own: is it blank, how deep
        // is it, does it start with `#`. That is enough for a heading and for a
        // paragraph, and wrong for every construct whose meaning is carried by
        // the line *above* it. Two of them:
        //
        //  * A fenced code block. `> aaa` is a line of prose or a line of a
        //    listing depending only on whether a `> ``` ` came before it, and
        //    with no memory the styler had to guess prose — so a quoted code
        //    block was quoted body text, 4pt short per line and 32pt short of
        //    the `pre`'s padding.
        //  * A list item. `>>     two` is four columns of indent, which reads
        //    as an indented code block until you know an item opened at column
        //    four above it — and then it is that item's own paragraph. The test
        //    was `contentIndent >= 4` against nothing, so #237 drew a 52pt code
        //    box over a 24pt line of prose.
        //
        // It is a stack and it belongs here rather than in `BlockParser`. The
        // parser's blocks are a flat, non-overlapping tiling of the document,
        // and that shape cannot express a reopened container at all — the probe
        // that tried came back with two `listItem` blocks both starting at line
        // 0 and the inner content dropped. What a quote's interior needs is far
        // smaller than that: one open fence and the columns of the items open
        // inside it, never deeper than the quote itself, and dead the moment
        // this function returns.

        /// What the code box makes of a quote line.
        enum Interior: Equatable {
            case none
            /// A fence delimiter: the box's padding, and nothing else. The page
            /// draws no ``` at all, so caret-away the line *is* `pre`'s
            /// `padding: 16px` — the same trade `applyFenceBand` makes at the
            /// top level.
            case delimiter(band: Int, paddings: Int)
            /// A line of the listing.
            case listing(band: Int, paddings: Int)
        }
        var interior = [Interior](repeating: .none, count: parsed.count)
        /// The content column of the innermost list item open at each line —
        /// the column an indented code block inside the quote has to clear.
        var itemColumns = [Int](repeating: 0, count: parsed.count)

        /// Where a list item's content starts, in columns past the quote's own
        /// content, or nil when the line opens no item.
        ///
        /// CommonMark's rule, not the marker's width: the content column is
        /// past the marker and the spaces after it, *unless* there are five or
        /// more, when the run is an indented code block starting one column
        /// past the marker and the item's content column is that.
        func itemContentColumn(_ info: QuoteLine) -> Int? {
            guard let marker = quoteListMarker(info.content, in: text) else { return nil }
            let afterMarker = marker.range.location + marker.range.length - 1   // before its space
            var i = afterMarker, spaces = 0
            let end = info.content.location + info.content.length
            while i < end, text.character(at: i) == 0x20 { spaces += 1; i += 1 }
            let base = afterMarker - info.content.location
            return spaces >= 5 ? base + 1 : base + spaces
        }

        /// The margin CSS puts **above** an item this line opens, named rather
        /// than measured, because looseness is not known until the whole quote
        /// has been walked.
        ///
        /// A blockquote's interior had no list box model at all: the gutter
        /// pass gave a gap for a deeper nested quote and for a heading, and
        /// nothing else, so `> - one` / `> - two` stood 4pt short of `li + li`
        /// and every extra item cost another 4. A quote with a list in it is
        /// half the meeting notes anyone writes; the corpus has quoted lists
        /// but never two items and a paragraph in the same quote, which is the
        /// shape that makes the missing margin add up.
        enum ItemGap: Equatable {
            case none
            /// Another item of the same list: `li + li`, or `li > p` where the
            /// list is loose.
            case sibling(list: Int)
            /// The first item of a list opening inside the item above it.
            /// `ul ul { margin-top: 0 }` — unless a `<p>` on either side of the
            /// boundary supplies one, which is `ListItemTop.opensNestedList`.
            case nested(parent: Int, child: Int)
            /// A list starting next to something that is not its own sibling —
            /// after a paragraph, or after a list written with another marker.
            /// Two boxes, so the block margin.
            case newList
        }
        /// An item open on the stack: where its content starts, the column its
        /// marker was written at, the marker itself (a `1.` after a `-` starts
        /// a *new* list, per CommonMark), and which list it belongs to.
        struct OpenItem {
            var content: Int
            var markerIndent: Int
            var token: unichar
            var list: Int
        }
        /// Which lines open an item, and the margin each one takes.
        var itemGap = [ItemGap](repeating: .none, count: parsed.count)
        /// How many list items are open at each line — blank lines included,
        /// because a blank line is where the question gets asked.
        var openItemsAt = [Int](repeating: 0, count: parsed.count)
        /// Looseness, per list found inside this quote. A loose list wraps
        /// every item's text in a `<p>`, and that `<p>`'s margin is 16 where a
        /// tight item's is 4.
        var listIsLoose: [Bool] = []

        /// What distinguishes one list from the next: the bullet character, or
        /// an ordered list's delimiter. `*` after `-` is a second list and so
        /// is `1)` after `1.`, and CSS then puts a whole block margin between
        /// them rather than `li + li`'s four points.
        func markerToken(_ marker: (range: NSRange, ordered: Bool, width: CGFloat)) -> unichar {
            let last = marker.range.location + marker.range.length - 2   // before its space
            return text.character(at: marker.ordered ? max(marker.range.location, last)
                                                     : marker.range.location)
        }

        /// Can this line start a block of its own?
        ///
        /// Only if it carries a `>`. A quote line with none is a **lazy
        /// continuation** — the paragraph above running on — and the rest of
        /// this pass already knows that: the gutter loop skips `depth == 0`
        /// outright. Spec #216 is `> foo` / `    - bar`, where the second line
        /// is four columns of paragraph text that happens to begin with a
        /// dash, and reading it as a list put a block margin between two lines
        /// of one sentence. The stack itself is left alone — what column the
        /// line sits at is a separate question, asked by the code-box ruler,
        /// and this only decides whether a *margin* opens above it.
        func opensABox(_ info: QuoteLine) -> Bool { info.depth > 0 }

        var openFence: (marker: unichar, count: Int, at: Int)?
        var listColumns: [OpenItem] = []
        /// The stack depth at the last blank line, waiting to be attributed.
        ///
        /// Deferred rather than applied where it is found, because a blank line
        /// only loosens a list that **continues past it**: `> - one` /
        /// `> - two` / `>` / `> Trailer.` ends its list at the blank, and
        /// marking the list loose there would have put 16pt between two items
        /// the page separates by four. Attributed on the next line that is
        /// still inside the list, which is the only place the question can be
        /// answered.
        var blankDepth: Int? = nil
        for (offset, info) in parsed.enumerated() {
            openItemsAt[offset] = listColumns.count
            // A line inside an open fence is still inside whatever list item
            // the fence was written in — the whole box takes the item's indent,
            // padding rows included. Left at zero, the listing moved right and
            // the two 16pt padding bands did not, so the panel had a notch cut
            // out of its left side exactly the width of the list indent.
            itemColumns[offset] = listColumns.last?.content ?? 0
            if let open = openFence {
                // A blank line does not close a fence — it is a blank line of
                // the listing — and neither does a shorter run or the other
                // fence character.
                if let d = info.fence, d.bare, d.marker == open.marker,
                   d.count >= open.count, info.contentIndent < 4 {
                    interior[offset] = .delimiter(band: 2, paddings: 1)
                    openFence = nil
                } else {
                    interior[offset] = .listing(band: 1, paddings: 0)
                }
                continue
            }
            // A blank line does *not* close an item — it only makes the list
            // loose. The item ends where a line is written shallower than its
            // content column, blank line or no, which is what the pop below
            // does. Clearing the stack here instead is what left #237's own
            // continuation looking like an indented code block: the `>>` in the
            // middle threw away the column the item had opened at.
            guard !info.isBlank else { blankDepth = listColumns.count; continue }
            var popped: OpenItem? = nil
            while let top = listColumns.last, info.contentIndent < top.content {
                popped = listColumns.removeLast()
            }
            let column = listColumns.last?.content ?? 0
            itemColumns[offset] = column
            // Four columns past the *item's* content is an indented code block,
            // and an indented code block swallows a fence rather than opening
            // one.
            guard info.contentIndent < column + 4 else { continue }
            if let d = info.fence {
                openFence = (d.marker, d.count, offset)
                interior[offset] = .delimiter(band: 0, paddings: 1)
                continue
            }
            if info.heading == nil, let opened = itemContentColumn(info),
               let marker = quoteListMarker(info.content, in: text) {
                let token = markerToken(marker)
                // Already absolute within the quote's content — it is measured
                // from `content.location` and so counts the marker's own indent
                // — so adding the enclosing item's column would count that
                // indent twice, and a nested item's code column would come back
                // one too deep for every level of nesting.
                if let previous = popped, previous.markerIndent == info.contentIndent,
                   previous.token == token {
                    // The same list continuing. A blank line seen while that
                    // item was the innermost one open is a blank line *between
                    // two items*, which is what loose means.
                    if blankDepth == listColumns.count + 1 { listIsLoose[previous.list] = true }
                    itemGap[offset] = opensABox(info) ? .sibling(list: previous.list) : .none
                    listColumns.append(OpenItem(content: opened, markerIndent: info.contentIndent,
                                                token: token, list: previous.list))
                } else {
                    listIsLoose.append(false)
                    let list = listIsLoose.count - 1
                    if let parent = listColumns.last, popped == nil {
                        // A blank line above a *nested* list is the third way
                        // to be loose, and the one the other two miss: the
                        // parent item then directly holds a paragraph and a
                        // list with a gap between them. `> - one` / `>` /
                        // `>   - deep` / `> - two` is the shape, and without
                        // this the item after the nested list took `li + li`'s
                        // four points where the page gives it sixteen.
                        if blankDepth == listColumns.count { listIsLoose[parent.list] = true }
                        itemGap[offset] = opensABox(info)
                            ? .nested(parent: parent.list, child: list) : .none
                    } else {
                        itemGap[offset] = opensABox(info) ? .newList : .none
                    }
                    listColumns.append(OpenItem(content: opened, markerIndent: info.contentIndent,
                                                token: token, list: list))
                }
            } else if let top = listColumns.last, blankDepth == listColumns.count {
                // Not an item, still inside one, and a blank line above it: the
                // item directly holds two blocks with a gap between them, which
                // is CommonMark's other way of being loose.
                listIsLoose[top.list] = true
            }
            openItemsAt[offset] = listColumns.count
            blankDepth = nil
        }

        /// Is the list that was open above line `k` still open at it?
        ///
        /// The question a blank run has to answer before it can know what
        /// margin it is holding. Between two items the gap is the loose item's
        /// own `<p>` margin; past the last item it is the **list's**, and those
        /// are two different numbers whenever the list sits inside another
        /// list.
        func listContinues(at k: Int) -> Bool {
            guard k < parsed.count else { return false }
            if itemColumns[k] > 0 { return true }
            if case .sibling = itemGap[k] { return true }
            return false
        }
        /// Whether the quote opens with a **loose** list — the one construct
        /// inside a quote with a margin that escapes it.
        ///
        /// A loose `<li>` wraps its own text in a `<p>`, and that paragraph's
        /// `margin-top` collapses straight out through the `<li>`, the `<ul>`
        /// and the `<blockquote>`: none of the three has padding or a border on
        /// that edge to stop it, and `blockquote > :first-child` zeroes the
        /// *list's* top margin, not the paragraph's. Anywhere but the top of
        /// the note that margin meets the one below whatever precedes the quote
        /// and disappears into it, which is why this is invisible until the
        /// quote is the first thing in the document — and then the page simply
        /// starts 16pt lower than the editor did.
        ///
        /// A dedicated scan rather than a flag kept by the pass above, because
        /// the only list whose looseness anyone here needs is the one that
        /// opens the quote, and answering it in general means tracking list
        /// *identity* — which sibling marker belongs to which `<ul>` — for a
        /// question nothing else asks.
        func opensALooseList() -> Bool {
            guard let column = itemContentColumn(parsed[0]) else { return false }
            let markerIndent = parsed[0].contentIndent
            var blankSeen = false
            for info in parsed.dropFirst() {
                if info.isBlank { blankSeen = true; continue }
                // Still the same list: a continuation indented to the item's
                // content, or a sibling marker written at the item's own
                // indent. Anything shallower has ended it, and a blank line
                // before *that* leaves the list tight.
                let continues = info.contentIndent >= column
                    || (info.contentIndent == markerIndent && itemContentColumn(info) != nil)
                guard continues else { return false }
                if blankSeen { return true }
            }
            return false
        }
        let escapingTopMargin = opensDocument && opensALooseList()

        // A fence that never closes ends with the quote, exactly as one at the
        // top level ends with the note. Its bottom padding has no delimiter to
        // sit on, so the listing's last line holds it — and a fence with no
        // listing at all holds both paddings itself, which is the empty `<pre>`
        // GitHub draws for a quote that is nothing but `> ``` `.
        if let open = openFence {
            if open.at == parsed.count - 1 {
                interior[open.at] = .delimiter(band: 3, paddings: 2)
            } else {
                interior[parsed.count - 1] = .listing(band: 2, paddings: 1)
            }
        }

        for (offset, info) in parsed.enumerated() {
            let lineNo = first + offset
            // A **lazy continuation** carries no `>` of its own and is still
            // inside the quote: `> A long quoted line` over an unprefixed
            // second line is one quoted paragraph, and the page puts the bar
            // beside both and the padding either side of both. Skipped for its
            // missing marker, the line was laid out at the full pane width —
            // narrower in Preview by the gutter and both paddings, so it fitted
            // more per line and the quote came out a whole line short. Nothing
            // at 800pt shows it, because a corpus example never wraps; a real
            // note wrapped at 640 and lost 24pt.
            let depth = info.depth > 0 ? info.depth : deepestInParagraph[offset]
            guard depth > 0 else { continue }
            let lineRange = lines.lineRange(lineNo)
            guard lineRange.length > 0,
                  lineRange.location + lineRange.length <= target.length else { continue }

            let para = (target.attribute(.paragraphStyle, at: lineRange.location,
                                         effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()

            // How far past the quote's bars this line's box starts. Set by the
            // two code branches below and added to the gutter inset at the
            // bottom — the code box is `pre`, and `pre` has 16pt of padding on
            // its left as well as its top. It used to be added to the paragraph
            // style directly, which did nothing at all: the gutter block down
            // there *assigns* both indents from the quote's nesting, so the
            // `+=` was overwritten a dozen lines later and the code band was
            // painted straight through the quote's own bar.
            var codeInset: CGFloat = 0
            let box = interior[offset]

            if box != .none {
                // Inside a code box nothing else applies: a blank line is a
                // blank line of the listing rather than a margin, and a `#` or
                // a `-` is a character of the program.
            } else if info.isBlank {
                // The `>` on its own is the margin between two paragraphs of
                // the quote, exactly as a bare blank line is between two
                // paragraphs of the document. Shared out if the writer left
                // more than one.
                var run = 1
                var back = offset - 1
                while back >= 0, parsed[back].isBlank { run += 1; back -= 1 }
                var ahead = offset + 1
                while ahead < parsed.count, parsed[ahead].isBlank { run += 1; ahead += 1 }
                // Only a run *between* two paragraphs is a margin. A `>` line
                // opening or closing the quote separates nothing — the quote's
                // own margin is already outside it — so it collapses, exactly
                // as a leading or trailing blank line does in the document.
                let separates = back >= 0 && ahead < parsed.count
                // What the run is holding is the **collapsed margin between
                // the two boxes it separates**, not a constant. It was
                // `blockGap` for every run in every quote, which is right for
                // the ordinary paragraph-to-paragraph gap and wrong at both
                // ends of it.
                //
                // Below: a heading's `margin-top` is 24, not 16, so every
                // `>` / `> ## Head` in the corpus stood 8pt short — in a quote
                // only, because at the top level `BlockBoxes.gapBetween`
                // already asks this question properly.
                //
                // Above: a list's `margin-bottom` is **zero inside a list
                // item**, because github-markdown-css writes `ol ul { margin:
                // 0 }` with a descendant combinator — so a `<ul>` in a
                // `<blockquote>` in an `<li>` matches it just as a directly
                // nested one does. The page really does draw no gap there, and
                // the editor drew 16: `1.` / a quote / a list in it / a
                // paragraph after the list is a numbered how-to step, and 28's
                // two of them were 32pt tall between them. Only when the run
                // *ends* the list — between two items of a loose one the gap
                // is `li > p`'s 16, which nothing zeroes.
                let endsAList = openItemsAt[offset] > 0 && !listContinues(at: ahead)
                let above = (endsAList && insideListItem) ? 0 : m.blockGap
                let below = ahead < parsed.count && parsed[ahead].heading != nil
                    ? m.headingTopGap : 0
                let total = max(above, below)
                let each = separates && total > 0
                    ? max(BlockBoxes.minimumBlankLine, total / CGFloat(run))
                    : BlockBoxes.collapsedLine
                para.minimumLineHeight = each
                para.maximumLineHeight = each
                // An interior run *is* the margin, so it carries no spacing of
                // its own. A closing one is the block's last line, and that is
                // where `applyBase` put the quote's own bottom margin — zeroing
                // it there deleted the gap between the quote and what follows.
                if separates && total > 0 { para.paragraphSpacing = 0 }
                // This line is a margin, not a line of text: the half-leading
                // the block's style carries below every text line has no place
                // on it, and left there it made the gap inside a quote a
                // half-leading too tall.
                para.lineSpacing = 0
            } else if offset + 1 < parsed.count {
                // A change of nesting starts a new box, and CSS puts the block
                // gap between them. A blank line between the two is already
                // holding that gap, so it is not added twice.
                let next = parsed[offset + 1]
                // A lazily continued line carries no `>` of its own (depth 0)
                // and is the *same* paragraph running on, not a new box — so it
                // opens no gap. Comparing depths alone made every lazy
                // continuation look like a change of nesting and put a block
                // margin inside a single quoted paragraph.
                // Only a *deeper* line opens a new box. Fewer markers than the
                // line above is lazy continuation — a continuation line may
                // carry no `>` at all, so carrying fewer is no different — and
                // treating every change of depth as a new block put a margin
                // through the middle of one quoted paragraph.
                var internalGap = (!next.isBlank
                                   && next.depth > deepestInParagraph[offset]) ? m.blockGap : 0
                // A heading is a box inside the quote, and boxes are separated
                // by the block margin. The margin only: an h1/h2's rule is
                // `padding-bottom` plus a border, it lives *inside* the
                // heading, and the heading's own fragment reserves it now
                // (`headingRuleAttribute`, below). Added here as well it was
                // the same space twice — and it was only ever added when
                // another line of the quote followed, so a heading that closed
                // a quote, or one with a blank quote line under it, got the
                // padding nowhere at all and the note stood an inset short.
                if info.heading != nil, !next.isBlank {
                    internalGap = max(internalGap, m.blockGap)
                }
                // …and a list item below is a box too. Resolved here rather
                // than in the pass that found it, because looseness is a
                // property of the whole list and the last item can be the one
                // that settles it: `> - a` / `> - b` / `>` / `> - c` is loose,
                // and the margin above `b` is 16 on the strength of a blank
                // line two lines further down.
                if !next.isBlank {
                    switch itemGap[offset + 1] {
                    case .none: break
                    case .sibling(let list):
                        internalGap = max(internalGap,
                                          listIsLoose[list] ? m.blockGap : m.listItemGap)
                    case .nested(let parent, let child):
                        // `ul ul { margin-top: 0 }`, and the 16 comes back only
                        // when a `<p>` on one side of the boundary carries it —
                        // the parent item's own text when *its* list is loose,
                        // this item's when *this* one is.
                        if listIsLoose[parent] || listIsLoose[child] {
                            internalGap = max(internalGap, m.blockGap)
                        }
                    case .newList:
                        internalGap = max(internalGap, m.blockGap)
                    }
                }
                para.paragraphSpacing = internalGap
                // Spacing *within* the quote is covered by the bar; the gap
                // below the whole quote is margin and is not.
                if internalGap > 0 {
                    target.addAttribute(quoteBarExtraAttribute, value: internalGap, range: lineRange)
                }
            }

            // Source the reader never sees — a reference definition inside the
            // quote. `applyBase` collapsed the line already; this pass rewrites
            // every quote line's style, so without the same knowledge it put
            // the definition straight back at full height.
            if box == .none, !info.isBlank, isUnrenderedContent(info.content, in: unrendered) {
                para.minimumLineHeight = BlockBoxes.collapsedLine
                para.maximumLineHeight = BlockBoxes.collapsedLine
                para.lineSpacing = 0
                target.addAttributes([
                    .font: theme.concealed,
                    .foregroundColor: PlatformColor.clear,
                    markerAttribute: true,
                ], range: lineRange)
                target.addAttribute(.paragraphStyle, value: para, range: lineRange)
                continue
            }

            // A list inside the quote — `> - item`. Its marker is a marker, not
            // two characters of prose: outside a quote the editor conceals it
            // and draws a disc, and inside one it was showing the raw `-`.
            var listExtra: (indent: CGFloat, firstLine: CGFloat)? = nil
            if box == .none, !info.isBlank, info.heading == nil,
               info.contentIndent < itemColumns[offset] + 4,
               let marker = quoteListMarker(info.content, in: text),
               !revealedLines.contains(lineNo) {
                // Recorded, not applied: the gutter-bar block below rewrites
                // the indents from the quote's nesting, so setting them here
                // would be undone. `ul { padding-left: 2em }` is added to that
                // — **once per level**, because that is what the stylesheet
                // does: a `<ul>` inside an `<li>` pads again. One level flat,
                // a nested item's text sat 32pt left of the page's, which is
                // invisible until the line is long enough to wrap and then
                // costs a whole line.
                let level = CGFloat(max(1, openItemsAt[offset]))
                listExtra = (m.listIndent * level,
                             marker.ordered ? m.listIndent * level - marker.width
                                            : m.listIndent * level)
                if !marker.ordered {
                    target.addAttributes([
                        .font: theme.concealed,
                        .foregroundColor: PlatformColor.clear,
                        markerAttribute: true,
                    ], range: marker.range)
                    target.addAttribute(listBulletAttribute, value: 0, range: marker.range)
                }
            }

            // …and a **continuation** line of a quoted item takes the same
            // indent — including the lines of a code box written under the
            // item's text. Neither carries a marker, so the branch above never
            // saw either, and both were laid out at the quote's own gutter:
            // the `<pre>` inside a quoted numbered step started at the quote
            // bar rather than under the item's text, a whole list indent to the
            // left of where the page draws it. Heights cannot see that at all —
            // it took the pictures.
            if listExtra == nil, !info.isBlank, info.heading == nil,
               itemColumns[offset] > 0, !revealedLines.contains(lineNo) {
                let level = m.listIndent * CGFloat(max(1, openItemsAt[offset]))
                listExtra = (level, level)
            }

            // Four columns past the *item's own content* is an indented code
            // block inside the quote — cmark nests a `<pre>` in the
            // `<blockquote>` and GitHub gives it the code box. The editor read
            // it as one more quoted line of prose, 28pt short of the box it
            // stands for.
            //
            // Four past the quote's bars was the wrong ruler the moment a list
            // opened inside one: `> > 1.  one` puts the item's content at
            // column four, so its own continuation `>>     two` is four columns
            // in and was read as a program.
            if box == .none, !info.isBlank,
               info.contentIndent >= itemColumns[offset] + 4, info.heading == nil,
               !revealedLines.contains(lineNo) {
                let column = itemColumns[offset] + 4
                let above = offset > 0 && !parsed[offset - 1].isBlank
                    && parsed[offset - 1].contentIndent >= column
                let below = offset + 1 < parsed.count && !parsed[offset + 1].isBlank
                    && parsed[offset + 1].contentIndent >= column
                let top = !above, bottom = !below
                para.minimumLineHeight = m.codeLineHeight + (top ? m.codePadding : 0)
                para.maximumLineHeight = para.minimumLineHeight
                codeInset = m.codePadding
                para.tailIndent = -m.codePadding
                // The code font goes on the *content*, not the whole line: the
                // `>` is the quote's marker and stays concealed. Set over the
                // line it came back as a monospaced `>` sitting inside the code
                // block, which is markup the reader never sees.
                target.addAttributes([
                    .font: theme.mono,
                    .foregroundColor: theme.text,
                ], range: info.content)
                target.addAttribute(codeBandAttribute,
                                    value: top && bottom ? 3 : (top ? 0 : (bottom ? 2 : 1)),
                                    range: lineRange)
                if bottom {
                    target.addAttribute(codeBottomPadAttribute, value: m.codePadding, range: lineRange)
                }
            }

            // A fenced code block inside the quote. The delimiters are the
            // box's 16pt padding and the lines between are the listing, exactly
            // as at the top level (`applyFenceBand` / `applyNestedCode`) — the
            // difference is only that nothing here knows where the block is
            // without the pass above.
            //
            // The box is laid out whether or not the caret is on the line, as
            // it is at the top level: a quote that grew and shrank by 8pt every
            // time the caret crossed its fence would be worse than one showing
            // its ``` . What reveal changes is the concealment, not the height.
            switch box {
            case .none:
                break
            case .delimiter(let band, let paddings):
                para.minimumLineHeight = CGFloat(paddings) * m.codePadding
                para.maximumLineHeight = para.minimumLineHeight
                para.lineSpacing = 0
                codeInset = m.codePadding
                para.tailIndent = -m.codePadding
                target.addAttribute(codeBandAttribute, value: band, range: lineRange)
                if revealedLines.contains(lineNo) {
                    target.addAttributes([.font: theme.mono,
                                          .foregroundColor: theme.secondary], range: info.content)
                } else {
                    target.addAttributes([
                        .font: theme.concealed,
                        .foregroundColor: PlatformColor.clear,
                        markerAttribute: true,
                    ], range: info.content)
                }
            case .listing(let band, let paddings):
                // The quote's own marker — the `>`s **and the item's indent
                // before them** — concealed again. `StyleSpec` hid it before
                // the cmark overlay ran, and `GFMLiveStyle.emitCodeBlock`
                // paints a `.codeBlock` run across the whole body of a fenced
                // block, markers included, at full size. So a listing inside a
                // quote inside a list item carried three visible columns of
                // indent and a `>` it should not have: crooked, and 3 characters
                // narrower than the page's column, which is a wrapped line at
                // any pane under about 520pt.
                // …and, past the markers, the enclosing item's own columns.
                // cmark strips those before the `<pre>` sees the line, so they
                // are markup: drawn, they pushed the listing three columns
                // right of the page's inside a box that starts in the right
                // place, and made the editor's code column that much narrower.
                var listing = info.content
                if !revealedLines.contains(lineNo) {
                    var i = info.content.location, column = 0
                    let end = info.content.location + info.content.length
                    while i < end, column < itemColumns[offset] {
                        let c = text.character(at: i)
                        if c == 0x20 { column += 1 } else if c == 0x09 { column += 4 - (column % 4) }
                        else { break }
                        i += 1
                    }
                    var hide = info.marker
                    hide.length = i - hide.location
                    if hide.length > 0 {
                        target.addAttributes([.font: theme.concealed,
                                              .foregroundColor: PlatformColor.clear,
                                              markerAttribute: true], range: hide)
                    }
                    // The listing itself starts past what was just hidden —
                    // set the code font over the whole content and the mono
                    // face goes straight back onto the columns.
                    listing = NSRange(location: i, length: end - i)
                }
                let bottom = CGFloat(paddings) * m.codePadding
                para.minimumLineHeight = m.codeLineHeight
                para.maximumLineHeight = para.minimumLineHeight
                para.lineSpacing = 0
                codeInset = m.codePadding
                para.tailIndent = -m.codePadding
                // The code font goes on the *content*, not the whole line: the
                // `>` is the quote's marker and stays concealed, and set over
                // the line it comes back as a monospaced `>` sitting inside the
                // listing — markup the reader never sees.
                if listing.length > 0 {
                    target.addAttributes([
                        .font: theme.mono,
                        .foregroundColor: theme.text,
                    ], range: listing)
                }
                target.addAttribute(codeBandAttribute, value: band, range: lineRange)
                // The padding an unclosed fence leaves on its last line, below
                // the line box — the same `codeBottomPadAttribute` the top
                // level's `padCodeLine` and the list item's `applyNestedCode`
                // use, deliberately, so that one repair fixes all four.
                if bottom > 0 {
                    target.addAttribute(codeBottomPadAttribute, value: bottom, range: lineRange)
                }
            }

            // The heading's own box: its line height, its font, and its
            // concealed `#` marker.
            if box == .none, let level = info.heading, !revealedLines.contains(lineNo) {
                let height = m.headingLineHeight(level)
                para.minimumLineHeight = height
                para.maximumLineHeight = height
                let content = NSRange(location: info.headingMarker.location + info.headingMarker.length,
                                      length: info.content.location + info.content.length
                                              - info.headingMarker.location - info.headingMarker.length)
                if content.length > 0, content.location + content.length <= target.length {
                    target.addAttributes([
                        .font: theme.headingFont(level: level),
                        .foregroundColor: theme.headingColor(level: level),
                    ], range: content)
                    // Glyphs sit centred in the line box, as everywhere else.
                    let lift = BlockBoxes.halfLeading(.heading(level: level), theme: theme)
                    if lift > 0 {
                        target.addAttribute(.baselineOffset, value: -lift, range: content)
                    }
                }
                if info.headingMarker.length > 0,
                   info.headingMarker.location + info.headingMarker.length <= target.length {
                    target.addAttributes([
                        .font: theme.concealed,
                        .foregroundColor: PlatformColor.clear,
                        markerAttribute: true,
                    ], range: info.headingMarker)
                }
                // …and an h1/h2 inside a quote draws the same rule an h1/h2
                // draws anywhere. The mark goes on the line's *first*
                // character, which here is the `>` — that is where the
                // fragment looks, and a quote line is a paragraph of its own,
                // so one line is one fragment. Without it the quote pass was
                // the only place in the editor that styled a heading and never
                // asked for its border; the page drew one there and no height
                // gate could see the difference, because the space the border
                // needs was being folded into the gap below instead.
                if level <= 2, lineRange.length > 0 {
                    target.addAttribute(headingRuleAttribute, value: level,
                                        range: NSRange(location: lineRange.location, length: 1))
                }
            }

            // The bar and the indent are per line, and so is the decision to
            // draw them: a line showing its raw `>` sits at its natural indent
            // with no bar, while every other line of the quote keeps its bar.
            if !revealedLines.contains(lineNo) {
                target.addAttribute(calloutTintAttribute, value: theme.secondary, range: lineRange)
                target.addAttribute(blockquotePlainAttribute, value: depth, range: lineRange)
                // `blockquote { border-left: .25em; padding: 0 1em }` — one such
                // step per `>` of nesting, so the text clears every bar. Plus
                // the code box's own `padding-left` when this line is inside
                // one: `drawCodeBand` reads the band's left edge back off
                // `headIndent`, so a code box that did not declare it here was
                // painted over the quote's bar.
                let inset = listInset + CGFloat(depth) * m.quoteIndent + codeInset
                para.firstLineHeadIndent = inset + (listExtra?.firstLine ?? 0)
                para.headIndent = inset + (listExtra?.indent ?? 0)
                // `blockquote { padding: 0 1em }` is padding on **both** sides,
                // and only the left one was ever applied — so a quoted line ran
                // to the pane's right edge, 16pt per nesting level wider than
                // the page gives it. Invisible at any width where nothing wraps,
                // which is every width the corpus is swept at: it takes a real
                // document and a narrow pane for a line to fit in Edit and not
                // in Preview. `tailIndent` is measured from the container's
                // right edge, hence negative.
                //
                // **Added to** whatever the code branches above reserved, not
                // chosen instead of it. A `pre` inside a blockquote is inset by
                // the quote's padding *and* by its own, and taking only the
                // larger of the two left a quoted listing 16pt wider than the
                // page's — two characters, i.e. one wrapped line on a 500pt
                // pane and nothing at all on an 800pt one.
                let codeTail = -para.tailIndent
                para.tailIndent = -(CGFloat(depth) * m.quotePadding + codeTail)
            }
            if offset == 0, escapingTopMargin {
                // The fragment's own `topMargin`, not the line height and not
                // `paragraphSpacingBefore`: TextKit drops the latter on the
                // document's first paragraph, which is the only place this is
                // ever needed, and a line height is per **wrapped visual
                // line** — so an opening item long enough to wrap paid the
                // margin once per line. This file styles without knowing the
                // pane's width, so nothing here could notice; a 560pt sweep of
                // whole documents did. Same repair, same attribute, as the one
                // inside a list item.
                target.addAttribute(openingMarginAttribute, value: m.blockGap,
                                    range: NSRange(location: lineRange.location, length: 1))
            }
            target.addAttribute(.paragraphStyle, value: para, range: lineRange)
        }
    }

    /// Obsidian-style callout tint + SF Symbol per `[!type]`.
    static func calloutStyle(for type: String, theme: EditorTheme) -> (PlatformColor, String) {
        switch type {
        case "tip", "hint", "important":
            return (.systemTeal, "flame")
        case "warning", "caution", "attention":
            return (.systemOrange, "exclamationmark.triangle")
        case "danger", "error", "bug", "failure", "fail", "missing":
            return (.systemRed, "xmark.octagon")
        case "success", "check", "done":
            return (.systemGreen, "checkmark.circle")
        case "question", "help", "faq":
            return (.systemYellow, "questionmark.circle")
        case "example":
            return (.systemPurple, "list.bullet")
        case "quote", "cite":
            return (theme.secondary, "quote.opening")
        case "abstract", "summary", "tldr":
            return (.systemTeal, "text.alignleft")
        default: // note, info, …
            return (theme.accent, "pencil.circle")
        }
    }

    private static func apply(
        _ run: StyleRun,
        to target: NSMutableAttributedString,
        theme: EditorTheme,
        revealed: Bool,
        resolveWiki: WikiResolver?
    ) {
        let range = run.range
        guard range.length > 0, range.location + range.length <= target.length else { return }

        // Concealment beats everything: markers vanish when inactive.
        if run.concealment == .whenInactive && !revealed {
            target.addAttributes([
                .font: theme.concealed,
                .foregroundColor: PlatformColor.clear,
                markerAttribute: true,
            ], range: range)
            return
        }

        switch run.role {
        case .body:
            break   // base already applied

        case .htmlSource:
            // Raw HTML, shown only while the caret is in it. Set like code so
            // the tags read as the markup they are rather than as prose.
            target.addAttributes([
                .font: theme.monoFont(matching: theme.body),
                .foregroundColor: theme.secondary,
            ], range: range)

        case .headingText(let level):
            target.addAttributes([
                .font: theme.headingFont(level: level),
                .foregroundColor: theme.headingColor(level: level),
            ], range: range)

        case .strong:
            addTrait(bold: true, italic: nil, in: range, target: target, theme: theme)
        case .emphasis:
            addTrait(bold: nil, italic: true, in: range, target: target, theme: theme)

        case .strikethrough:
            target.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: theme.secondary,
            ], range: range)

        case .highlighted:
            target.addAttribute(.backgroundColor, value: theme.highlightBackground, range: range)

        case .inlineCode:
            // `code { font-size: 85% }` — but `h1 code { font-size: inherit }`,
            // so the size follows whatever the run already had.
            var codeSize = theme.metrics.codeSize
            target.enumerateAttribute(.font, in: range, options: []) { value, sub, _ in
                let mono = theme.monoFont(matching: value as? PlatformFont)
                codeSize = mono.pointSize
                target.addAttribute(.font, value: mono, range: sub)
            }
            // `code { padding: 0 .4em }`, or `.2em` inside a heading. Reserved
            // with kerning on the concealed backticks either side — they are
            // the only characters in the right places, and they are already
            // invisible — so the padding advances the text exactly as the
            // Preview's does. No `.backgroundColor`: the fragment paints the
            // pill, padding included.
            let inHeading = abs(codeSize - theme.metrics.codeSize) > 0.01
            let pad = (inHeading ? 0.2 : 0.4) * codeSize
            target.addAttribute(inlineCodeAttribute, value: pad, range: range)
            target.addAttribute(.kern, value: pad,
                                range: NSRange(location: range.location + range.length - 1, length: 1))
            // Only onto the backtick itself. cmark reports the span's *content*
            // and the delimiter sits just outside it, but a span that began at
            // a block's first character would otherwise put five points of
            // kerning on the last character of the block before.
            if range.location > 0,
               (target.string as NSString).character(at: range.location - 1) == 0x60 {
                target.addAttribute(.kern, value: pad,
                                    range: NSRange(location: range.location - 1, length: 1))
            }

        case .codeBlock:
            // No `.backgroundColor`: a text background paints behind glyphs
            // only, so a short line left a ragged edge and the box's 16pt
            // padding stayed uncoloured. The fragment fills the real box.
            target.addAttribute(.font, value: theme.mono, range: range)

        case .codeInfo:
            target.addAttributes([.font: theme.monoSmall, .foregroundColor: theme.secondary], range: range)

        case .mathSource:
            target.addAttributes([.font: theme.mono, .foregroundColor: theme.secondary], range: range)

        case .comment:
            target.addAttribute(.foregroundColor, value: theme.markerColor, range: range)

        case .linkText:
            target.addAttribute(.foregroundColor, value: theme.accent, range: range)

        case .url:
            // Real URLs get a live .link so the view gives hover + click.
            let urlString = (target.string as NSString).substring(with: range)
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: theme.accent]
            if let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true {
                attrs[.link] = url
            }
            target.addAttributes(attrs, range: range)

        case .wikiLink(let target_, let isEmbed):
            let exists = resolveWiki?(Self.baseTitle(of: target_)) ?? true
            var attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: exists ? theme.accent : theme.brokenLink,
                wikiTargetAttribute: target_,
            ]
            if !isEmbed, let encoded = target_.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
               let url = URL(string: "hellonotes-wiki://\(encoded)") {
                attrs[.link] = url
                #if canImport(AppKit)
                attrs[.cursor] = NSCursor.pointingHand
                #else
                // No `.cursor` attribute in UIKit — a pointer over a link on
                // iPadOS gets its hover effect from the text view's own pointer
                // interaction rather than from an attribute. The *link* is
                // there either way; only the cursor hint has no key to set.
                #endif
            }
            target.addAttributes(attrs, range: range)

        case .tag:
            target.addAttributes([
                .foregroundColor: theme.accent,
                .backgroundColor: theme.accent.withAlphaComponent(0.12),
            ], range: range)

        case .footnote:
            target.addAttributes([.foregroundColor: theme.accent, .font: theme.monoSmall], range: range)

        case .quote:
            target.addAttribute(.foregroundColor, value: theme.secondary, range: range)

        case .calloutTitle(let type):
            let (tint, _) = Self.calloutStyle(for: type, theme: theme)
            target.addAttributes([.font: theme.bodyBold, .foregroundColor: tint], range: range)

        case .listMarker:
            // An ordered list's `1.` takes the document's text colour, the way
            // `<ol>`'s markers do. It used to be the accent, which read as a
            // link and put the one thing GitHub renders in plain text in the
            // one colour GitHub reserves for links.
            target.addAttributes([.foregroundColor: theme.text], range: range)

        case .listBullet(let depth):
            // Keep the marker's width but hide the raw glyph; the fragment
            // draws a bullet in its place. Editing the line reveals the `-`.
            if revealed {
                target.addAttribute(.foregroundColor, value: theme.accent, range: range)
            } else {
                target.addAttributes([
                    .foregroundColor: PlatformColor.clear,
                    listBulletAttribute: depth,
                ], range: range)
            }

        case .taskMarker(let checked):
            // Conceal the `[ ]`/`[x]` characters (keep the mono width so the
            // layout is stable) and mark them so the fragment draws a real
            // checkbox glyph in their place — clickable to toggle.
            target.addAttributes([
                .font: theme.mono,
                .foregroundColor: PlatformColor.clear,
                taskCheckboxAttribute: checked,
            ], range: range)

        case .thematicBreak:
            target.addAttribute(.foregroundColor, value: theme.markerColor, range: range)

        case .frontMatter:
            target.addAttributes([.font: theme.monoSmall, .foregroundColor: theme.secondary], range: range)

        case .marker:
            target.addAttributes([
                .foregroundColor: theme.markerColor,
                markerAttribute: true,
            ], range: range)
        }
    }

    /// Merge a bold/italic trait into whatever font is already present, so
    /// nested emphasis (`**a *b* c**`) composes instead of replacing.
    private static func addTrait(
        bold: Bool?, italic: Bool?,
        in range: NSRange,
        target: NSMutableAttributedString,
        theme: EditorTheme
    ) {
        target.enumerateAttribute(.font, in: range, options: []) { value, sub, _ in
            let current = value as? PlatformFont ?? theme.body
            let isBold = (bold ?? currentIsBold(current)) || currentIsBold(current)
            let isItalic = (italic ?? currentIsItalic(current)) || currentIsItalic(current)
            let font: PlatformFont =
                switch (isBold, isItalic) {
                case (true, true): theme.bodyBoldItalic
                case (true, false): theme.bodyBold
                case (false, true): theme.bodyItalic
                case (false, false): theme.body
                }
            // Headings keep their size; only body-sized text swaps fonts.
            if current.pointSize == theme.body.pointSize {
                target.addAttribute(.font, value: font, range: sub)
            }
        }
    }

    private static func currentIsBold(_ font: PlatformFont) -> Bool {
        #if canImport(AppKit)
        font.fontDescriptor.symbolicTraits.contains(.bold)
        #else
        font.fontDescriptor.symbolicTraits.contains(.traitBold)
        #endif
    }

    private static func currentIsItalic(_ font: PlatformFont) -> Bool {
        #if canImport(AppKit)
        font.fontDescriptor.symbolicTraits.contains(.italic)
        #else
        font.fontDescriptor.symbolicTraits.contains(.traitItalic)
        #endif
    }

    /// `Note#heading` and `Note|alias` resolve on the note title alone.
    static func baseTitle(of target: String) -> String {
        var t = target
        if let pipe = t.firstIndex(of: "|") { t = String(t[..<pipe]) }
        if let hash = t.firstIndex(of: "#") { t = String(t[..<hash]) }
        return t.trimmingCharacters(in: .whitespaces)
    }
}
