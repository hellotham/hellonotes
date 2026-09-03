//
//  TransclusionTargetTests.swift
//  HelloNotesTests
//
//  `[[Examples/Nested Note]]` opened the note and `![[Examples/Nested Note]]`
//  rendered nothing.
//
//  Two resolvers disagreed about what a target meant. Wiki-link *navigation*
//  goes through the link graph, which handles aliases and relative paths —
//  `WikiLinkNavigation.resolve` says so where it calls it. Transclusion had a
//  private map keyed on the note's **title** and nothing else, so a
//  path-qualified target missed and the embed silently drew nothing.
//
//  It was found by looking: the shipped tour's Transclusion note is the one
//  page in `DefaultCollection` that demonstrates the feature, and it uses the
//  path-qualified form — so the demonstration demonstrated it not working, on
//  both platforms, to anyone who opened the app.
//

import Testing
import Foundation
@testable import HelloNotes

@Suite @MainActor
struct TransclusionTargetTests {

    /// Every trailing run of path components resolves to the same note.
    @Test func aTargetResolvesByNameOrByPath() {
        let url = URL(filePath: "/vault/Examples/Deep/Nested Note.md")
        let keys = CollectionEmbedProvider.pathKeys(for: url)
        #expect(keys.contains("nested note"), "the bare name has to work")
        #expect(keys.contains("deep/nested note"))
        #expect(keys.contains("examples/deep/nested note"),
                "the form the shipped tour actually uses")
        #expect(keys.allSatisfy { $0 == $0.lowercased() }, "lookup is case-insensitive")
        #expect(!keys.contains(where: { $0.hasSuffix(".md") }), "the extension is not part of a target")
    }

    /// The provider finds a note by either spelling.
    @Test func theProviderIndexesBothSpellings() {
        let provider = CollectionEmbedProvider()
        let nested = Note(title: "Nested Note",
                          fileURL: URL(filePath: "/vault/Examples/Nested Note.md"),
                          lastModified: Date(), fileSize: 1)
        let plain = Note(title: "Writing",
                         fileURL: URL(filePath: "/vault/Writing.md"),
                         lastModified: Date(), fileSize: 1)
        provider.update(notes: [nested, plain])

        #expect(provider.url(forName: "Nested Note") == nested.fileURL)
        #expect(provider.url(forName: "Examples/Nested Note") == nested.fileURL,
                "the path-qualified form is what DefaultCollection ships")
        #expect(provider.url(forName: "examples/nested note") == nested.fileURL)
        #expect(provider.url(forName: "Writing") == plain.fileURL)
        #expect(provider.url(forName: "Nothing Here") == nil,
                "a miss must stay a miss — a wrong card is worse than none")
    }

    /// The shipped tour note uses a target the app can actually render.
    ///
    /// The real regression guard: this file is inside the binary, and it is the
    /// only demonstration of the feature a new user sees.
    @Test func theShippedTourNoteTranscludesSomethingThatResolves() throws {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "DefaultCollection")
        let text = try String(contentsOf: root.appending(path: "Transclusion.md"), encoding: .utf8)

        // **Only real embeds.** The note also *documents* the syntax as inline
        // code — `![[Note]]` and `![[Note#Heading]]` — and those are meant to
        // be unresolvable examples, not links. A first version of this test
        // counted them and failed for the wrong reason.
        let targets: [String] = text.split(separator: "\n").flatMap { line -> [String] in
            guard !line.contains("`![[") else { return [] }
            var found: [String] = []
            var rest = Substring(line)
            while let open = rest.range(of: "![["), let close = rest.range(of: "]]") {
                found.append(String(rest[open.upperBound..<close.lowerBound]))
                rest = rest[close.upperBound...]
            }
            return found
        }
        #expect(!targets.isEmpty, "the tour note stopped demonstrating transclusion")

        let files = try FileManager.default
            .enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "md" } ?? []
        let provider = CollectionEmbedProvider()
        provider.update(notes: files.map {
            Note(title: $0.deletingPathExtension().lastPathComponent,
                 fileURL: $0, lastModified: Date(), fileSize: 1)
        })

        for target in targets {
            let base = target.split(separator: "#", maxSplits: 1).first.map(String.init) ?? target
            #expect(provider.url(forName: base) != nil,
                    "the shipped tour transcludes “\(base)”, which does not resolve")
        }
    }
}
