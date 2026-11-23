//
//  WikiPictureEmbedTests.swift
//  MarkdownEditorTests
//
//  What the editor asks its host for when a note holds `![[photo.png]]`.
//
//  The host finds a Markdown image's file by its path from the note's folder
//  and an Obsidian embed's by name, anywhere in the vault — so it must be
//  told which was written, and handed the embed's size with it. And an embed
//  inside a list item, a quote or a line of prose is a picture there as
//  much as a Markdown image is.
//

import Foundation
import Testing
@testable import MarkdownEditor
@testable import MarkdownCore

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@Suite @MainActor struct WikiPictureEmbedTests {

    /// Records what it is asked for, and answers every picture with a swatch.
    private final class Recorder: BlockRenderer, @unchecked Sendable {
        private let lock = NSLock()
        private var kinds: [BlockEmbedKind] = []
        let image: PlatformImage
        init(image: PlatformImage) { self.image = image }
        var asked: [BlockEmbedKind] { lock.withLock { kinds } }
        func render(_ kind: BlockEmbedKind, maxWidth: CGFloat, darkMode: Bool) async -> PlatformImage? {
            lock.withLock { kinds.append(kind) }
            if case .image = kind { return image }
            return nil
        }
    }

    private static func swatch() -> PlatformImage {
        let size = CGSize(width: 40, height: 20)
        #if canImport(AppKit)
        return NSImage(size: size)
        #else
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        #endif
    }

    /// Style `text` with the caret at its end, and wait until the recorder
    /// has been asked `count` times, or a second has gone.
    private func asked(for text: String, count: Int = 1) async throws -> [BlockEmbedKind] {
        let recorder = Recorder(image: Self.swatch())
        let document = EditorDocument(text: text, services: EditorServices(blockRenderer: recorder))
        document.selectionDidChange(NSRange(location: (text as NSString).length, length: 0))
        document.styleEverythingNow()
        for _ in 0..<50 where recorder.asked.count < count {
            try await Task.sleep(for: .milliseconds(20))
        }
        return recorder.asked
    }

    @Test func aParagraphEmbedIsAskedForAsWrittenAndSaysSo() async throws {
        let kinds = try await asked(for: "Intro\n\n![[photo.png|200]]\n\nAfter\n")
        #expect(kinds.contains(.image(target: "photo.png|200", isWikiEmbed: true, width: 200)), "\(kinds)")
        let markdown = try await asked(for: "Intro\n\n![](assets/My%20photo.png)\n\nAfter\n")
        #expect(markdown.contains(.image(target: "assets/My photo.png", isWikiEmbed: false)), "\(markdown)")
    }

    /// Obsidian sizes a Markdown image in its description, `![A cat|150](…)`,
    /// and the editor reads it there — on a line of its own, behind a
    /// reference, and inside a line.
    @Test func aMarkdownImagesSizeIsReadFromItsDescription() async throws {
        let plain = try await asked(for: "Intro\n\n![A cat|150](cat.png)\n\nAfter\n")
        #expect(plain.contains(.image(target: "cat.png", isWikiEmbed: false, width: 150)), "\(plain)")
        let boxed = try await asked(for: "Intro\n\n![|150x40](cat.png)\n\nAfter\n")
        #expect(boxed.contains(.image(target: "cat.png", isWikiEmbed: false, width: 150, height: 40)), "\(boxed)")
        let referenced = try await asked(for: "Intro\n\n![A cat|90][cat]\n\n[cat]: cat.png\n")
        #expect(referenced.contains(.image(target: "cat.png", isWikiEmbed: false, width: 90)), "\(referenced)")
        let inList = try await asked(for: "Steps\n\n- Open it\n- ![A cat|120](cat.png)\n\nEnd\n")
        #expect(inList.contains(.image(target: "cat.png", isWikiEmbed: false, width: 120)), "\(inList)")
        // A description that is words is not a size.
        let words = try await asked(for: "Intro\n\n![A cat|asleep](cat.png)\n\nAfter\n")
        #expect(words.contains(.image(target: "cat.png", isWikiEmbed: false)), "\(words)")
    }

    /// A list item is where an Obsidian note puts a step's screenshot. Only a
    /// picture is drawn in a line: a note shown in place has no room there.
    @Test func anEmbedInAListItemIsAPictureInTheLine() async throws {
        let kinds = try await asked(for: "Steps\n\n- Open it\n- ![[step two.png]]\n- Done\n\nEnd\n")
        #expect(kinds.contains(.image(target: "step two.png", isWikiEmbed: true)), "\(kinds)")

        let card = try await asked(for: "Steps\n\n- ![[Meeting notes]]\n\nEnd\n")
        #expect(!card.contains { if case .image = $0 { return true } else { return false } },
                "a note's card was asked for inside a line: \(card)")
    }
}

/// The addresses a Preview page names its pictures by.
@Suite struct PreviewPicturesTests {
    @Test func anAddressNamesItsFileAndOnlyAGivenAddressNamesOne() throws {
        let file = URL(fileURLWithPath: "/Vault/assets/My photo (1).png")
        let first = PreviewPictures.address(of: file, modified: Date(timeIntervalSinceReferenceDate: 10))
        #expect(first.scheme == PreviewPictures.scheme)
        #expect(PreviewPictures.file(at: first) == file)
        #expect(first.lastPathComponent == "My photo (1).png")
        // One file, one token: built again, the page is the same page — and
        // changed on disk, the picture is asked for again.
        let again = PreviewPictures.address(of: file, modified: Date(timeIntervalSinceReferenceDate: 10))
        let changed = PreviewPictures.address(of: file, modified: Date(timeIntervalSinceReferenceDate: 20))
        #expect(again == first)
        #expect(changed != first && PreviewPictures.file(at: changed) == file)
        // A path written into a page is not an address any page was given.
        let forged = try #require(URL(string: "\(PreviewPictures.scheme)://picture/Users/someone/secret.png"))
        #expect(PreviewPictures.file(at: forged) == nil)
    }
}
