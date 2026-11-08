//
//  ContainerPathTests.swift
//  HelloNotesTests
//
//  A path inside the app's container is named from the container, which
//  moves when the app is installed again (`ContainerPath`, implemented.md
//  §51.69): on the simulator at every install, measured, and with it went
//  every note's reading place and the collection's index cache.
//

import Foundation
import Testing
@testable import HelloNotes

struct ContainerPathTests {

    static let before = "/private/var/mobile/Containers/Data/Application/ADE7D338"
    static let after = "/var/mobile/Containers/Data/Application/2CE3E666"

    /// **Inside the container, the name is the container's own**, whichever
    /// UUID it has today and whichever of its two spellings it was handed in.
    @Test func aPathInsideTheContainerIsNamedFromIt() {
        let one = ContainerPath.stableName(of: Self.before + "/Documents/Notes/A.md", home: Self.before)
        let other = ContainerPath.stableName(of: Self.after + "/Documents/Notes/A.md", home: Self.after)
        #expect(one == "~/Documents/Notes/A.md")
        #expect(other == one)
        #expect(ContainerPath.stableName(of: "/var/mobile/Containers/Data/Application/ADE7D338/Documents",
                                         home: Self.before + "/") == "~/Documents")
        #expect(ContainerPath.stableName(of: Self.after, home: Self.after) == "~")
    }

    /// **Outside it, the path is the name** — one spelling of it — and a
    /// folder whose name merely begins with the container's is outside it.
    @Test func aPathOutsideTheContainerKeepsItsPath() {
        let iCloud = "/private/var/mobile/Library/Mobile Documents/iCloud~com~hellotham~HelloNotes/Documents/A.md"
        #expect(ContainerPath.stableName(of: iCloud, home: Self.before)
                == "/var/mobile/Library/Mobile Documents/iCloud~com~hellotham~HelloNotes/Documents/A.md")
        #expect(ContainerPath.stableName(of: Self.after + "-other/A.md", home: Self.after) == Self.after + "-other/A.md")
        #expect(ContainerPath.stableName(of: "/Users/someone/Notes/A.md", home: "/") == "/Users/someone/Notes/A.md")
    }

    /// **The index cache of a collection inside the container is found after
    /// the container moves** — keyed by the old name it was missed, and the
    /// collection walked as if never seen, at every install. The control: two
    /// collections are two caches.
    @Test func aCollectionsCacheIsFoundAfterTheContainerMoves() {
        let moved = CollectionIndexCache.cacheURL(for: URL(filePath: Self.after + "/Documents/Notes", directoryHint: .isDirectory),
                                                  home: Self.after)
        let kept = CollectionIndexCache.cacheURL(for: URL(filePath: Self.before + "/Documents/Notes", directoryHint: .isDirectory),
                                                 home: Self.before)
        #expect(moved == kept, "the cache was looked for under the container's old name")
        let another = CollectionIndexCache.cacheURL(for: URL(filePath: Self.after + "/Documents/Work", directoryHint: .isDirectory),
                                                    home: Self.after)
        #expect(another != moved)
    }
}
