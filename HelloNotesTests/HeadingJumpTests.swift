//
//  HeadingJumpTests.swift
//  HelloNotesTests
//
//  Jumping to a heading is a *position*, not a search.
//
//  The outline posted the heading's own text as a find query, so "go to Rich
//  Content" meant "select the first occurrence of the words Rich Content" — and
//  in a note with front matter that is the `title:` line, four lines above the
//  heading. It was reported as "jumps to the wrong location" and it had been
//  visible all along: taking screenshots earlier the same day, clicking the
//  outline's first row highlighted `title: Rich Content` in the front matter,
//  and that was read as an inconvenience rather than as the bug.
//

import Foundation
import Testing
@testable import HelloNotes

struct HeadingJumpTests {

    /// A heading knows where it starts.
    @Test func headingsCarryTheirOffset() {
        let text = """
        # First

        Some prose.

        ## Second
        """
        let headings = MarkdownParsing.headings(in: text)
        #expect(headings.map(\.title) == ["First", "Second"])
        #expect(headings[0].offset == 0)
        let second = try! #require(headings[1].offset)
        #expect((text as NSString).substring(from: second).hasPrefix("## Second"))
    }

    /// **The reported bug.** The words of the heading appear earlier, in the
    /// front matter — a search lands there, a position does not.
    @Test func theOffsetIsTheHeadingNotTheFirstMentionOfItsWords() {
        let text = """
        ---
        title: Rich Content
        tags: [tour]
        ---

        # Rich Content

        Body.
        """
        let ns = text as NSString
        let heading = MarkdownParsing.headings(in: text).first { $0.title == "Rich Content" }
        let offset = try! #require(heading?.offset)

        #expect(ns.substring(from: offset).hasPrefix("# Rich Content"))
        // What the old mechanism would have done, for contrast: the first
        // occurrence of the text is the front-matter line, 4 characters in.
        #expect(ns.range(of: "Rich Content").location < offset,
                "the words really do appear before the heading — that was the trap")
    }

    /// Prose mentioning the heading's words also came first.
    @Test func proseBeforeTheHeadingDoesNotWin() {
        let text = """
        # Note

        We will get to Diagrams in a moment.

        ## Diagrams

        Here they are.
        """
        let ns = text as NSString
        let offset = try! #require(MarkdownParsing.headings(in: text)
            .first { $0.title == "Diagrams" }?.offset)
        #expect(ns.substring(from: offset).hasPrefix("## Diagrams"))
        #expect(ns.range(of: "Diagrams").location < offset)
    }

    /// Two headings with the same name are distinguished by position, which a
    /// search cannot do at all.
    @Test func duplicateHeadingsAreDistinctPositions() {
        let text = """
        ## Setup

        one

        ## Setup

        two
        """
        let headings = MarkdownParsing.headings(in: text).filter { $0.title == "Setup" }
        #expect(headings.count == 2)
        let a = try! #require(headings[0].offset), b = try! #require(headings[1].offset)
        #expect(a < b)
    }

    /// Offsets are UTF-16, because that is what the text views index by. A note
    /// with an emoji above the heading would otherwise land short.
    @Test func offsetsAreUTF16() {
        let text = """
        # 🇦🇺 Intro

        ## Target
        """
        let ns = text as NSString
        let offset = try! #require(MarkdownParsing.headings(in: text)
            .first { $0.title == "Target" }?.offset)
        #expect(ns.substring(from: offset).hasPrefix("## Target"))
    }

    /// A `DocumentHeading` written before offsets existed still decodes.
    ///
    /// It is stored inside `NoteIndexRecord`, and synthesised decoding *throws*
    /// on a missing key — so a non-optional field here would have made every
    /// cached record fail to decode, which is a silent wipe of the index rather
    /// than a loud error.
    @Test func anOlderCachedHeadingStillDecodes() throws {
        let json = Data(#"{"level":2,"title":"Older"}"#.utf8)
        let heading = try JSONDecoder().decode(DocumentHeading.self, from: json)
        #expect(heading.level == 2)
        #expect(heading.title == "Older")
        #expect(heading.offset == nil)
    }
}
