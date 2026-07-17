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
        #expect(parse(#"\*not\* emphasis"#).isEmpty)
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

    // MARK: - Coordinates are absolute

    @Test func offsetsRespectBase() {
        let text = "xxxx**b**" as NSString
        let nodes = InlineParser.parse(text, in: NSRange(location: 4, length: 5))
        #expect(nodes.first?.range == NSRange(location: 4, length: 5))
        #expect(nodes.first?.contentRange == NSRange(location: 6, length: 1))
    }
}
