//
//  BlockParserTests.swift
//  MarkdownCoreTests
//

import Foundation
import Testing
@testable import MarkdownCore

@Suite struct BlockParserTests {

    private func kinds(_ text: String) -> [BlockKind] {
        BlockParser.fullParse(text as NSString).blocks.map(\.kind)
    }

    // MARK: - CRLF

    /// `contentRange` strips the `\n` but not the `\r`, so every structural
    /// classifier saw a trailing carriage return and refused to match. A file
    /// saved on Windows parsed its setext headings, thematic breaks and front
    /// matter as ordinary paragraphs.
    @Test func crlfDocumentsClassifyLikeLFOnes() {
        let lf = "---\ntitle: T\n---\n\nHeading\n=======\n\nSub\n---\n\n***\n\ntail\n"
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(kinds(crlf) == kinds(lf))

        // And spelled out, so a future change can't quietly make both wrong.
        let crlfKinds = kinds(crlf)
        #expect(crlfKinds.contains { if case .frontMatter = $0 { return true }; return false })
        #expect(crlfKinds.contains { if case .heading(1, true) = $0 { return true }; return false })
        #expect(crlfKinds.contains { if case .heading(2, true) = $0 { return true }; return false })
        #expect(crlfKinds.contains { if case .thematicBreak = $0 { return true }; return false })
    }

    /// Consecutive blank lines are one run, not one block each. The merge test
    /// used to sit after `closeOpen`, which had already reset the open state.
    @Test func consecutiveBlankLinesMergeIntoOneBlock() {
        // No trailing newline: one would add a final empty line, which is a
        // second (legitimate) blank run and obscures what's being tested.
        let parsed = BlockParser.fullParse("para\n\n\n\n# H" as NSString)
        let blanks = parsed.blocks.filter { if case .blank = $0.kind { return true }; return false }
        #expect(blanks.count == 1)
        #expect(blanks.first?.lineCount == 3)
    }

    // MARK: - Tiling invariant

    @Test func blocksTileTheDocument() {
        let text = """
        # Title

        Paragraph one
        continues here.

        ```swift
        let x = 1
        ```

        - item
        > quote
        """
        let result = BlockParser.fullParse(text as NSString)
        var expected = 0
        for b in result.blocks {
            #expect(b.range.location == expected, "gap or overlap before \(b.kind)")
            expected = b.range.location + b.range.length
        }
        #expect(expected == (text as NSString).length)
    }

    // MARK: - Headings

    @Test func atxHeadings() {
        #expect(kinds("# One") == [.heading(level: 1, setext: false)])
        #expect(kinds("### Three") == [.heading(level: 3, setext: false)])
        #expect(kinds("####### seven") == [.paragraph])   // > 6 = paragraph
        #expect(kinds("#nospace") == [.paragraph])        // tag-like, not heading
    }

    @Test func setextHeadings() {
        #expect(kinds("Title\n===") == [.heading(level: 1, setext: true)])
        #expect(kinds("Title\n---") == [.heading(level: 2, setext: true)])
        // No open paragraph → dashes are a thematic break.
        #expect(kinds("---") == [.thematicBreak])
        #expect(kinds("Para\n\n---") == [.paragraph, .blank, .thematicBreak])
    }

    @Test func setextHeadingsWithTrailingNewline() {
        // The realistic case: the underline line has a trailing newline.
        #expect(kinds("Title\n===\n") == [.heading(level: 1, setext: true), .blank])
        #expect(kinds("Title\n===\n\nNext") == [.heading(level: 1, setext: true), .blank, .paragraph])
        #expect(kinds("Title\n---\n\nNext") == [.heading(level: 2, setext: true), .blank, .paragraph])
    }

    // MARK: - Fences

    @Test func closedFence() {
        let text = "```swift\ncode\n```"
        #expect(kinds(text) == [.fencedCode(info: "swift", closed: true)])
    }

    @Test func unclosedFenceSwallowsRest() {
        let text = "```\ncode\nmore text\n# not a heading"
        #expect(kinds(text) == [.fencedCode(info: "", closed: false)])
    }

    @Test func fenceCloseNeedsMatchingMarker() {
        // ~~~ cannot close ``` — the fence stays open to EOF.
        #expect(kinds("```\ncode\n~~~") == [.fencedCode(info: "", closed: false)])
        // A longer close run is fine.
        #expect(kinds("```\ncode\n`````") == [.fencedCode(info: "", closed: true)])
    }

    @Test func tildeFence() {
        #expect(kinds("~~~\nx\n~~~") == [.fencedCode(info: "", closed: true)])
    }

    // MARK: - Front matter

    @Test func frontMatterAtTop() {
        let text = "---\ntitle: Hi\n---\nBody"
        #expect(kinds(text) == [.frontMatter, .paragraph])
    }

    @Test func frontMatterRequiresClose() {
        // No closing fence → the dashes are a thematic break, not front matter.
        let text = "---\ntitle: Hi\nBody"
        let k = kinds(text)
        #expect(k.first == .thematicBreak)
        #expect(!k.contains(.frontMatter))
    }

    @Test func frontMatterOnlyAtLineZero() {
        let text = "Body\n\n---\nkey: value\n---"
        #expect(!kinds(text).contains(.frontMatter))
    }

    /// A note that opens with a horizontal rule and carries another one further
    /// down used to lose everything between them: front matter folds, so the
    /// first section was concealed and the note appeared to begin at the second
    /// rule. The closing fence was hunted 200 lines away, so there was no
    /// practical limit on how much could vanish.
    @Test func frontMatterNeedsAProperty() {
        let text = "---\n\n# Chapter one\n\nSome text.\n\n---\n\n# Chapter two"
        let k = kinds(text)
        #expect(!k.contains(.frontMatter))
        #expect(k.first == .thematicBreak)
        #expect(k.contains(.heading(level: 1, setext: false)))
    }

    /// GFM spec #68. Two `---` lines with nothing between them carry no
    /// property, and `FrontMatter.applying` deletes the block outright when the
    /// last property goes — so an empty one is not something HelloNotes would
    /// ever have written. Every other Markdown tool reads it as two rules.
    @Test func twoBareFencesAreTwoRules() {
        #expect(kinds("---\n---") == [.thematicBreak, .thematicBreak])
    }

    /// GFM spec #66. `Foo` is a bare YAML scalar, not a mapping, so the second
    /// `---` is a setext underline and not a closing fence.
    @Test func aScalarBetweenFencesIsASetextHeading() {
        #expect(kinds("---\nFoo\n---\nBar\n---\nBaz") == [
            .thematicBreak,
            .heading(level: 2, setext: true),
            .heading(level: 2, setext: true),
            .paragraph,
        ])
    }

    /// A `#` line is a legal YAML comment *and* the commonest way a note's
    /// first heading is written, so it cannot be the entry that proves the
    /// block is a mapping.
    @Test func aCommentAloneIsNotAProperty() {
        #expect(!kinds("---\n# just a comment\n---\nBody").contains(.frontMatter))
    }

    /// The colon has to end the line or be followed by a space, or a diary line
    /// or a bare URL would fold the note away again.
    @Test func aTimeOrAURLIsNotAProperty() {
        #expect(!kinds("---\n12:30 standup\n---\nBody").contains(.frontMatter))
        #expect(!kinds("---\nhttps://example.org/x\n---\nBody").contains(.frontMatter))
        #expect(kinds("---\nwhen: 12:30 standup\n---\nBody").first == .frontMatter)
    }

    /// One property is enough — the rest of the block is the user's, prose and
    /// all. Demanding that *every* interior line look like YAML would throw
    /// away real front matter that has a stray line in it.
    @Test func onePropertyCarriesTheWholeBlock() {
        #expect(kinds("---\ntitle: Hi\n\nloose prose\n---\nBody").first == .frontMatter)
        #expect(kinds("---\ntags:\n  - a\n  - b\n---\nBody").first == .frontMatter)
    }

    // MARK: - Quotes, callouts, lists, tables

    @Test func quoteRunsGroup() {
        #expect(kinds("> a\n> b") == [.blockquote(callout: nil)])
        #expect(kinds("> a\n\n> b") == [.blockquote(callout: nil), .blank, .blockquote(callout: nil)])
    }

    @Test func calloutDetected() {
        #expect(kinds("> [!note]\n> body") == [.blockquote(callout: "note")])
        #expect(kinds("> [!TIP] Title\n> body") == [.blockquote(callout: "tip")])
    }

    @Test func listItems() {
        let k = kinds("- one\n- two\n  continued\n1. ordered")
        #expect(k.count == 3)
        guard case .listItem(let a) = k[0], case .listItem(let b) = k[1], case .listItem(let c) = k[2] else {
            Issue.record("expected three list items, got \(k)"); return
        }
        #expect(a.isOrdered == false)
        #expect(b.isOrdered == false)
        #expect(c.isOrdered == true)
    }

    @Test func taskItems() {
        let k = kinds("- [ ] todo\n- [x] done")
        guard case .listItem(let a) = k[0], case .listItem(let b) = k[1] else {
            Issue.record("expected task items, got \(k)"); return
        }
        #expect(a.task == .unchecked)
        #expect(b.task == .checked)
    }

    @Test func tableNeedsDelimiterRow() {
        #expect(kinds("| a | b |\n|---|---|\n| 1 | 2 |") == [.table])
        // A pipe line alone is just a paragraph.
        #expect(kinds("| a | b |\njust text") == [.paragraph])
    }

    /// GFM: "The delimiter row must match the header row in the number of
    /// cells. If not, a table will not be recognized." Accepted anyway, the
    /// editor drew a two-column grid over a document the page renders as three
    /// lines of prose.
    @Test func aDelimiterRowMustMatchItsHeadersCellCount() {
        #expect(kinds("| abc | def |\n| --- |\n| bar |") == [.paragraph])
        #expect(kinds("| abc |\n| --- | --- |\n| bar |") == [.paragraph])
        // Escaped pipes are counted as text on both lines, so the two still
        // match: one column each.
        #expect(kinds("| f\\|oo  |\n| ------ |\n| b im |") == [.table])
    }

    /// A table row does not have to contain a pipe. GFM breaks a table "at the
    /// first empty line, or beginning of another block-level structure" — and
    /// prose is neither, so the line below the last row is a one-cell row.
    /// Ended there, the editor showed a grid and a paragraph where the page
    /// shows one more row: a whole block margin apart.
    @Test func aPlainLineContinuesATablesBody() {
        #expect(kinds("| a | b |\n| - | - |\n| 1 | 2 |\nbar") == [.table])
        // A blank line still closes it…
        #expect(kinds("| a | b |\n| - | - |\n| 1 | 2 |\n\nbar") == [.table, .blank, .paragraph])
        // …and so does the start of another block.
        #expect(kinds("| a | b |\n| - | - |\n| 1 | 2 |\n> quoted")
                == [.table, .blockquote(callout: nil)])
        #expect(kinds("| a | b |\n| - | - |\n| 1 | 2 |\n# head")
                == [.table, .heading(level: 1, setext: false)])
    }

    /// The item's content column is where its content *begins*, and a checkbox
    /// is content: `- [x] a` opens at column 2 exactly as `- a` does. Measured
    /// past the checkbox it came out 3, so a sub-list needed three spaces of
    /// indent to count as nested and the two everybody writes read as a
    /// sibling — `li + li`'s 4pt where the page puts `ul ul`'s nothing.
    @Test func aCheckboxIsContentNotMarker() {
        guard case .listItem(let task) = kinds("- [x] foo")[0],
              case .listItem(let plain) = kinds("- foo")[0] else {
            Issue.record("expected list items"); return
        }
        #expect(task.contentColumn == plain.contentColumn)
        #expect(task.contentColumn == 2)
        // …while the *offset* still points past it, because that is where the
        // text is drawn.
        #expect(task.contentOffset == 6)
        #expect(plain.contentOffset == 2)
        // A wider marker moves both together.
        guard case .listItem(let ordered) = kinds("10. [ ] foo")[0] else {
            Issue.record("expected an ordered task item"); return
        }
        #expect(ordered.contentColumn == 4)
        #expect(ordered.contentOffset == 8)
    }

    // MARK: - Math blocks

    @Test func mathBlock() {
        #expect(kinds("$$\nx^2\n$$") == [.mathBlock(closed: true)])
        #expect(kinds("$$x^2$$") == [.mathBlock(closed: true)])
        #expect(kinds("$$\nx^2") == [.mathBlock(closed: false)])
    }

    // MARK: - Incremental == full (targeted edits)

    private func assertIncrementalMatchesFull(_ original: String, edit: (NSRange, String)) {
        let old = BlockParser.fullParse(original as NSString)
        let ns = NSMutableString(string: original)
        ns.replaceCharacters(in: edit.0, with: edit.1)
        let textEdit = TextEdit(range: edit.0, replacementLength: (edit.1 as NSString).length)
        let incremental = BlockParser.incremental(ns as NSString, edit: textEdit, previous: old)
        let full = BlockParser.fullParse(ns as NSString)
        #expect(incremental.blocks == full.blocks, "incremental diverged for edit \(edit)")
        #expect(incremental.lines == full.lines)
    }

    @Test func incrementalTypedCharacter() {
        assertIncrementalMatchesFull("# Title\n\nBody text here", edit: (NSRange(location: 12, length: 0), "x"))
    }

    @Test func incrementalOpensFence() {
        // Typing ``` at the top flips everything below into a fence.
        assertIncrementalMatchesFull("Para\n\nMore\n\nText", edit: (NSRange(location: 0, length: 0), "```\n"))
    }

    @Test func incrementalClosesFence() {
        assertIncrementalMatchesFull("```\ncode\nmore\nrest", edit: (NSRange(location: 9, length: 0), "```\n"))
    }

    @Test func incrementalDeletesBlankBetweenParagraphs() {
        assertIncrementalMatchesFull("aaa\n\nbbb", edit: (NSRange(location: 4, length: 1), ""))
    }

    @Test func incrementalMakesSetext() {
        assertIncrementalMatchesFull("Title\nbody", edit: (NSRange(location: 6, length: 0), "===\n"))
    }

    @Test func incrementalEditInsideFrontMatter() {
        assertIncrementalMatchesFull("---\ntitle: x\n---\nBody", edit: (NSRange(location: 11, length: 1), "y"))
    }

    /// Typing the colon is what turns two rules and a setext heading into front
    /// matter, and it happens *below* the opening fence — the one edit the
    /// incremental walk cannot resolve locally, because the block it creates
    /// starts on a line the damage window never reaches.
    @Test func incrementalTypingAPropertyMakesFrontMatter() {
        assertIncrementalMatchesFull("---\nFoo\n---\nBody", edit: (NSRange(location: 7, length: 0), ": bar"))
    }

    @Test func incrementalDeletingTheLastPropertyDissolvesFrontMatter() {
        assertIncrementalMatchesFull("---\nFoo: bar\n---\nBody", edit: (NSRange(location: 7, length: 5), ""))
    }

    @Test func incrementalBreaksFrontMatterOpen() {
        // Deleting a dash from the opening fence dissolves the front matter.
        assertIncrementalMatchesFull("---\ntitle: x\n---\nBody", edit: (NSRange(location: 0, length: 1), ""))
    }

    @Test func incrementalPasteMultipleBlocks() {
        assertIncrementalMatchesFull("start\n\nend", edit: (NSRange(location: 7, length: 0), "# H\n\n- a\n- b\n\n"))
    }

    @Test func incrementalDeleteAcrossBlocks() {
        assertIncrementalMatchesFull("# H\n\npara one\n\n> quote\n\nlast", edit: (NSRange(location: 3, length: 14), ""))
    }

    @Test func incrementalAtVeryEnd() {
        assertIncrementalMatchesFull("abc\ndef", edit: (NSRange(location: 7, length: 0), "\nghi"))
    }

    @Test func incrementalEmptyDocumentInsert() {
        assertIncrementalMatchesFull("", edit: (NSRange(location: 0, length: 0), "# Hello"))
    }
}

/// Container blocks hold *blocks*, not lines. These are the three places where
/// the editor's flat block list has to agree with cmark's tree about where a
/// container ends, because getting it wrong shows up as a layout shift between
/// Edit and Preview rather than as a parse error.
@Suite struct ContainerBlockTests {

    private func kinds(_ text: String) -> [BlockKind] {
        BlockParser.fullParse(text as NSString).blocks.map(\.kind)
    }

    private func blocks(_ text: String) -> [Block] {
        BlockParser.fullParse(text as NSString).blocks
    }

    private func isItem(_ kind: BlockKind) -> Bool {
        if case .listItem = kind { return true }; return false
    }

    // MARK: - A blank line does not always end a list item

    @Test func anIndentedContinuationKeepsTheItemOpen() {
        // `  two` is indented to the item's content column, so it belongs to
        // the item — one loose item holding two paragraphs.
        let items = blocks("- one\n\n  two").filter { isItem($0.kind) }
        #expect(items.count == 1)
        #expect(items.first?.lineCount == 3)
    }

    @Test func anUnindentedLineAfterABlankEndsTheItem() {
        let all = kinds("- one\n\ntwo")
        #expect(all.count == 3)
        #expect(isItem(all[0]))
        if case .paragraph = all[2] {} else { Issue.record("expected a paragraph after the list") }
    }

    @Test func aFollowingMarkerStartsANewItemRatherThanContinuing() {
        let items = blocks("- one\n\n- two").filter { isItem($0.kind) }
        #expect(items.count == 2)
    }

    // MARK: - Lazy continuation inside a blockquote

    @Test func anUnprefixedLineContinuesTheQuotesParagraph() {
        let all = blocks("> bar\nbaz")
        #expect(all.count == 1)
        if case .blockquote = all[0].kind {} else { Issue.record("expected one blockquote") }
        #expect(all[0].lineCount == 2)
    }

    /// After a `>` on its own the quote's paragraph has ended, so there is
    /// nothing to continue and the next unprefixed line starts a new block.
    @Test func nothingContinuesLazilyAfterAnEmptyQuoteLine() {
        let all = kinds(">\nbaz")
        #expect(all.count == 2)
        if case .blockquote = all[0] {} else { Issue.record("expected a blockquote first") }
        if case .paragraph = all[1] {} else { Issue.record("expected a paragraph second") }
    }

    // MARK: - A lone `-`

    /// With no paragraph above it, a single `-` is an empty list item — and the
    /// list carries on across it.
    @Test func aLoneDashWithNoParagraphIsAnEmptyListItem() {
        let items = blocks("- foo\n-\n- bar").filter { isItem($0.kind) }
        #expect(items.count == 3)
    }

    /// …but after a paragraph the same character is a setext underline, and
    /// that reading must win.
    @Test func aLoneDashAfterAParagraphIsStillASetextHeading() {
        let all = kinds("foo\n-")
        #expect(all.count == 1)
        if case .heading(2, true) = all[0] {} else { Issue.record("expected a setext h2") }
    }

    /// "A list item can begin with at most one blank line." An item whose
    /// marker line carries nothing has used its one up, so a blank line after
    /// it ends the item: `-` / blank / `  foo` is an empty item followed by a
    /// paragraph, not an item holding `foo`.
    @Test func anItemBeginningWithABlankLineMayNotHaveASecond() {
        let all = kinds("-\n\n  foo")
        #expect(all.filter { if case .listItem = $0 { return true }; return false }.count == 1)
        #expect(all.contains { if case .paragraph = $0 { return true }; return false })
    }

    /// …but content on the very next line still belongs to the item.
    @Test func contentDirectlyUnderAnEmptyMarkerStaysInTheItem() {
        let items = blocks("-   \n  foo").filter { isItem($0.kind) }
        #expect(items.count == 1)
        #expect(items.first?.lineCount == 2)
    }

    // MARK: - What may interrupt a paragraph

    /// An *empty* list item may not. `*foo bar` then a lone `*` is one
    /// paragraph; reading the `*` as a marker broke a sentence in two.
    @Test func anEmptyListItemCannotInterruptAParagraph() {
        let all = kinds("*foo bar\n*")
        #expect(all.count == 1)
        if case .paragraph = all[0] {} else { Issue.record("expected one paragraph") }
    }

    @Test func aNonEmptyListItemStillInterruptsAParagraph() {
        let all = kinds("foo\n- bar")
        #expect(all.count == 2)
        #expect(isItem(all[1]))
    }

    /// A setext underline needs heading *text* above it, and a reference
    /// definition is consumed before setext is considered — so `[foo]: /url`
    /// then `===` is a definition and a paragraph, not an h1.
    @Test func aSetextUnderlineDoesNotApplyToReferenceDefinitions() {
        let all = kinds("[foo]: /url\n===\n[foo]")
        #expect(!all.contains { if case .heading(_, true) = $0 { return true }; return false })
    }

    /// Indented to a list item's content column with text above it, a line of
    /// dashes underlines that text rather than ruling off the list — the spec
    /// gives setext precedence when a line could be either.
    @Test func aDashLineInsideAListItemUnderlinesTheTextAboveIt() {
        let all = kinds("- Bar\n  ---\n  baz")
        #expect(!all.contains { if case .thematicBreak = $0 { return true }; return false })
        #expect(all.filter { if case .listItem = $0 { return true }; return false }.count == 1)
    }

    /// At the outer indent it still ends the list and rules off.
    @Test func aDashLineAtTheOuterIndentIsStillAThematicBreak() {
        #expect(kinds("- foo\n---").contains { if case .thematicBreak = $0 { return true }; return false })
    }

    @Test func aSetextUnderlineStillAppliesToRealText() {
        let all = kinds("Foo\n===")
        #expect(all.count == 1)
        if case .heading(1, true) = all[0] {} else { Issue.record("expected a setext h1") }
    }

    @Test func threeDashesAreStillAThematicBreak() {
        let all = kinds("- foo\n\n---\n\n- bar")
        #expect(all.contains { if case .thematicBreak = $0 { return true }; return false })
    }
}

/// Line-level rules that decide a block's *kind*, each one found by a spec
/// example laying out differently from Preview.
@Suite struct LineClassificationTests {

    private func kinds(_ text: String) -> [BlockKind] {
        BlockParser.fullParse(text as NSString).blocks.map(\.kind)
    }

    private func has(_ text: String, _ match: (BlockKind) -> Bool) -> Bool {
        kinds(text).contains(where: match)
    }

    /// A setext underline may carry trailing whitespace. Counting those spaces
    /// against it sent `Foo` / `   ----   ` to the thematic-break branch, so a
    /// heading someone had lined up became a paragraph and a rule.
    @Test func aSetextUnderlineMayHaveTrailingWhitespace() {
        #expect(has("Foo\n   ----      ") { if case .heading(2, true) = $0 { return true }; return false })
        #expect(has("Foo\n---") { if case .heading(2, true) = $0 { return true }; return false })
    }

    @Test func realThematicBreaksSurvive() {
        #expect(has("---") { if case .thematicBreak = $0 { return true }; return false })
        #expect(has("- - -") { if case .thematicBreak = $0 { return true }; return false })
        #expect(has("***") { if case .thematicBreak = $0 { return true }; return false })
    }

    /// Counted in dashes, not characters: `-   ` is one dash and three spaces,
    /// which is an empty list item, not a rule.
    @Test func aThematicBreakNeedsThreeDashesNotThreeCharacters() {
        #expect(!has("-   ") { if case .thematicBreak = $0 { return true }; return false })
        #expect(has("- foo\n-   \n- bar") { if case .listItem = $0 { return true }; return false })
    }

    /// A backtick fence's info string may not contain a backtick, or the same
    /// line would open a block and close it.
    @Test func aBacktickFenceInfoStringMayNotContainABacktick() {
        #expect(!has("``` ```\naaa") { if case .fencedCode = $0 { return true }; return false })
        #expect(!has("``` aa ```\nfoo") { if case .fencedCode = $0 { return true }; return false })
        #expect(has("```swift\ncode\n```") { if case .fencedCode = $0 { return true }; return false })
    }

    /// A tab separates a list marker from its content just as a space does.
    @Test func aTabMaySeparateAMarkerFromItsContent() {
        #expect(has("-\tfoo") { if case .listItem = $0 { return true }; return false })
    }

    /// An unclosed fence knows it is unclosed — its last line is code, and the
    /// renderer must not treat it as a closing fence.
    @Test func anUnclosedFenceIsMarkedUnclosed() {
        #expect(has("```\naaa") { if case .fencedCode(_, false) = $0 { return true }; return false })
        #expect(has("```\naaa\n```") { if case .fencedCode(_, true) = $0 { return true }; return false })
    }
    /// A marker line indented four or more, but short of the open item's own
    /// content column, is not inside that item — it dedents to the document,
    /// where four columns means indented code, and indented code cannot
    /// interrupt a paragraph. So it is the item's paragraph continued, and the
    /// dash is text: `   - d` then `    - e` is **one** item reading "d ⏎ - e".
    @Test func anIndentedMarkerBelowAParagraphIsLazyContinuation() {
        let blocks = BlockParser.fullParse("- a\n - b\n  - c\n   - d\n    - e\n" as NSString).blocks
        let items = blocks.filter { if case .listItem = $0.kind { return true } else { return false } }
        #expect(items.count == 4)
        #expect(items.last?.lineCount == 2)
    }

    /// Lazy continuation runs a *paragraph* on, and a fence swallows nothing:
    /// `> ``` ` then an unquoted `foo` is a quote holding an empty code block
    /// and then a paragraph. Read as continuation the unquoted text joined the
    /// quote, and everything below it went with it.
    @Test func anUnquotedLineDoesNotContinueAQuoteWithAnOpenFence() {
        let blocks = BlockParser.fullParse("> ```\nfoo\n```\n" as NSString).blocks
        #expect(blocks.first?.lineCount == 1)
        #expect(blocks.contains { if case .paragraph = $0.kind { return true } else { return false } })
        // A quoted *paragraph* still runs on as before.
        let lazy = BlockParser.fullParse("> bar\nbaz\n" as NSString).blocks
        #expect(lazy.first?.lineCount == 2)
    }

    /// A fence opened on an item's **marker line** belongs to the item, exactly
    /// as indented code on that line does. It used to be swallowed as item text
    /// and the *closing* delimiter read as a fresh, unclosed fence — so
    /// everything below `1. ``` ` in the note came out as code, to the end of
    /// the document.
    @Test func aFenceOnTheMarkerLineStaysInsideItsItem() {
        let blocks = BlockParser.fullParse("1. ```\n   foo\n   ```\n\nafter\n" as NSString).blocks
        #expect(!blocks.contains { if case .fencedCode = $0.kind { return true } else { return false } })
        let items = blocks.filter { if case .listItem = $0.kind { return true } else { return false } }
        #expect(items.count == 1)
        #expect(items.first?.lineCount == 3)
        // …and the paragraph below survives as a paragraph.
        #expect(blocks.contains { if case .paragraph = $0.kind { return true } else { return false } })
    }

    /// "In order for a list to interrupt a paragraph, it must start with 1."
    /// Prose wrapping onto a line that begins `14. ` is one paragraph — read as
    /// a marker it broke the sentence in two and put a block margin through it.
    @Test func onlyAListStartingAtOneCanInterruptAParagraph() {
        let text = "The number of windows in my house is\n14.  The number of doors is 6.\n"
        let blocks = BlockParser.fullParse(text as NSString).blocks
        #expect(!blocks.contains { if case .listItem = $0.kind { return true } else { return false } })
        // …but `1.` may.
        let one = BlockParser.fullParse("foo\n1. bar\n" as NSString).blocks
        #expect(one.contains { if case .listItem = $0.kind { return true } else { return false } })
    }

    /// With no paragraph open the same line is **indented code**: the list
    /// closed at the blank, and four columns at the document's level is a code
    /// block. `1. a` / blank / `  2. b` / blank / `    3. c` is two items and a
    /// `<pre>`, not three items.
    @Test func anIndentedMarkerAfterABlankIsIndentedCode() {
        let blocks = BlockParser.fullParse("1. a\n\n  2. b\n\n    3. c\n" as NSString).blocks
        let items = blocks.filter { if case .listItem = $0.kind { return true } else { return false } }
        #expect(items.count == 2)
        #expect(blocks.contains { if case .indentedCode = $0.kind { return true } else { return false } })
    }

    /// But a line inside the item's own content column is a nested list, blank
    /// line or not — `- a` / blank / `    - b` is one item holding a list.
    @Test func anIndentedMarkerInsideTheItemStaysANestedList() {
        let blocks = BlockParser.fullParse("- a\n\n    - b\n" as NSString).blocks
        #expect(!blocks.contains { if case .indentedCode = $0.kind { return true } else { return false } })
    }

    /// At or past the content column the line *is* inside the item, and a
    /// marker there opens a nested list — the rule above must not swallow it.
    @Test func aMarkerAtTheContentColumnStillOpensANestedList() {
        let blocks = BlockParser.fullParse("- a\n    - b\n" as NSString).blocks
        let items = blocks.filter { if case .listItem = $0.kind { return true } else { return false } }
        #expect(items.count == 2)
    }

    /// A fence written at the item's own content column is a block *inside*
    /// the item, exactly as one on the marker line is. Every fence used to
    /// close the open item outright, so the list ended at the opening
    /// delimiter and the code became a sibling of it.
    @Test func aFenceAtTheItemsContentColumnStaysInsideItsItem() {
        let blocks = BlockParser.fullParse("-\n  ```\n  bar\n  ```\n-\n  x\n" as NSString).blocks
        #expect(!blocks.contains { if case .fencedCode = $0.kind { return true } else { return false } })
        let items = blocks.filter { if case .listItem = $0.kind { return true } else { return false } }
        #expect(items.count == 2)
        #expect(items.first?.lineCount == 4)          // marker, fence, listing, fence
    }

    /// …and a fence that does *not* reach the content column still ends the
    /// item: `- foo` then an unindented fence is an item and a code block.
    @Test func aFenceShortOfTheContentColumnStillEndsTheItem() {
        let blocks = BlockParser.fullParse("- foo\n```\nbar\n```\n" as NSString).blocks
        #expect(blocks.contains { if case .fencedCode = $0.kind { return true } else { return false } })
        let items = blocks.filter { if case .listItem = $0.kind { return true } else { return false } }
        #expect(items.count == 1)
        #expect(items.first?.lineCount == 1)
    }

    /// Four columns at the **document's** own level is indented code, list
    /// marker or not. The demotion used to require a `mostRecentItem()` to be
    /// short of, so a note opening `    1.  A paragraph` — a `<pre>` to every
    /// renderer — came out as a list, and every line under it as its prose.
    @Test func aMarkerAtColumnFourWithNoListAboveIsIndentedCode() {
        let text = "    1.  A paragraph\n        with two lines.\n\n            indented code"
        let blocks = BlockParser.fullParse(text as NSString).blocks
        #expect(!blocks.contains { if case .listItem = $0.kind { return true } else { return false } })
        let code = blocks.filter { if case .indentedCode = $0.kind { return true } else { return false } }
        // One box, not one per chunk: a blank line does not end an indented
        // code block, and the marker line must not start a second one.
        #expect(code.count == 1)
        #expect(code.first?.lineCount == 4)
        // Three columns is still a list.
        let shallow = BlockParser.fullParse("   1.  A paragraph\n" as NSString).blocks
        #expect(shallow.contains { if case .listItem = $0.kind { return true } else { return false } })
    }

    /// A paragraph inside a list item runs on to a line carrying none of the
    /// item's indent, exactly as a paragraph inside a blockquote runs on to a
    /// line carrying no `>`. The quote branch has always had the rule and the
    /// list branch never did, so one sentence came out as an item and a
    /// separate paragraph with a 16pt block margin through the middle of it.
    @Test func anUnindentedLineContinuesTheItemsParagraph() {
        let blocks = BlockParser.fullParse("  1.  A paragraph\nwith two lines.\n" as NSString).blocks
        let items = blocks.filter { if case .listItem = $0.kind { return true } else { return false } }
        #expect(items.count == 1)
        #expect(items.first?.lineCount == 2)
        #expect(!blocks.contains { if case .paragraph = $0.kind { return true } else { return false } })
    }

    /// Only a *paragraph* runs on. A heading, a rule and a code block inside
    /// the item all close it, so the unindented line below them starts
    /// something of its own — the same guard `quoteLineHasContent` applies.
    @Test func nothingButAParagraphContinuesAnItemLazily() {
        for interior in ["- # Foo", "- Foo\n  ---", "-     code"] {
            let blocks = BlockParser.fullParse("\(interior)\nbar\n" as NSString).blocks
            #expect(blocks.contains { if case .paragraph = $0.kind { return true } else { return false } },
                    "`bar` should not have joined \(interior)")
        }
    }

}
