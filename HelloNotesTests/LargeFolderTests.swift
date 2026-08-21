//
//  LargeFolderTests.swift
//  HelloNotesTests
//
//  The large-folder warning, on both platforms.
//
//  It was an `NSAlert` inside `Library`'s `#if os(macOS)` block, so iPad had no
//  warning at all: picking a 2,000-note vault there opened it with nothing said
//  and no way to narrow the choice — on the platform where the wait is longest
//  and where the picker is most likely to land on a whole iCloud Drive folder.
//
//  What is asserted here is the *judgement*, which is the part that was
//  unreachable while it lived behind a modal button press.
//

import Foundation
import Testing
@testable import HelloNotes

struct LargeFolderTests {

    private func estimate(items: Int, remaining: Int = 0, complete: Bool)
        -> Library.FolderSizeEstimate {
        Library.FolderSizeEstimate(itemsSeen: items,
                                   directoriesRemaining: remaining,
                                   isComplete: complete)
    }

    /// A finished walk is never "large", however much it found: the probe saw
    /// the whole tree inside a second, so opening it is not the wait the
    /// warning exists to announce.
    @Test func aCompletedWalkIsNeverLarge() {
        #expect(estimate(items: 50_000, complete: true).looksLarge == false)
        #expect(estimate(items: 0, complete: true).looksLarge == false)
    }

    /// The signal is *both* halves: a second was not enough **and** there is
    /// already a lot here. Either alone is an ordinary folder on a slow disk.
    @Test func largeMeansUnfinishedAndAlreadyBig() {
        #expect(estimate(items: 5_000, complete: false).looksLarge)
        #expect(estimate(items: 4_999, complete: false).looksLarge == false)
        #expect(estimate(items: 100, remaining: 900, complete: false).looksLarge == false)
    }

    /// The message says what was *seen*, not a total — the walk stopped early,
    /// so "at least" is the only honest quantifier.
    @Test func theMessageDoesNotClaimATotal() {
        let text = LargeFolderAlert.explanation(
            estimate(items: 12_000, remaining: 40, complete: false))
        #expect(text.contains("at least"))
        #expect(text.contains("12,000") || text.contains("12000"))
        #expect(text.contains("40"))
        #expect(!text.contains("12,040"), "the two numbers are not a sum")
    }

    /// Singular and plural both read as English.
    @Test func theMessageCountsFoldersInWords() {
        let one = LargeFolderAlert.explanation(
            estimate(items: 9_000, remaining: 1, complete: false))
        #expect(one.contains("1 more folder"))
        #expect(!one.contains("1 more folders"))

        let none = LargeFolderAlert.explanation(
            estimate(items: 9_000, remaining: 0, complete: false))
        #expect(!none.contains("folder"), "no unfinished folders, no clause about them")
    }
}
