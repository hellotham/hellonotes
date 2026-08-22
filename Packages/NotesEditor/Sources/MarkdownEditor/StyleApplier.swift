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
        gfmRuns: [StyleRun] = []
    ) {
        target.beginEditing()
        for index in blockIndices where index >= 0 && index < parse.blocks.count {
            let block = parse.blocks[index]
            guard block.range.length > 0,
                  block.range.location + block.range.length <= target.length else { continue }
            applyBase(for: block, at: index, in: parse.blocks, text: text,
                      lines: parse.lines, to: target, theme: theme, revealedLines: revealedLines)
            let runs = StyleSpec.runs(for: block, text: text, lines: parse.lines)
            /// Is this run on a line the caret is on?
            func revealsRun(_ run: StyleRun) -> Bool {
                revealedLines.contains(parse.lines.lineNumber(at: run.range.location))
            }
            for run in runs {
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
                   && run.range.location + run.range.length <= blockEnd {
                    apply(run, to: target, theme: theme, revealed: revealsRun(run), resolveWiki: resolveWiki)
                }
            }
            // Plain-blockquote gutter bars are per-line (nesting depth), and so
            // is the decision to draw them: a line showing its raw `>` sits at
            // its natural indent with no bar, while every other line of the same
            // quote keeps its bar.
            applyQuoteBars(for: block, lines: parse.lines, text: text,
                           to: target, theme: theme, revealedLines: revealedLines)
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
        case .table, .fencedCode, .indentedCode, .mathBlock, .frontMatter, .thematicBreak, .blank: false
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
        revealedLines: Set<Int>
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

        let lastLineNumber = block.firstLine + block.lineCount - 1
        // Which line carries the block's trailing gap. Normally the last, but a
        // block whose parser range runs past its rendered content — an indented
        // code block keeps the blank lines that follow it — hands the gap to
        // the last line that actually renders.
        var gapLine = lastLineNumber

        // A blank run is not a box: it is the gap between the two boxes it
        // separates, and it gets exactly that much height, shared out over
        // however many blank lines were typed.
        guard let box = BlockBoxes.box(at: index, in: blocks, text: text) else {
            let total = BlockBoxes.blankRunHeight(index, in: blocks, text: text,
                                                  lines: lines, metrics: m)
            let each = max(BlockBoxes.minimumBlankLine, total / CGFloat(max(1, block.lineCount)))
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = each
            style.maximumLineHeight = each
            target.addAttribute(.paragraphStyle, value: style, range: block.range)
            return
        }

        let style = BlockBoxes.baseStyle(for: block, box: box, text: text, theme: theme)
        target.addAttribute(.paragraphStyle, value: style, range: block.range)

        // The gap below this block — unless the next block is a blank run,
        // which is already holding it.
        let nextIsBlank = blocks.indices.contains(index + 1)
            && BlockBoxes.box(at: index + 1, in: blocks, text: text) == nil
        var trailing = nextIsBlank ? 0 : BlockBoxes.gapAfter(index, in: blocks, text: text, metrics: m)
        // When a blank run follows, it is holding the gap — except for the
        // share that belongs to this block's own collapsed tail lines.
        let collapsedTotal = nextIsBlank
            ? BlockBoxes.gapShares(blankRunAt: index + 1, in: blocks, text: text,
                                   lines: lines, metrics: m).tail
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
            if level <= 2 {
                // GitHub's h1/h2 rule: `padding-bottom: .3em` then a 1px
                // border. Padding is inside the box, so it adds to the
                // collapsed margin rather than collapsing with it — and it
                // stays above a setext underline that is now holding the
                // margin, which is where CSS puts the padding too.
                trailing += m.headingRuleInset(level)
                target.addAttribute(headingRuleAttribute, value: level,
                                    range: NSRange(location: block.range.location,
                                                   length: min(1, block.range.length)))
            }

        case .fencedCode, .mathBlock:
            // `pre { padding: 16px }`, vertically. The fence lines are exactly
            // where that padding goes: concealed they are an empty band of the
            // right height, revealed they show the fence you are editing.
            applyFenceBand(block: block, lines: lines, to: target, metrics: m)
            applyCodeBand(block: block, lines: lines, to: target)

        case .indentedCode:
            // No fences to spend, so the padding is spacing at the block's own
            // edges — which does not collapse with the neighbouring margins,
            // exactly as CSS padding does not.
            //
            // The parser keeps the blank lines that trail an indented code
            // block and cmark drops them; left at the code line height they
            // added a phantom line of listing to every such block.
            let contentLast = lastContentLine(of: block, lines: lines, text: text)
            if contentLast < lastLineNumber {
                collapseLines(from: contentLast + 1, through: lastLineNumber,
                              total: collapsedTotal, lines: lines, to: target)
                trailing = 0
            }
            applyCodeBand(block: block, through: contentLast, lines: lines, to: target)
            let opening = style.mutableCopy() as! NSMutableParagraphStyle
            opening.paragraphSpacingBefore = m.codePadding
            target.addAttribute(.paragraphStyle, value: opening,
                                range: lines.lineRange(block.firstLine))
            // The bottom padding and the collapsed margin both belong below the
            // last line that renders. Written as two styles, the second
            // replaced the first and one of them silently vanished — which is
            // how the top padding disappeared from one-line listings.
            gapLine = contentLast
            trailing += m.codePadding

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

        // The collapsed margin goes on the last line and nowhere else:
        // `paragraphSpacing` ends every *paragraph*, and TextKit ends one at
        // each newline, so a block-wide value would space a five-line
        // blockquote's own lines apart.
        guard trailing > 0 else { return }
        let lastLine = lines.lineRange(gapLine)
        guard lastLine.length > 0,
              lastLine.location + lastLine.length <= target.length else { return }
        let existing = target.attribute(.paragraphStyle, at: lastLine.location,
                                        effectiveRange: nil) as? NSParagraphStyle ?? style
        let closing = (existing.mutableCopy() as! NSMutableParagraphStyle)
        closing.paragraphSpacing = trailing
        target.addAttribute(.paragraphStyle, value: closing, range: lastLine)
    }

    /// Give a fenced block's opening and closing fence lines the height of the
    /// code box's vertical padding. Concealed (caret away) they draw nothing,
    /// so what is left is exactly `pre { padding: 16px }`; revealed, the fence
    /// is there to edit.
    private static func applyFenceBand(block: Block, lines: LineIndex,
                                       to target: NSMutableAttributedString,
                                       metrics m: GFMBoxMetrics) {
        let last = block.firstLine + block.lineCount - 1
        var fenceLines = [block.firstLine]
        if last > block.firstLine { fenceLines.append(last) }
        for lineNumber in fenceLines {
            let range = lines.lineRange(lineNumber)
            guard range.length > 0, range.location + range.length <= target.length else { continue }
            let band = NSMutableParagraphStyle()
            band.minimumLineHeight = m.codePadding
            band.maximumLineHeight = m.codePadding
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
    /// drift for every such block. Never quite zero, though: a line the caret
    /// cannot be seen on is a line you cannot edit your way out of.
    private static func collapseLines(from firstLine: Int, through lastLine: Int,
                                      total: CGFloat, lines: LineIndex,
                                      to target: NSMutableAttributedString) {
        guard lastLine >= firstLine else { return }
        let each = max(BlockBoxes.minimumBlankLine, total / CGFloat(lastLine - firstLine + 1))
        for lineNumber in firstLine...lastLine {
            let range = lines.lineRange(lineNumber)
            guard range.length > 0, range.location + range.length <= target.length else { continue }
            let flat = NSMutableParagraphStyle()
            flat.minimumLineHeight = each
            flat.maximumLineHeight = each
            target.addAttribute(.paragraphStyle, value: flat, range: range)
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
        revealedLines: Set<Int> = []
    ) {
        guard case .blockquote(nil) = block.kind else { return }
        let first = block.firstLine, last = block.firstLine + block.lineCount - 1
        for lineNo in first...last where !revealedLines.contains(lineNo) {
            let line = lines.contentRange(lineNo, in: text)
            // Count `>` markers on this line = nesting depth.
            var i = line.location
            let end = line.location + line.length
            var depth = 0
            while i < end, text.character(at: i) == 0x20 { i += 1 }
            while i < end, text.character(at: i) == 0x3E {   // '>'
                depth += 1; i += 1
                if i < end, text.character(at: i) == 0x20 { i += 1 }
            }
            guard depth > 0 else { continue }
            let lineRange = lines.lineRange(lineNo)
            target.addAttribute(calloutTintAttribute, value: theme.secondary, range: lineRange)
            target.addAttribute(blockquotePlainAttribute, value: depth, range: lineRange)
            // `blockquote { border-left: .25em; padding: 0 1em }` — one such
            // step per `>` of nesting, so the text clears every bar.
            let para = (target.attribute(.paragraphStyle, at: lineRange.location,
                                         effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            let inset = CGFloat(depth) * theme.metrics.quoteIndent
            para.firstLineHeadIndent = inset
            para.headIndent = inset
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
