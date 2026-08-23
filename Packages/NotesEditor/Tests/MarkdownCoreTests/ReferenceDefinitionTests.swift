//
//  ReferenceDefinitionTests.swift
//  MarkdownCoreTests
//
//  The editor hides reference definitions because the rendered page has nothing
//  for them. Hiding one line too many deletes text the reader can see, so the
//  boundary cases matter more than the happy path.
//

import Foundation
import Testing
@testable import MarkdownCore

@Suite struct ReferenceDefinitionTests {

    private func matches(_ line: String) -> Bool {
        let ns = line as NSString
        return ReferenceDefinition.matches(ns, contentRange: NSRange(location: 0, length: ns.length))
    }

    @Test func plainDefinitions() {
        #expect(matches("[foo]: /url"))
        #expect(matches("[foo]: /url \"title\""))
        #expect(matches("[foo]: /url 'title'"))
        #expect(matches("[foo]: /url (title)"))
        #expect(matches("   [foo]: /url"))            // up to three spaces
        #expect(matches("[foo bar]: /url"))
        #expect(matches("[foo\\]bar]: /url"))         // escaped bracket in the label
    }

    /// CommonMark backs the title out when anything follows it, and the line
    /// becomes an ordinary paragraph — spec example 179. Hiding it would make
    /// text vanish.
    @Test func aTrailingWordAfterTheTitleIsNotADefinition() {
        #expect(!matches("[foo]: /url \"title\" ok"))
        #expect(!matches("[foo]: /url \"unclosed"))
    }

    /// An angle-bracketed destination ends at its `>`, and a title has to be
    /// separated from it by whitespace. `[foo]: <bar>(baz)` is a paragraph to
    /// cmark — spec example 170 — and treating it as a definition hid a line of
    /// text the reader can see.
    @Test func angleBracketedDestinations() {
        #expect(matches("[foo]: <bar>"))
        #expect(matches("[foo]: <bar> \"title\""))
        #expect(matches("[foo]: <>"))
        #expect(!matches("[foo]: <bar>(baz)"))
        #expect(!matches("[foo]: <bar"))          // unterminated
    }

    /// A link label needs at least one character that is not whitespace —
    /// spec example 560, `[\n ]\n\n[\n ]: /uri`, where cmark leaves both
    /// halves as visible paragraphs. The old guard only asked whether the label
    /// was *empty*, and a newline plus a space is not empty, so the four lines
    /// were concealed and the note came out 64pt short of its Preview.
    @Test func aLabelOfNothingButWhitespaceIsNotADefinition() {
        #expect(!matches("[\n ]: /uri"))
        #expect(!matches("[ ]: /uri"))
        #expect(!matches("[\t]: /uri"))
        #expect(!matches("[\n\n]: /uri"))
        // The whitespace is only fatal when it is *all* there is, and a
        // backslash escape is itself a character, so these stay definitions.
        #expect(matches("[ foo ]: /uri"))
        #expect(matches("[\n foo \n]: /uri"))
        #expect(matches("[\\ ]: /uri"))
    }

    /// `matches` is now `parse(…) != nil`, so the two can no longer disagree
    /// about what a definition is — but the halves it reads out are new, and a
    /// destination that quietly includes its own title is exactly the bug that
    /// once asked the renderer for a file called `photo.jpg "Caption"`.
    @Test func parseReadsTheLabelDestinationAndTitle() {
        func parse(_ line: String) -> ReferenceDefinition.Definition? {
            let ns = line as NSString
            return ReferenceDefinition.parse(ns, contentRange: NSRange(location: 0, length: ns.length))
        }
        let plain = parse("[foo bar]: /url \"the title\"")
        #expect(plain?.label == "foo bar")
        #expect(plain?.destination == "/url")
        #expect(plain?.title == "the title")
        #expect(parse("[foo]: /url")?.title == "")
        #expect(parse("[foo]: /url (paren title)")?.title == "paren title")
        #expect(parse("[foo]: <my url> 'q'")?.destination == "my url")
        #expect(parse("[foo]: <>")?.destination == "")
        // The label keeps its escapes and its line breaks; folding them is
        // `LinkReferenceMap`'s job, and doing it twice would fold it twice.
        #expect(parse("[foo\\]bar]: /url")?.label == "foo\\]bar")
        #expect(parse("[\n foo \n]: /uri")?.label == "\n foo \n")
    }

    @Test func whatIsNotADefinition() {
        #expect(!matches("[foo]: "))                  // no destination
        #expect(!matches("[]: /url"))                 // empty label
        #expect(!matches("[foo] /url"))               // no colon
        #expect(!matches("    [foo]: /url"))          // four spaces is code
        #expect(!matches("see [foo]: /url"))          // not at the start
        #expect(!matches("[foo[bar]]: /url"))         // nested brackets
        #expect(!matches(""))
    }
}
