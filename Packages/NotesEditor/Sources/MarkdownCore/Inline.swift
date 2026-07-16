//
//  Inline.swift
//  MarkdownCore
//
//  Inline-level structure: the spans inside a block's content. Produced per
//  block, on demand — inline parsing a paragraph is microseconds, so blocks
//  are re-parsed whenever the styler needs them (no cache to invalidate).
//

import Foundation

public enum InlineKind: Sendable, Equatable {
    case strong                      // **text** / __text__
    case emphasis                    // *text* / _text_
    case strikethrough               // ~~text~~
    case highlight                   // ==text==
    case code                        // `code`
    case math                        // $math$
    case comment                     // %%hidden%%
    /// `[[target]]`, `[[target|alias]]`, `[[target#heading]]`.
    case wikiLink(target: String, isEmbed: Bool)
    /// `[text](url)` / `![alt](url)`.
    case link(url: String, isImage: Bool)
    case autolink(url: String)       // <https://…> or bare https://…
    case tag(name: String)           // #tag
    case footnoteRef(id: String)     // [^id]
}

public struct InlineNode: Sendable, Equatable {
    public var kind: InlineKind
    /// Absolute UTF-16 range of the whole construct, markers included.
    public var range: NSRange
    /// The visible content inside the markers.
    public var contentRange: NSRange
    /// The syntax-marker ranges (concealed when the caret is elsewhere).
    public var markerRanges: [NSRange]

    public init(kind: InlineKind, range: NSRange, contentRange: NSRange, markerRanges: [NSRange]) {
        self.kind = kind
        self.range = range
        self.contentRange = contentRange
        self.markerRanges = markerRanges
    }
}
