//
//  ListLoosenessTests.swift
//  MarkdownEditorTests
//
//  A list is loose when its own items are separated by blank lines, or when
//  one of its items *directly* contains two blocks with a blank line between
//  them. Both halves of that sentence used to be wrong: "its own items" was
//  every block at `indent / 2 >= depth`, so a blank belonging to an item two
//  levels down loosened the outermost list, and "directly contains" was any
//  blank line in the item's source, so the blank lines inside a fenced code
//  block did it too.
//
//  It is worth its own file because getting it wrong is not a corpus
//  curiosity: a loose list wraps every item's text in a `<p>` with 16pt
//  margins, so one wrong answer is 16pt per item on an ordinary note.
//

import Foundation
import Testing
@testable import MarkdownEditor
@testable import MarkdownCore

@Suite struct ListLoosenessTests {

    /// Is the list owning the item that `needle` starts loose?
    private func loose(_ text: String, item needle: String) -> Bool {
        let ns = text as NSString
        let blocks = BlockParser.fullParse(ns).blocks
        let loc = ns.range(of: needle).location
        guard loc != NSNotFound else {
            Issue.record("no such item: \(needle)")
            return false
        }
        guard let index = blocks.firstIndex(where: {
            BlockBoxes.isListItemBlock($0) && NSLocationInRange(loc, $0.range)
        }) else {
            Issue.record("`\(needle)` is not inside a list item")
            return false
        }
        return BlockBoxes.listIsLoose(around: index, in: blocks, text: ns)
    }

    // MARK: - The plain cases

    @Test func adjacentItemsAreTightAndSeparatedOnesAreLoose() {
        #expect(!loose("- a\n- b\n", item: "- a"))
        #expect(loose("- a\n\n- b\n", item: "- a"))
        #expect(loose("- a\n\n- b\n", item: "- b"))
        // An item that swallowed a blank line of its own is loose too, and no
        // blank *block* separates the items in that case — the blank is inside
        // the item (see `BlockParser`'s list continuation rule).
        #expect(loose("- a\n\n  a2\n- b\n", item: "- b"))
    }

    /// Two lists, not one: `1.` after `-` starts a new list, so the blank line
    /// between them loosens neither.
    @Test func aChangeOfMarkerEndsTheListRatherThanLooseningIt() {
        #expect(!loose("- a\n\n1. b\n", item: "- a"))
        #expect(!loose("- a\n\n1. b\n", item: "1. b"))
    }

    // MARK: - Nesting

    /// A blank line owned by an item two levels down loosens *that* list and
    /// nothing above it. Admitting every block at `listDepth >= depth` made
    /// the outermost list loose as well, which is 16pt around every one of its
    /// items for a gap the reader never sees at that level.
    @Test func aBlankOwnedByANestedItemLoosensOnlyThatList() {
        let text = "- foo\n  - bar\n    - baz\n\n\n      bim\n"
        #expect(!loose(text, item: "- foo"))
        #expect(!loose(text, item: "  - bar"))
        #expect(loose(text, item: "    - baz"))
    }

    /// The same shape one level shallower, and with the blank between two
    /// *blocks* of the nested item rather than at the end of it.
    @Test func aLooseSubListLeavesItsParentTight() {
        let text = "- a\n  - b\n\n    c\n- d\n"
        #expect(!loose(text, item: "- a"))
        #expect(loose(text, item: "  - b"))
    }

    /// A blank line between two children of the **same** item loosens that
    /// item's own list. The scan used to walk only `.listItem` blocks, so the
    /// paragraph the parser had to dedent out of the nested item — it is short
    /// of *its* content column but not of the outer item's — fell outside the
    /// range and the gap was never seen.
    @Test func aBlankBetweenTwoChildrenOfOneItemLoosensIt() {
        #expect(loose("* foo\n  * bar\n\n  baz\n", item: "* foo"))
        #expect(!loose("* foo\n  * bar\n\n  baz\n", item: "  * bar"))
        // The item's own text above the gap counts just as its second
        // paragraph below it does: `1.  foo` / blank / `    - bar` is a loose
        // item holding a paragraph and a tight sub-list.
        #expect(loose("1.  foo\n\n    - bar\n", item: "1.  foo"))
        #expect(!loose("1.  foo\n\n    - bar\n", item: "    - bar"))
    }

    /// …but a blank between two items of a nested list is that list's own.
    @Test func aBlankBetweenTwoNestedItemsLeavesTheOuterListTight() {
        let text = "- a\n  - b\n\n  - c\n"
        #expect(!loose(text, item: "- a"))
        #expect(loose(text, item: "  - b"))
    }

    /// "A list item can begin with at most one blank line", so `-` on its own
    /// has used its up: the paragraph below is the document's, however far it
    /// is indented. Adopted as the item's second block it made a one-item list
    /// loose and put a `<p>`'s margins around an empty `<li>`.
    @Test func anEmptyItemDoesNotAdoptTheParagraphBelowIt() {
        #expect(!loose("-\n\n  foo\n", item: "-"))
    }

    // MARK: - Membership is the content column, not the indent

    /// `1. a` / blank / `  2. b` are two items of one list: `  2. b` is
    /// indented two columns and `1. a`'s content starts at three, so it never
    /// reaches the column that would nest it. Scoring membership by
    /// `indent / 2` put them at different depths and read them as two lists,
    /// so a genuinely loose list came out tight — while `box(at:)`, which had
    /// always compared content columns, gave the second item the `li + li`
    /// margin of a list it was not a member of.
    @Test func membershipFollowsTheContentColumnNotTheIndent() {
        let text = "1. a\n\n  2. b\n\n    3. c\n"
        #expect(loose(text, item: "1. a"))
        #expect(loose(text, item: "  2. b"))
        // Items stepped one space at a time are siblings all the way down.
        #expect(!loose("- foo\n - bar\n  - baz\n", item: "- foo"))
        #expect(loose("- foo\n\n - bar\n", item: "- foo"))
    }

    // MARK: - Blank lines the reader never sees

    /// A fence keeps whatever is written in it, blank lines included, and they
    /// are not the item's own. Counted as the item's, a list whose only blank
    /// lines are inside a code box gained 16pt of margin around every item.
    @Test func blankLinesInsideAFenceDoNotLoosenTheList() {
        #expect(!loose("- a\n- ```\n  b\n\n\n  ```\n- c\n", item: "- a"))
        // The fence written on the item's own marker line, which is where the
        // scan has to start past the marker to see the delimiter at all.
        #expect(!loose("- ```\n  b\n\n  ```\n- c\n", item: "- ```"))
        // …and a blank line genuinely outside the fence still loosens it.
        #expect(loose("- ```\n  b\n  ```\n\n  after\n- c\n", item: "- c"))
    }

    // MARK: - What the looseness is spent on

    /// The margin between an item's text and a sub-list belongs to whichever
    /// side wraps its text in a `<p>`. Asking only the parent left every loose
    /// sub-list 16pt short, and `- a` / `  - b` / blank / `    c` is the
    /// ordinary way to write one.
    @Test func aLooseSubListHasAMarginAboveIt() {
        let text = "- a\n  - b\n\n    c\n- d\n"
        let ns = text as NSString
        let blocks = BlockParser.fullParse(ns).blocks
        let m = GFMBoxMetrics(base: 16)
        let sub = blocks.firstIndex { BlockBoxes.isListItemBlock($0)
            && NSLocationInRange(ns.range(of: "  - b").location, $0.range) }
        #expect(sub != nil)
        if let sub, case .listItem(let top, _) = BlockBoxes.box(at: sub, in: blocks, text: ns) {
            #expect(top == .opensNestedList(spaced: true))
        } else {
            Issue.record("expected a nested list-item box")
        }
        // …and the mirror below it: the last `<p>` of the loose sub-list has a
        // margin-bottom that `ul ul { margin-bottom: 0 }` does not stop.
        if let sub {
            #expect(BlockBoxes.gapAfter(sub, in: blocks, text: ns, metrics: m) == m.blockGap)
        }
        // A *tight* sub-list gets neither.
        let tight = "- a\n  - b\n- d\n" as NSString
        let tightBlocks = BlockParser.fullParse(tight).blocks
        if let i = tightBlocks.firstIndex(where: { BlockBoxes.isListItemBlock($0)
            && NSLocationInRange(tight.range(of: "  - b").location, $0.range) }) {
            if case .listItem(let top, _) = BlockBoxes.box(at: i, in: tightBlocks, text: tight) {
                #expect(top == .opensNestedList(spaced: false))
            }
            #expect(BlockBoxes.gapAfter(i, in: tightBlocks, text: tight, metrics: m)
                    == m.listItemGap)
        }
    }
}
