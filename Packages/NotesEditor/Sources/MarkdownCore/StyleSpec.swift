//
//  StyleSpec.swift
//  MarkdownCore
//
//  The pure styling layer: given a block (and the text), produce the list
//  of style runs — semantic roles over ranges, with a concealment policy
//  per run. No fonts, no colors, no platform types: the UI target maps
//  roles to attributes and decides how "concealed" renders. Keeping this
//  pure makes the entire Markdown presentation unit-testable.
//

import Foundation

/// Semantic role of a styled range. The UI maps these to fonts and colors.
public enum TextRole: Sendable, Equatable {
    case body
    case headingText(level: Int)
    case strong
    case emphasis
    case strikethrough
    case highlighted
    case inlineCode
    case codeBlock
    case codeInfo               // the fence's language string
    case mathSource
    case comment
    case linkText
    case url
    case wikiLink(target: String, isEmbed: Bool)
    case tag(name: String)
    case footnote
    case quote
    case calloutTitle(type: String)
    case listMarker
    case taskMarker(checked: Bool)
    case thematicBreak
    case frontMatter
    /// Syntax punctuation — `**`, `` ` ``, `[[`, heading `#`s, fences …
    case marker
}

/// Whether a run disappears when the caret is elsewhere (Typora-style
/// syntax concealment). Only ever applied to same-line punctuation — nothing
/// that would change line count.
public enum Concealment: Sendable, Equatable {
    case never
    case whenInactive
}

public struct StyleRun: Sendable, Equatable {
    public var range: NSRange
    public var role: TextRole
    public var concealment: Concealment

    public init(range: NSRange, role: TextRole, concealment: Concealment = .never) {
        self.range = range
        self.role = role
        self.concealment = concealment
    }
}

public enum StyleSpec {

    /// All style runs for `block`, base roles first, inline runs after —
    /// the applier lays them down in order, so later runs refine earlier
    /// ones (fonts merge traits; colors override).
    public static func runs(for block: Block, text: NSString, lines: LineIndex) -> [StyleRun] {
        var runs: [StyleRun] = []
        let spans = contentSpans(for: block, text: text, lines: lines, into: &runs)
        for span in spans where block.hasInlineContent {
            appendInlineRuns(for: span, text: text, into: &runs)
        }
        return runs
    }

    /// The block's inline-content spans (content minus block-level syntax),
    /// used both for styling and caret-context queries.
    public static func contentSpans(for block: Block, text: NSString, lines: LineIndex) -> [NSRange] {
        var scratch: [StyleRun] = []
        return contentSpans(for: block, text: text, lines: lines, into: &scratch)
    }

    // MARK: - Block-level runs

    private static func contentSpans(
        for block: Block,
        text: NSString,
        lines: LineIndex,
        into runs: inout [StyleRun]
    ) -> [NSRange] {
        let first = block.firstLine
        let last = block.firstLine + block.lineCount - 1

        switch block.kind {
        case .blank:
            return []

        case .paragraph:
            let content = trimmedBlockRange(block, text: text)
            runs.append(StyleRun(range: content, role: .body))
            return [content]

        case .heading(let level, let setext):
            if setext {
                // Text line(s) + underline line: heading style on the text,
                // marker on the underline (visible — hiding it would
                // collapse the line).
                let textEnd = last - 1
                let start = lines.lineRange(first).location
                let hi = lines.contentRange(textEnd, in: text)
                let content = NSRange(location: start, length: hi.location + hi.length - start)
                runs.append(StyleRun(range: content, role: .headingText(level: level)))
                runs.append(StyleRun(range: lines.contentRange(last, in: text), role: .marker))
                return [content]
            }
            let line = lines.contentRange(first, in: text)
            var i = line.location
            let end = line.location + line.length
            while i < end, text.character(at: i) == 0x20 { i += 1 }
            var hashes = 0
            while i + hashes < end, text.character(at: i + hashes) == 0x23 { hashes += 1 }
            var contentStart = i + hashes
            if contentStart < end, text.character(at: contentStart) == 0x20 { contentStart += 1 }
            let markerRange = NSRange(location: line.location, length: contentStart - line.location)
            let content = NSRange(location: contentStart, length: end - contentStart)
            runs.append(StyleRun(range: markerRange, role: .marker, concealment: .whenInactive))
            runs.append(StyleRun(range: content, role: .headingText(level: level)))
            return [content]

        case .fencedCode(let info, let closed):
            let openLine = lines.contentRange(first, in: text)
            runs.append(StyleRun(range: openLine, role: .marker))
            if !info.isEmpty {
                // The info string sits at the end of the open line.
                let infoLen = (info as NSString).length
                let infoRange = NSRange(location: openLine.location + openLine.length - infoLen, length: infoLen)
                runs.append(StyleRun(range: infoRange, role: .codeInfo))
            }
            let bodyFirst = first + 1
            let bodyLast = closed ? last - 1 : last
            if closed {
                runs.append(StyleRun(range: lines.contentRange(last, in: text), role: .marker))
            }
            if bodyFirst <= bodyLast {
                let start = lines.lineRange(bodyFirst).location
                let hi = lines.contentRange(bodyLast, in: text)
                let body = NSRange(location: start, length: max(0, hi.location + hi.length - start))
                runs.append(StyleRun(range: body, role: .codeBlock))
            }
            return []

        case .mathBlock:
            runs.append(StyleRun(range: trimmedBlockRange(block, text: text), role: .mathSource))
            return []

        case .blockquote(let callout):
            var spans: [NSRange] = []
            for lineNo in first...last {
                let line = lines.contentRange(lineNo, in: text)
                var i = line.location
                let end = line.location + line.length
                while i < end, text.character(at: i) == 0x20 { i += 1 }
                while i < end, text.character(at: i) == 0x3E { // '>' runs (nesting)
                    i += 1
                    if i < end, text.character(at: i) == 0x20 { i += 1 }
                }
                let markerRange = NSRange(location: line.location, length: i - line.location)
                if markerRange.length > 0 {
                    runs.append(StyleRun(range: markerRange, role: .marker))
                }
                let content = NSRange(location: i, length: end - i)
                if lineNo == first, let callout {
                    runs.append(StyleRun(range: content, role: .calloutTitle(type: callout)))
                } else {
                    runs.append(StyleRun(range: content, role: .quote))
                    spans.append(content)
                }
            }
            return spans

        case .listItem(let info):
            var spans: [NSRange] = []
            let markerLine = lines.contentRange(first, in: text)
            let markerRange = NSRange(location: markerLine.location + info.indent, length: info.markerLength)
            runs.append(StyleRun(range: markerRange, role: .listMarker))
            if let task = info.task {
                // The `[ ]` / `[x]` box sits right after "marker + space".
                let boxStart = markerLine.location + info.indent + info.markerLength + 1
                let boxLen = min(3, max(0, markerLine.location + markerLine.length - boxStart))
                if boxLen == 3 {
                    runs.append(StyleRun(range: NSRange(location: boxStart, length: 3),
                                         role: .taskMarker(checked: task == .checked)))
                }
            }
            let contentStart = markerLine.location + info.contentOffset
            let firstContent = NSRange(location: contentStart,
                                       length: max(0, markerLine.location + markerLine.length - contentStart))
            runs.append(StyleRun(range: firstContent, role: .body))
            spans.append(firstContent)
            if block.lineCount > 1 {
                for lineNo in (first + 1)...last {
                    let content = lines.contentRange(lineNo, in: text)
                    runs.append(StyleRun(range: content, role: .body))
                    spans.append(content)
                }
            }
            return spans

        case .table:
            var spans: [NSRange] = []
            for lineNo in first...last {
                let line = lines.contentRange(lineNo, in: text)
                if lineNo == first + 1 {
                    runs.append(StyleRun(range: line, role: .marker))   // delimiter row
                    continue
                }
                runs.append(StyleRun(range: line, role: .body))
                // Dim the pipes; content between them is inline-parsed.
                var cellStart = line.location
                var i = line.location
                let end = line.location + line.length
                while i <= end {
                    let isPipe = i < end && text.character(at: i) == 0x7C
                        && (i == line.location || text.character(at: i - 1) != 0x5C)
                    if isPipe || i == end {
                        if i > cellStart {
                            spans.append(NSRange(location: cellStart, length: i - cellStart))
                        }
                        if isPipe {
                            runs.append(StyleRun(range: NSRange(location: i, length: 1), role: .marker))
                        }
                        cellStart = i + 1
                    }
                    i += 1
                }
            }
            return spans

        case .thematicBreak:
            runs.append(StyleRun(range: trimmedBlockRange(block, text: text), role: .thematicBreak))
            return []

        case .frontMatter:
            runs.append(StyleRun(range: trimmedBlockRange(block, text: text), role: .frontMatter))
            return []
        }
    }

    // MARK: - Inline runs

    private static func appendInlineRuns(for span: NSRange, text: NSString, into runs: inout [StyleRun]) {
        for node in InlineParser.parse(text, in: span) {
            let contentRole: TextRole?
            var markerConcealment: Concealment = .whenInactive
            switch node.kind {
            case .strong: contentRole = .strong
            case .emphasis: contentRole = .emphasis
            case .strikethrough: contentRole = .strikethrough
            case .highlight: contentRole = .highlighted
            case .code: contentRole = .inlineCode
            case .math: contentRole = .mathSource
            case .comment: contentRole = .comment
            case .wikiLink(let target, let isEmbed):
                contentRole = .wikiLink(target: target, isEmbed: isEmbed)
            case .link(let url, _):
                contentRole = .linkText
                _ = url
            case .autolink:
                contentRole = .url
                markerConcealment = .never
            case .tag(let name):
                contentRole = .tag(name: name)
                markerConcealment = .never   // the # stays visible
            case .footnoteRef:
                contentRole = .footnote
                markerConcealment = .never
            }
            if let contentRole {
                runs.append(StyleRun(range: node.contentRange, role: contentRole))
            }
            for marker in node.markerRanges {
                runs.append(StyleRun(range: marker, role: .marker, concealment: markerConcealment))
            }
        }
    }

    /// The block's range without its final trailing newline.
    private static func trimmedBlockRange(_ block: Block, text: NSString) -> NSRange {
        var r = block.range
        if r.length > 0, text.character(at: r.location + r.length - 1) == 0x0A {
            r.length -= 1
        }
        return r
    }
}
