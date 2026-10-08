//
//  MermaidDiagrams.swift
//  MarkdownCore
//
//  Which fences are diagrams, decided once.
//
//  The editor draws a ```` ```mermaid ```` fence as a picture, and the app
//  lists a note's diagrams — to offer the Mermaid command at all, and to page
//  through them in the zoom. The two used to decide separately: the editor
//  from this parse, the app with a regular expression that knew one spelling,
//  a lowercase backtick fence whose info string was the one word. A
//  `~~~mermaid` fence, a ```` ```Mermaid ```` or a ```` ```mermaid theme ````
//  was a picture in the note that the app could not find — no command in the
//  menu, and a zoom that could not list the diagram you had just clicked.
//  Both ask here now, and so does Preview's line scanner (`PreviewSuperset`,
//  in the app), which kept a third copy that wanted the info string to be the
//  one word: a ```` ```mermaid theme ```` was a picture in Edit and code in
//  Preview. It asks `MermaidDiagram.isDiagram(info:)`.
//

import Foundation

/// A Mermaid diagram in a document.
public struct MermaidDiagram: Sendable, Equatable {
    /// The fence, opening and closing lines included — the block's range.
    public var range: NSRange
    /// What it draws: the lines between the fences, without the last newline.
    public var source: String

    public init(range: NSRange, source: String) {
        self.range = range
        self.source = source
    }

    /// Whether a fence with this info string holds a diagram: its first word
    /// is `mermaid`, in any case. Words end at any whitespace, a tab included —
    /// the same first word cmark-gfm writes into `class="language-…"`.
    public static func isDiagram<S: StringProtocol>(info: S) -> Bool {
        info.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } == "mermaid"
    }
}

extension ParseResult {
    /// The Mermaid source block `index` draws, or nil if it is not a diagram.
    ///
    /// A diagram is a **closed** fence whose info string's first word is
    /// `mermaid`, in any case. An unclosed fence is not one yet: it is still
    /// being typed, and drawing it would redraw a half-written diagram on every
    /// keystroke. A fence with nothing between its lines draws nothing.
    public func mermaidSource(ofBlock index: Int, in text: NSString) -> String? {
        guard index >= 0, index < blocks.count else { return nil }
        let block = blocks[index]
        guard case .fencedCode(let info, let closed) = block.kind, closed,
              MermaidDiagram.isDiagram(info: info),
              block.range.location >= 0,
              block.range.location + block.range.length <= text.length
        else { return nil }
        let bodyFirst = block.firstLine + 1
        let bodyLast = block.firstLine + block.lineCount - 2
        guard bodyFirst <= bodyLast else { return nil }
        let start = lines.lineRange(bodyFirst).location
        let end = lines.contentRange(bodyLast, in: text)
        return text.substring(with: NSRange(location: start,
                                            length: end.location + end.length - start))
    }

    /// Every diagram in the document, in order.
    public func mermaidDiagrams(in text: NSString) -> [MermaidDiagram] {
        blocks.indices.compactMap { index in
            mermaidSource(ofBlock: index, in: text).map {
                MermaidDiagram(range: blocks[index].range, source: $0)
            }
        }
    }
}
