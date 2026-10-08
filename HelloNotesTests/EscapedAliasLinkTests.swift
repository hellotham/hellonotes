//
//  EscapedAliasLinkTests.swift
//  HelloNotesTests
//
//  `[[Note\|alias]]` — how an aliased link is written in a table's row, and
//  the same link anywhere else — names `Note` to every reader of a link, by
//  the one rule they share (`WikiLinkSyntax`, implemented.md §51.36). Each
//  stopped at the pipe and kept the table's backslash, so it named `Note\`.
//

import Foundation
import Testing
import GFMRender
import MarkdownEditor
@testable import HelloNotes

@Suite @MainActor
struct EscapedAliasLinkTests {

    /// The link graph: a table's aliased link was missing from backlinks and
    /// from the graph.
    @Test func theLinkGraphReadsTheNote() {
        let text = #"| [[Note\|alias]] |"# + "\nSee [[Other|shown]], [[Third]] and [[Even\\\\|run]].\n"
        #expect(MarkdownParsing.wikiLinkTargets(in: text) == ["Note", "Other", "Third", #"Even\\"#])
    }

    /// A composed note's links: a table's aliased link to a real note was
    /// unwrapped to its alias, as if the note did not exist — and one kept
    /// keeps its escape, or the rewritten link divides the cell.
    @Test func aComposedNoteKeepsATablesLinkWithItsEscape() {
        let resolved = ComposedNote.resolveWikiLinks(in: #"| [[note\|the note]] | [[Gone\|gone]] |"#,
                                                     knownTitles: ["Note"])
        #expect(resolved.text == #"| [[Note\|the note]] | gone |"#)
        #expect(resolved.kept == ["Note"])
        #expect(resolved.dropped == ["Gone"])
    }

    /// The mind map: a table's aliased link drew no leaf.
    @Test func theMindMapDrawsTheNote() {
        let url = URL(fileURLWithPath: "/tmp/Other.md")
        let model = MindMapModel(rootTitle: "Root", text: #"Intro mentioning [[Other\|the other one]]."#,
                                 resolveLink: { $0 == "Other" ? (url, "Other") : nil })
        #expect(model.nodes.contains { $0.title == "Other" }, "no leaf for the linked note: \(model.nodes.map(\.title))")
    }

    /// A rename rewrites a table's aliased links to the note, keeping their
    /// escape. It looked for the old name followed by `#`, `|` or `]]`, so
    /// `[[Old\|alias]]` kept the old name and broke.
    @Test func aRenameRewritesATablesLinks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EscapedAlias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileIO.write("# Old\n", to: root.appendingPathComponent("Old.md"))
        let linker = root.appendingPathComponent("Linker.md")
        try FileIO.write("| Link |\n| --- |\n| [[Old\\|the old one]] |\n\n[[Old\\|again]] and [[Old\\\\|not it]]\n", to: linker)
        let collection = Collection(rootURL: root)
        collection.scan()
        let old = try #require(collection.note(titled: "Old"))

        _ = try #require(await collection.renameNote(old, to: "New"))
        // The links are rewritten after the rename returns.
        let expected = "| Link |\n| --- |\n| [[New\\|the old one]] |\n\n[[New\\|again]] and [[Old\\\\|not it]]\n"
        let deadline = ContinuousClock.now + .seconds(10)
        var text = try FileIO.readString(at: linker)
        while text != expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            text = try FileIO.readString(at: linker)
        }
        #expect(text == expected, "the links were not rewritten: \(text.debugDescription)")
    }

    /// Preview's transclusions: `![[picture\|300]]` and `![[Note\|alias]]`
    /// looked up `Note\`, and the embed was left undrawn.
    @Test func previewDrawsATablesTransclusion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EscapedEmbed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Note.md")
        try FileIO.write("# Note\n\nWhat the card shows.\n", to: url)
        let provider = CollectionEmbedProvider()
        provider.update(notes: [Note(title: "Note", fileURL: url, lastModified: Date(), fileSize: 30)])

        let page = await PreviewSuperset.apply(to: #"| ![[Note\|a card]] |"#, isDark: false, embeds: provider)
        #expect(page.contains("hn-embed"), "the transclusion was not drawn: \(page)")
    }

    /// **A click on a table's aliased link in Preview opens the note.** The
    /// link as the page has it — through the rewrite and cmark-gfm — handed
    /// over as Preview hands a click (`GFMPreview.linkTap`), and followed as
    /// Edit's tap is. Preview's web view had no navigation delegate, so the
    /// click went nowhere the app could see.
    @Test func aClickInPreviewOpensTheNote() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewLink-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Examples", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileIO.write("# Nested\n", to: folder.appendingPathComponent("Nested Note.md"))
        let from = root.appendingPathComponent("Index.md")
        let text = "| Link |\n| --- |\n| [[Examples/Nested Note\\|an alias]] |\n"
        try FileIO.write(text, to: from)
        let collection = Collection(rootURL: root)
        collection.scan()
        // A path-qualified name is the link graph's to resolve.
        collection.refreshDerived(force: true)
        let deadline = ContinuousClock.now + .seconds(10)
        while collection.linkGraph.resolve("Examples/Nested Note") == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        let html = GFMRenderer.html(GitHubMarkdown.prepare(text))
        let href = try #require(html.firstMatch(of: /href="([^"]*)"/)).1
        let url = try #require(URL(string: String(href)))
        guard case .wiki(let target)? = GFMPreview.linkTap(for: url, page: root) else {
            Issue.record("Preview did not hand the link over as a wiki link: \(href)"); return
        }
        let destination = await WikiLinkNavigation.resolve(target: target, in: collection,
                                                            current: collection.note(titled: "Index"),
                                                            createOnMiss: false)
        guard case .note(let note, nil) = destination else {
            Issue.record("the link went to \(destination)"); return
        }
        #expect(note.fileURL.lastPathComponent == "Nested Note.md")
    }

    /// Following a link reaches the note — as it has since implemented.md
    /// §51.35, now by the shared rule.
    @Test func followingALinkReachesTheNote() {
        #expect(WikiLinkNavigation.split(#"Note\|alias"#).base == "Note")
        #expect(WikiLinkNavigation.split(#"Note#Part\|alias"#) == ("Note", "Part"))
    }
}
