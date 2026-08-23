//
//  LinkReferenceTests.swift
//  MarkdownCoreTests
//
//  `[foo]` is a link only because `[foo]: /url` exists somewhere else, so the
//  two halves have to be tested together: the map that collects definitions,
//  and the inline parser that spends them. The dangerous direction is the
//  false positive — every square bracket in ordinary prose is a shortcut
//  reference waiting for a definition that must not be invented.
//

import Foundation
import Testing
@testable import MarkdownCore

@Suite struct LinkReferenceTests {

    private func map(_ text: String) -> LinkReferenceMap {
        let ns = text as NSString
        return LinkReferenceMap(scanning: ns, document: BlockParser.fullParse(ns))
    }

    private func parse(_ text: String, _ references: LinkReferenceMap) -> [InlineNode] {
        InlineParser.parse(text as NSString, in: NSRange(location: 0, length: (text as NSString).length),
                           references: references)
    }

    // MARK: - Collecting

    @Test func aDefinitionCarriesItsDestinationAndTitle() {
        let m = map("[foo]: /url \"title\"\n")
        #expect(m["foo"]?.destination == "/url")
        #expect(m["foo"]?.title == "title")
        #expect(m.count == 1)
    }

    @Test func anAngleBracketedDestinationLosesItsBrackets() {
        #expect(map("[foo]: <my url>\n")["foo"]?.destination == "my url")
    }

    /// CommonMark's label normalisation: case fold, trim the ends, collapse
    /// each internal whitespace run to one space. `[FOOBAR]` and `[foobar]`
    /// name the same definition — spec example 585 renders an image from a
    /// definition written in a different case from the reference.
    @Test func labelsMatchAfterCaseFoldingAndWhitespaceCollapse() {
        let m = map("[FOOBAR]: train.jpg\n")
        #expect(m["foobar"] != nil)
        #expect(m["FooBar"] != nil)
        let spaced = map("[foo  bar]: /url\n")
        #expect(spaced["foo bar"] != nil)
        #expect(spaced[" foo   bar "] != nil)
        // A label written across lines: the break counts as one space.
        #expect(map("[foo\nbar]: /url\n")["foo bar"] != nil)
    }

    /// A repeated label keeps the *earlier* definition. Writing each one into
    /// the dictionary in turn keeps the later one instead — the opposite, and
    /// with nothing to show for it.
    @Test func anEarlierDefinitionWins() {
        let m = map("[foo]: /first\n[foo]: /second\n")
        #expect(m["foo"]?.destination == "/first")
    }

    /// Definitions inside a list item or a blockquote count too — they are the
    /// ones the cmark inversion cannot see, because a container node covers
    /// them along with its children.
    @Test func definitionsInsideContainersAreCollected() {
        #expect(map("- [foo]: /url\n")["foo"]?.destination == "/url")
        #expect(map("> [bar]: /url\n")["bar"]?.destination == "/url")
    }

    /// A definition cannot interrupt a paragraph, so the second line here is
    /// two lines of one paragraph — text the reader sees, and not a definition
    /// anything may resolve against.
    @Test func aLineInsideAParagraphIsNotADefinition() {
        #expect(map("prose\n[foo]: /url\n")["foo"] == nil)
    }

    // MARK: - Spending

    @Test func theThreeReferenceFormsResolve() {
        let m = map("[bar]: /url \"t\"\n")
        // Full.
        #expect(parse("[text][bar]", m).contains { $0.kind == .link(url: "/url", isImage: false) })
        // Collapsed — the text is its own label.
        let collapsed = map("[text]: /url\n")
        #expect(parse("[text][]", collapsed).contains { $0.kind == .link(url: "/url", isImage: false) })
        // Shortcut.
        #expect(parse("[text]", collapsed).contains { $0.kind == .link(url: "/url", isImage: false) })
    }

    @Test func theSameThreeFormsWorkForImages() {
        let m = map("[bar]: train.jpg\n")
        #expect(parse("![text][bar]", m).contains { $0.kind == .link(url: "train.jpg", isImage: true) })
        let self_ = map("[text]: train.jpg\n")
        #expect(parse("![text][]", self_).contains { $0.kind == .link(url: "train.jpg", isImage: true) })
        #expect(parse("![text]", self_).contains { $0.kind == .link(url: "train.jpg", isImage: true) })
    }

    @Test func aReferenceNodeSpansTheWholeConstruct() {
        let m = map("[bar]: /url\n")
        let nodes = parse("![foo][bar]", m)
        #expect(nodes.count == 1)
        #expect(nodes[0].range == NSRange(location: 0, length: 11))
        #expect(nodes[0].contentRange == NSRange(location: 2, length: 3))     // "foo"
        // Opener and tail conceal, exactly as an inline link's do.
        #expect(nodes[0].markerRanges == [NSRange(location: 0, length: 2),
                                          NSRange(location: 5, length: 6)])
    }

    // MARK: - The false positives

    /// The whole risk of the shortcut form. `[see below]` is a link if and
    /// only if a definition exists, and prose is full of brackets that have
    /// none — get this wrong and every aside in every note becomes a link to
    /// nowhere.
    @Test func bracketedProseWithNoDefinitionIsNotALink() {
        let m = map("[other]: /url\n")
        #expect(parse("a [note] here", m).isEmpty)
        #expect(parse("[citation needed]", m).isEmpty)
        #expect(parse("![no such picture]", m).isEmpty)
        // And with nothing defined at all, whatever the brackets say.
        #expect(parse("[other]", .empty).isEmpty)
    }

    /// A label followed by a *link label* is not a shortcut, even when the
    /// second label resolves to nothing. Falling back to the shortcut here
    /// would link `[foo]` and leave `[bar]` beside it as litter.
    @Test func anUndefinedFullReferenceIsNotAShortcut() {
        let m = map("[foo]: /url\n")
        #expect(parse("[foo][bar]", m).isEmpty)
    }

    /// `[[foo]]` is a wikilink and stays one — the inline parser reaches the
    /// reference forms only after the Obsidian constructs have had their say.
    @Test func aWikiLinkIsNotAShortcutReference() {
        let m = map("[foo]: /url\n")
        let nodes = parse("[[foo]]", m)
        #expect(nodes.count == 1)
        #expect(nodes[0].kind == .wikiLink(target: "foo", isEmbed: false))
    }

    /// An inline destination always wins: `[foo](/inline)` is not looked up.
    @Test func anInlineDestinationBeatsADefinitionOfTheSameName() {
        let m = map("[foo]: /reference\n")
        #expect(parse("[foo](/inline)", m).contains { $0.kind == .link(url: "/inline", isImage: false) })
    }
}
