//
//  ReadingPositionsTests.swift
//  HelloNotesTests
//
//  Where the reader was in each note, between launches (`ReadingPositions`,
//  implemented.md §51.69): an iPhone ends a suspended app when it likes, and
//  every note then opened at its top.
//

import Foundation
import Testing
@testable import HelloNotes

@MainActor
struct ReadingPositionsTests {

    /// **A note reached by either of its folder's names is one note.** An
    /// iPhone hands its folders over as `/private/var/…` and Foundation answers
    /// `/var/…` for the same one.
    @Test(.scratchDefaults) func aPlaceIsFoundUnderEitherNameOfItsFolder() {
        let defaults = ScratchDefaults.suite()
        let long = URL(filePath: "/private/var/mobile/Containers/Notes/Note.md")
        let short = URL(filePath: "/var/mobile/Containers/Notes/Note.md")
        ReadingPositions.keep(1_234, of: long, in: defaults)
        #expect(ReadingPositions.position(of: short, in: defaults) == 1_234)
        #expect(ReadingPositions.position(of: long, in: defaults) == 1_234)
    }

    /// A note left at its top keeps nothing, and leaving it there forgets
    /// where it was.
    @Test(.scratchDefaults) func aNoteLeftAtItsTopHasNoPlace() {
        let defaults = ScratchDefaults.suite()
        let note = URL(filePath: "/Users/someone/Notes/Note.md")
        ReadingPositions.keep(500, of: note, in: defaults)
        ReadingPositions.keep(nil, of: note, in: defaults)
        #expect(ReadingPositions.position(of: note, in: defaults) == nil)
        ReadingPositions.keep(0, of: note, in: defaults)
        #expect(ReadingPositions.position(of: note, in: defaults) == nil)
        #expect((defaults.array(forKey: ReadingPositions.key) ?? []).isEmpty)
    }

    /// The most recently left are kept, and no more.
    @Test(.scratchDefaults) func theMostRecentlyLeftAreKept() {
        let defaults = ScratchDefaults.suite()
        let notes = (0...ReadingPositions.limit).map { URL(filePath: "/Users/someone/Notes/\($0).md") }
        for (index, note) in notes.enumerated() { ReadingPositions.keep(index + 1, of: note, in: defaults) }
        #expect(ReadingPositions.position(of: notes[0], in: defaults) == nil, "the oldest was kept past the limit")
        #expect(ReadingPositions.position(of: notes[ReadingPositions.limit], in: defaults) == ReadingPositions.limit + 1)
        #expect((defaults.array(forKey: ReadingPositions.key) ?? []).count == ReadingPositions.limit)
    }

    /// **A place inside the app's container outlives the container's moving.**
    /// The container is a folder named by a UUID, and it moves when the app is
    /// installed again — at every install on the simulator, measured; a place
    /// kept by the old path was found by nobody, and the note opened at its
    /// top (implemented.md §51.69). The control: another note has no place.
    @Test(.scratchDefaults) func aPlaceInsideTheAppsContainerOutlivesItsMoving() {
        let defaults = ScratchDefaults.suite()
        let before = "/private/var/mobile/Containers/Data/Application/ADE7D338"
        let after = "/var/mobile/Containers/Data/Application/2CE3E666"
        ReadingPositions.keep(1_530, of: URL(filePath: before + "/Documents/Notes/Note.md"), kind: .previewOffset,
                              home: before, in: defaults)
        #expect(ReadingPositions.position(of: URL(filePath: after + "/Documents/Notes/Note.md"), kind: .previewOffset,
                                          home: after, in: defaults) == 1_530,
                "the place was lost when the container moved")
        #expect(ReadingPositions.position(of: URL(filePath: after + "/Documents/Notes/Other.md"), kind: .previewOffset,
                                          home: after, in: defaults) == nil)
    }

    /// **Preview's place is points down its page, Edit's a character of the
    /// note** — each kept under its own key, so neither is read as the other.
    @Test(.scratchDefaults) func aPreviewPlaceIsKeptApartFromACharacter() {
        let defaults = ScratchDefaults.suite()
        let note = URL(filePath: "/Users/someone/Notes/Note.md")
        ReadingPositions.keep(1_234, of: note, in: defaults)
        ReadingPositions.keep(640, of: note, kind: .previewOffset, in: defaults)
        #expect(ReadingPositions.position(of: note, in: defaults) == 1_234)
        #expect(ReadingPositions.position(of: note, kind: .previewOffset, in: defaults) == 640)
        ReadingPositions.keep(nil, of: note, kind: .previewOffset, in: defaults)
        #expect(ReadingPositions.position(of: note, kind: .previewOffset, in: defaults) == nil)
        #expect(ReadingPositions.position(of: note, in: defaults) == 1_234, "leaving Preview at the top forgot Edit's place")
    }

    /// Read entry by entry: one that is not a place is passed over, never the
    /// whole list.
    @Test(.scratchDefaults) func anEntryThatIsNotAPlaceIsPassedOver() {
        let defaults = ScratchDefaults.suite()
        let note = URL(filePath: "/Users/someone/Notes/Note.md")
        defaults.set([["note": 42], "not an entry", ["note": note.path, "at": 77]], forKey: ReadingPositions.key)
        #expect(ReadingPositions.position(of: note, in: defaults) == 77)
    }

    /// **A test host keeps no place in the person's preferences.** The suite
    /// opens notes in editors as the app does, and each editor kept its place
    /// in the app's own defaults as it was left: the places of 32 tests' notes
    /// were in the person's preferences before it was seen (implemented.md
    /// §51.72). Kept and found through the store everything uses, and not in
    /// the app's own defaults.
    @Test func aTestHostKeepsItsPlacesToItself() {
        #expect(ReadingPositions.store !== UserDefaults.standard)
        let note = FileManager.default.temporaryDirectory
            .appending(path: "ReadingPositions-\(UUID().uuidString)/Note.md")
        ReadingPositions.keep(321, of: note)
        defer { ReadingPositions.keep(nil, of: note) }
        #expect(ReadingPositions.position(of: note) == 321, "the place was not kept at all")
        #expect(ReadingPositions.position(of: note, in: .standard) == nil,
                "the place was kept in the person's preferences")
    }

    /// **A note renamed, or the folder it is in moved, keeps where it was
    /// read** — in Edit and in Preview. Kept by path, it opened at its top
    /// (implemented.md §51.72). A folder whose name only begins with the
    /// moved one's keeps its own places.
    @Test(.scratchDefaults) func aRenameOrAMoveKeepsWhereANoteWasRead() {
        let defaults = ScratchDefaults.suite()
        let root = "/Users/someone/Notes"
        let note = URL(filePath: root + "/Plan.md")
        let inside = URL(filePath: root + "/Projects/Budget.md")
        let beside = URL(filePath: root + "/Projects-old/Budget.md")
        ReadingPositions.keep(1_200, of: note, in: defaults)
        ReadingPositions.keep(480, of: note, kind: .previewOffset, in: defaults)
        ReadingPositions.keep(300, of: inside, in: defaults)
        ReadingPositions.keep(90, of: beside, in: defaults)

        let renamed = URL(filePath: root + "/Plan 2027.md")
        ReadingPositions.moved(from: note, to: renamed, in: defaults)
        #expect(ReadingPositions.position(of: renamed, in: defaults) == 1_200)
        #expect(ReadingPositions.position(of: renamed, kind: .previewOffset, in: defaults) == 480)
        #expect(ReadingPositions.position(of: note, in: defaults) == nil, "the old name kept its place too")

        ReadingPositions.moved(from: URL(filePath: root + "/Projects"), to: URL(filePath: root + "/Archive/Projects"),
                               in: defaults)
        #expect(ReadingPositions.position(of: URL(filePath: root + "/Archive/Projects/Budget.md"), in: defaults) == 300)
        #expect(ReadingPositions.position(of: beside, in: defaults) == 90, "a folder beside the moved one lost its place")
    }
}
