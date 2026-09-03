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

    /// The n-th heading, found by a scan that never runs on the main actor.
    @Test func findsTheNthHeading() {
        let text = """
        # First

        Some prose.

        ## Second

        ### Third
        """
        let ns = text as NSString
        for (ordinal, expected) in [(0, "# First"), (1, "## Second"), (2, "### Third")] {
            let offset = try! #require(SourceHeadingScan.offset(ofHeading: ordinal, in: text))
            #expect(ns.substring(from: offset).hasPrefix(expected))
        }
        #expect(SourceHeadingScan.offset(ofHeading: 3, in: text) == nil)
    }

    /// **The reported bug.** The heading's words appear earlier, in the front
    /// matter — a search lands there; counting headings cannot.
    @Test func frontMatterIsNotAHeading() {
        let text = """
        ---
        title: Rich Content
        tags: [tour]
        ---

        # Rich Content

        Body.
        """
        let ns = text as NSString
        let offset = try! #require(SourceHeadingScan.offset(ofHeading: 0, in: text))
        #expect(ns.substring(from: offset).hasPrefix("# Rich Content"))
        #expect(ns.range(of: "Rich Content").location < offset,
                "the words really do appear before the heading — that was the trap")
    }

    /// Prose mentioning the words is not a heading either.
    @Test func proseIsNotAHeading() {
        let text = """
        # Note

        We will get to Diagrams in a moment.

        ## Diagrams
        """
        let ns = text as NSString
        let offset = try! #require(SourceHeadingScan.offset(ofHeading: 1, in: text))
        #expect(ns.substring(from: offset).hasPrefix("## Diagrams"))
    }

    /// A `#` inside a fence is code, not a heading — otherwise every shell
    /// comment in a note shifts every ordinal after it.
    @Test func fencedHashesAreNotHeadings() {
        let text = """
        # Real

        ```bash
        # not a heading
        ```

        ## Also real
        """
        let ns = text as NSString
        let offset = try! #require(SourceHeadingScan.offset(ofHeading: 1, in: text))
        #expect(ns.substring(from: offset).hasPrefix("## Also real"))
    }

    /// `#tag` at the start of a line is a tag; a heading needs the space.
    @Test func aTagIsNotAHeading() {
        let text = "#tag alone\n\n# Actual\n"
        let ns = text as NSString
        let offset = try! #require(SourceHeadingScan.offset(ofHeading: 0, in: text))
        #expect(ns.substring(from: offset).hasPrefix("# Actual"))
    }

    /// Two headings with the same name are distinct positions — which is the
    /// thing a text search fundamentally cannot express.
    @Test func duplicateHeadingsAreDistinct() {
        let text = "## Setup\n\none\n\n## Setup\n\ntwo\n"
        let a = try! #require(SourceHeadingScan.offset(ofHeading: 0, in: text))
        let b = try! #require(SourceHeadingScan.offset(ofHeading: 1, in: text))
        #expect(a < b)
    }

    /// Offsets are UTF-16, because that is what the text views index by.
    @Test func offsetsAreUTF16() {
        let text = "# 🇦🇺 Intro\n\n## Target\n"
        let ns = text as NSString
        let offset = try! #require(SourceHeadingScan.offset(ofHeading: 1, in: text))
        #expect(ns.substring(from: offset).hasPrefix("## Target"))
    }

    /// The ordinal survives an edit that an offset would not.
    ///
    /// This is the whole argument for sending an ordinal. Type a paragraph above
    /// a heading and every offset below it moves; the heading is still the n-th
    /// heading. The outline can therefore be on screen while you type — which on
    /// iPad it is, because the inspector is a column — without anything needing
    /// to be recomputed on the actor that is accepting the keystrokes.
    @Test func anEditAboveTheHeadingDoesNotMoveItsOrdinal() {
        let before = "# One\n\n## Two\n"
        let after  = "# One\n\nA new paragraph typed just now.\n\n## Two\n"

        let oldOffset = try! #require(SourceHeadingScan.offset(ofHeading: 1, in: before))
        let newOffset = try! #require(SourceHeadingScan.offset(ofHeading: 1, in: after))
        #expect(oldOffset != newOffset, "the offset moved — which is the point")
        #expect((after as NSString).substring(from: newOffset).hasPrefix("## Two"))
        // The stale offset now points at something that is not the heading.
        #expect(!(after as NSString).substring(from: oldOffset).hasPrefix("## Two"))
    }
}

/// The outline's list of headings, which the jump counts along.
struct OutlineHeadingListTests {

    /// Front matter is not a heading — and CommonMark thinks it is.
    ///
    /// `---` under a run of text is a setext underline, so a YAML block parsed
    /// as a level-2 heading titled `title: Rich Content tags: [tour]`. It was
    /// visible in the outline popover the whole time and read as a feature.
    /// Worse, it put every ordinal one out against the editor's own block
    /// parser, which knows front matter when it sees it.
    @Test func frontMatterIsNotListedAsAHeading() {
        let text = """
        ---
        title: Rich Content
        tags: [tour]
        ---

        # Rich Content

        ## Callouts
        """
        let headings = MarkdownParsing.headings(in: text)
        #expect(headings.map(\.title) == ["Rich Content", "Callouts"])
        #expect(!headings.contains { $0.title.contains("tags:") })
    }

    /// The three lists that must agree, because the jump counts along one and
    /// resolves against another.
    @Test func everyHeadingListAgrees() {
        let text = """
        ---
        title: T
        ---

        # One

        ```
        # not a heading
        ```

        ## Two

        ### Three
        """
        let outline = MarkdownParsing.headings(in: text).map(\.title)
        let fast = MarkdownParsing.fastHeadings(in: text).map(\.title)
        #expect(outline == ["One", "Two", "Three"])
        #expect(fast == outline, "the bulk index and the outline must count the same headings")

        // And the raw-source scan lands on each of them in the same order.
        let ns = text as NSString
        for (ordinal, expected) in [(0, "# One"), (1, "## Two"), (2, "### Three")] {
            let offset = try! #require(SourceHeadingScan.offset(ofHeading: ordinal, in: text))
            #expect(ns.substring(from: offset).hasPrefix(expected))
        }
    }
}
