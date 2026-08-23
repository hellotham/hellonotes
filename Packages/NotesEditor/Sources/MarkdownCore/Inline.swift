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
    /// A raw inline `<img …>` tag, with its `src`.
    ///
    /// The one HTML element the inline layer has to know about, because it is
    /// the one that is **replaced**: every other inline tag decorates text
    /// that stays on the page, so leaving it as source costs a little markup
    /// on screen and nothing in the layout. An `<img>` draws a picture and no
    /// text at all, so a line holding one is a line whose box is set by
    /// something the editor could not see — and the box is 2pt taller than the
    /// one it laid out. It has no visible content and nothing to conceal until
    /// a picture actually arrives, so `contentRange` is empty and
    /// `markerRanges` is too; `EditorDocument` conceals the tag only once it
    /// has an image to put there.
    case rawImage(src: String)
    /// A raw inline HTML tag or comment — `<a href="…">`, `</em>`, `<!-- … -->`.
    ///
    /// It styles nothing: the tag stays on screen as the source the writer
    /// typed, exactly as it did before this case existed. It is here for the
    /// two things only a node can say. The scanner **consumes** the tag, so a
    /// `*` or `_` inside an attribute is not an emphasis delimiter (the same
    /// reason `rawImage` is scanned rather than skipped over). And it carries
    /// the tag's **extent**, which is the one fact the line-joining pass needs:
    /// a newline inside a tag is not a line break, because cmark has already
    /// eaten it into the token, and the page draws no `<br>` for it.
    case rawHTML
    case autolink(url: String)       // <https://…> or bare https://…
    case tag(name: String)           // #tag
    case footnoteRef(id: String)     // [^id]
    case escape                      // \* \` \# … (the backslash conceals)
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
