//
//  InlineParserTests.swift
//  MarkdownCoreTests
//

import Foundation
import Testing
@testable import MarkdownCore

@Suite struct InlineParserTests {

    private func parse(_ text: String) -> [InlineNode] {
        InlineParser.parse(text as NSString, in: NSRange(location: 0, length: (text as NSString).length))
    }

    private func node(_ text: String, _ kind: InlineKind) -> InlineNode? {
        parse(text).first { $0.kind == kind }
    }

    // MARK: - Spans

    @Test func codeSpan() {
        let n = node("a `code` b", .code)
        #expect(n?.contentRange == NSRange(location: 3, length: 4))
    }

    @Test func codeSpanNeedsMatchingRun() {
        // `` x ` y `` — double backticks close only with double.
        let nodes = parse("``x ` y``")
        #expect(nodes.count == 1)
        #expect(nodes[0].kind == .code)
        #expect(nodes[0].contentRange == NSRange(location: 2, length: 5))
    }

    @Test func delimitersInsideCodeAreLiteral() {
        let nodes = parse("`**not bold**`")
        #expect(nodes.count == 1)
        #expect(nodes[0].kind == .code)
    }

    @Test func inlineMath() {
        let n = node("cost $x^2$ here", .math)
        #expect(n?.contentRange == NSRange(location: 6, length: 3))
    }

    @Test func mathRejectsSpacePadding() {
        #expect(parse("5 $ 3 $ 1").isEmpty)   // "$ 3 $" is prose, not math
    }

    @Test func commentSpan() {
        let n = node("visible %%hidden%% visible", .comment)
        #expect(n?.contentRange == NSRange(location: 10, length: 6))
    }

    @Test func highlightAndStrike() {
        #expect(node("a ==mark== b", .highlight) != nil)
        #expect(node("a ~~gone~~ b", .strikethrough) != nil)
    }

    // MARK: - Emphasis

    @Test func strongAndEmphasis() {
        #expect(node("**bold**", .strong)?.contentRange == NSRange(location: 2, length: 4))
        #expect(node("*it*", .emphasis)?.contentRange == NSRange(location: 1, length: 2))
        #expect(node("__bold__", .strong) != nil)
        #expect(node("_it_", .emphasis) != nil)
    }

    @Test func nestedEmphasis() {
        let nodes = parse("**bold *inner* bold**")
        #expect(nodes.contains { $0.kind == .strong })
        #expect(nodes.contains { $0.kind == .emphasis })
    }

    @Test func tripleAsteriskMakesBoth() {
        let nodes = parse("***both***")
        #expect(nodes.contains { $0.kind == .strong })
        #expect(nodes.contains { $0.kind == .emphasis })
    }

    @Test func underscoreIntraWordIsLiteral() {
        #expect(parse("snake_case_name").isEmpty)
    }

    @Test func unclosedEmphasisIsLiteral() {
        #expect(parse("2 * 3 = 6").isEmpty)
        #expect(parse("*open but never closed").isEmpty)
    }

    @Test func escapedDelimiterIsLiteral() {
        // The `*` is escaped → no emphasis; each `\` becomes a concealable
        // escape node (backslash marker, literal punctuation as content).
        let nodes = parse(#"\*not\* emphasis"#)
        #expect(nodes.allSatisfy { $0.kind == .escape })
        #expect(nodes.count == 2)
        #expect(nodes.first?.markerRanges == [NSRange(location: 0, length: 1)])
    }

    // MARK: - Links

    @Test func wikiLink() {
        let n = node("see [[My Note]] here", .wikiLink(target: "My Note", isEmbed: false))
        #expect(n?.range == NSRange(location: 4, length: 11))
        #expect(n?.contentRange == NSRange(location: 6, length: 7))
    }

    @Test func wikiLinkWithAliasAndHeading() {
        #expect(node("[[Note|alias]]", .wikiLink(target: "Note|alias", isEmbed: false)) != nil)
        #expect(node("[[Note#Section]]", .wikiLink(target: "Note#Section", isEmbed: false)) != nil)
    }

    @Test func embedWikiLink() {
        let n = node("![[image.png]]", .wikiLink(target: "image.png", isEmbed: true))
        #expect(n?.range == NSRange(location: 0, length: 14))
    }

    @Test func markdownLink() {
        let n = node("[text](https://x.com)", .link(url: "https://x.com", isImage: false))
        #expect(n?.contentRange == NSRange(location: 1, length: 4))
    }

    @Test func imageLink() {
        #expect(node("![alt](img.png)", .link(url: "img.png", isImage: true)) != nil)
    }

    /// The parenthesised run is a destination *and* an optional title, and the
    /// url the node carries is the destination alone. Handed the whole run, an
    /// image the ordinary captioned way resolved to a file called
    /// `img.png "Caption"` and stayed as source in the editor while Preview
    /// drew the picture. The node's `range` still covers the whole construct —
    /// the title is concealed with the rest of the tail, not dropped.
    @Test func linkDestinationLeavesTheTitleBehind() {
        #expect(node("![alt](img.png \"Caption\")", .link(url: "img.png", isImage: true)) != nil)
        #expect(node("[t](/url 'title')", .link(url: "/url", isImage: false)) != nil)
        #expect(node("[t](  /url  \"title\"  )", .link(url: "/url", isImage: false)) != nil)
        let n = node("![alt](img.png \"Caption\")", .link(url: "img.png", isImage: true))
        #expect(n?.range == NSRange(location: 0, length: 25))
    }

    /// `<…>` is CommonMark's way of writing a destination with a space in it.
    @Test func angledLinkDestinationDropsItsBrackets() {
        #expect(node("[t](<my url>)", .link(url: "my url", isImage: false)) != nil)
        #expect(node("![a](<img.png> \"Cap\")", .link(url: "img.png", isImage: true)) != nil)
        // Unterminated: not a destination at all, so the run is left whole
        // rather than truncated at a `>` that is not there.
        #expect(node("[t](<oops)", .link(url: "<oops", isImage: false)) != nil)
    }

    @Test func autolinks() {
        #expect(node("<https://a.io>", .autolink(url: "https://a.io")) != nil)
        #expect(node("go to https://a.io now", .autolink(url: "https://a.io")) != nil)
        // Trailing period is prose, not URL.
        #expect(node("see https://a.io.", .autolink(url: "https://a.io")) != nil)
    }

    @Test func wwwAutolinkGetsHTTPSURL() {
        // GFM extended autolink: `www.` links to https:// but displays as-is.
        let n = node("visit www.github.com today", .autolink(url: "https://www.github.com"))
        #expect(n != nil)
        #expect(n?.contentRange == NSRange(location: 6, length: 14))   // "www.github.com"
        // Not a link mid-word.
        #expect(parse("xwww.github.com").isEmpty)
    }

    // MARK: - Tags & footnotes

    @Test func tags() {
        #expect(node("a #tag here", .tag(name: "tag")) != nil)
        #expect(node("#nested/tag-2", .tag(name: "nested/tag-2")) != nil)
        // Word-adjacent # is not a tag; pure numbers are not tags.
        #expect(parse("C#5 note").isEmpty)
        #expect(parse("#123").isEmpty)
    }

    @Test func footnoteRef() {
        #expect(node("claim[^1]", .footnoteRef(id: "1")) != nil)
    }

    // MARK: - Raw <img>, the one replaced element

    /// The tag is a node so the editor can put a picture where it is, and the
    /// node ends at the tag's own `>` — not at the first `>` in the source.
    @Test func rawIMGTag() {
        let nodes = parse("a <img src=\"pic.png\"> b")
        #expect(nodes.count == 1)
        #expect(nodes[0].kind == .rawImage(src: "pic.png"))
        #expect(nodes[0].range == NSRange(location: 2, length: 19))
        // Nothing visible and nothing to conceal: a replaced element has no
        // text of its own, and the tag stays on screen until a picture arrives.
        #expect(nodes[0].contentRange.length == 0)
        #expect(nodes[0].markerRanges.isEmpty)
    }

    /// Example 484 of the specification, and the reason the tag is consumed by
    /// the scan rather than matched afterwards: the `*` inside an attribute is
    /// not an emphasis delimiter, and it stops being one only because the
    /// delimiter pass never sees the characters inside the tag.
    @Test func aQuotedAngleOrStarInsideTheTagIsNotSyntax() {
        let nodes = parse("*<img src=\"foo\" title=\"*\"/>")
        #expect(nodes.count == 1)
        #expect(nodes[0].kind == .rawImage(src: "foo"))
        #expect(nodes[0].range == NSRange(location: 1, length: 26))
        #expect(parse("<img src='a>b.png'> x").first?.kind == .rawImage(src: "a>b.png"))
    }

    @Test func rawIMGAttributeForms() {
        #expect(node("<img src=pic.png>", .rawImage(src: "pic.png")) != nil)
        #expect(node("<IMG SRC=\"pic.png\" />", .rawImage(src: "pic.png")) != nil)
        #expect(node("<img alt=\"x\" src=\"pic.png\">", .rawImage(src: "pic.png")) != nil)
        // The three below are raw tags, not replaced elements: they claim no
        // picture, so the writer keeps their markup on screen. They are
        // `.rawHTML` rather than nothing at all because the scan still has to
        // consume them — see `aStarInsideAnyTagIsNotSyntax`.
        //
        // `data-src` is not `src`: the attribute has to start at a boundary.
        #expect(parse("<img data-src=\"pic.png\">").map(\.kind) == [.rawHTML])
        // No `src` at all — nothing to draw, so nothing is claimed.
        #expect(parse("<img alt=\"x\">").map(\.kind) == [.rawHTML])
        // Not a tag *named* img, and therefore not a tag with a missing `src`.
        #expect(parse("<images>").map(\.kind) == [.rawHTML])
        // Unterminated: an `<img>` never spans a line, and neither does a run
        // with no `>` in it at all.
        #expect(parse("<img src=\"a\"\nrest").isEmpty)
    }

    // MARK: - Raw HTML, and the line ending inside it

    /// The extent, and the fact that it may cross a line ending. cmark eats
    /// that newline into the token — the page draws one line for the tag, not
    /// two — which is the one thing the editor needs a node here to know.
    @Test func aRawTagIsOneNodeEvenAcrossALineEnding() {
        #expect(parse("<a href=\"x\">").map(\.kind) == [.rawHTML])
        #expect(parse("a <b data=\"x\ny\"> c").first?.range == NSRange(location: 2, length: 14))
        #expect(parse("</em>").map(\.kind) == [.rawHTML])
        #expect(parse("<a  /><b2\ndata=\"foo\" >").map(\.kind) == [.rawHTML, .rawHTML])
        // A comment, whose text may contain `--` (the old spec rule is gone,
        // and example 644 is exactly that shape).
        let comment = parse("foo <!-- this is a --\ncomment - with hyphens -->")
        #expect(comment.map(\.kind) == [.rawHTML])
        #expect(comment.first?.range == NSRange(location: 4, length: 44))
    }

    /// The grammar is `HTMLBlockShape`'s, and it is strict where a scan to the
    /// next `>` is not. `bim!bop` is not an attribute name, so cmark reads the
    /// whole run as literal text and the page prints two lines — spec #640, and
    /// what a lax scanner joined into one.
    @Test func aRunThatIsNotATagIsNotClaimed() {
        #expect(parse("<foo bar=baz\nbim!bop />").isEmpty)
        #expect(parse("< a><\nfoo><bar/ >").isEmpty)
        #expect(parse("a < b and c > d").isEmpty)
        // An autolink is still an autolink: the tag branch is tried after it,
        // and `https:` is not a tag name followed by a delimiter anyway.
        #expect(parse("<http://foo.bar>").map(\.kind) == [.autolink(url: "http://foo.bar")])
        // `a <b and c> d` genuinely *is* a tag with two boolean attributes.
        #expect(parse("a <b and c> d").map(\.kind) == [.rawHTML])
    }

    /// A star inside any tag, not only inside an `<img>`: the scan consumes the
    /// tag, so the delimiter pass never sees the characters in it.
    @Test func aStarInsideAnyTagIsNotSyntax() {
        // One emphasis, and it is `*y*`. Without the tag being consumed the
        // `*` in the attribute is a delimiter, and it pairs with the first `*`
        // after the tag — italicising `>x` and leaving `y` bare.
        let nodes = parse("<a title=\"*\">x*y*")
        #expect(nodes.contains { $0.kind == .rawHTML })
        #expect(nodes.filter { $0.kind == .emphasis }.map(\.range)
                == [NSRange(location: 14, length: 3)])
    }

    // MARK: - A line ending inside a link's parentheses

    /// Allowed only where whitespace is allowed. All three of these are in the
    /// corpus and all three disagree with each other.
    @Test func aLineEndingIsALinkOnlyBetweenTheDestinationAndTheTitle() {
        // #518 — between destination and title: one link.
        #expect(parse("[link](   /uri\n  \"title\"  )").contains {
            $0.kind == .link(url: "/uri", isImage: false) })
        // #499 — inside an unquoted destination: not a link at all, so both
        // lines stay literal text and the page draws two of them.
        #expect(!parse("[link](foo\nbar)").contains { if case .link = $0.kind { true } else { false } })
        // #500 — inside `<…>`: not a link either. The `<foo⏎bar>` in it *is* a
        // raw tag, which is what the page makes of it.
        let angled = parse("[link](<foo\nbar>)")
        #expect(!angled.contains { if case .link = $0.kind { true } else { false } })
        #expect(angled.contains { $0.kind == .rawHTML })
        // Single-line links keep the lenient scan they have always had.
        #expect(parse("[a](b c)").contains { if case .link = $0.kind { true } else { false } })
    }

    // MARK: - Coordinates are absolute

    @Test func offsetsRespectBase() {
        let text = "xxxx**b**" as NSString
        let nodes = InlineParser.parse(text, in: NSRange(location: 4, length: 5))
        #expect(nodes.first?.range == NSRange(location: 4, length: 5))
        #expect(nodes.first?.contentRange == NSRange(location: 6, length: 1))
    }
}
