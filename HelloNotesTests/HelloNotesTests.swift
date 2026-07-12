//
//  HelloNotesTests.swift
//  HelloNotesTests
//
//  Created by Chris Tham on 11/7/2026.
//

import Testing
import Foundation
import AppKit
@testable import HelloNotes

@MainActor
struct HelloNotesTests {

    // MARK: - Helpers

    /// The repo's committed sample vault (`SampleVault/`), located relative to
    /// this source file so tests exercise the same demo content shipped in the repo.
    private static var sampleVaultURL: URL {
        URL(filePath: #filePath)          // …/HelloNotesTests/HelloNotesTests.swift
            .deletingLastPathComponent()  // …/HelloNotesTests
            .deletingLastPathComponent()  // …/<repo root>
            .appending(path: "SampleVault")
    }

    /// The sample vault's note titles (Markdown files, recursively — including the
    /// notes in `Projects/` and `Templates/`, and its `README`).
    private static let sampleNoteTitles: Set<String> = [
        "2026-07-11", "Callouts", "Deck", "Diagram", "Ideas", "MathNote", "README",
        "RichTransclude", "Transclude", "Welcome", "Roadmap", "Daily", "SKILL",
    ]

    /// Copy the repo's sample vault into a unique temp directory so tests read
    /// (and may safely mutate) real content without touching the committed fixture.
    private func copiedSampleVault() throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelloNotesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: Self.sampleVaultURL, to: dest)
        return dest
    }

    /// The file URL of a root-level note in a vault.
    private func note(_ title: String, in vault: URL) -> URL {
        vault.appending(path: "\(title).md")
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    // MARK: - EditorModel

    @Test @MainActor
    func openLoadsFileContents() async throws {
        let vault = try copiedSampleVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let fileURL = note("Welcome", in: vault)
        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        let note = Note(title: "Welcome", fileURL: fileURL, lastModified: .now)

        let editor = EditorModel()
        await editor.open(note)

        #expect(editor.text == onDisk)
        #expect(editor.text.contains("# Welcome to HelloNotes"))
        #expect(editor.isDirty == false)
    }

    @Test @MainActor
    func editThenFlushPersistsToDisk() async throws {
        let vault = try copiedSampleVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let fileURL = note("Ideas", in: vault)
        let note = Note(title: "Ideas", fileURL: fileURL, lastModified: .now)

        let editor = EditorModel()
        await editor.open(note)

        editor.text = "edited content"
        #expect(editor.isDirty == true)

        await editor.flush()

        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(onDisk == "edited content")
        #expect(editor.isDirty == false)
    }

    @Test @MainActor
    func externalChangeReloadsCleanBuffer() async throws {
        let vault = try copiedSampleVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let fileURL = note("Ideas", in: vault)
        let note = Note(title: "Ideas", fileURL: fileURL, lastModified: .now)

        let editor = EditorModel()
        await editor.open(note)

        // Another program rewrites the file while our buffer is unchanged.
        try write("changed on disk", to: fileURL)
        await editor.reconcileWithDisk()

        #expect(editor.text == "changed on disk")
        #expect(editor.hasConflict == false)
    }

    @Test @MainActor
    func externalChangeWithUnsavedEditsRaisesConflict() async throws {
        let vault = try copiedSampleVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let fileURL = note("Ideas", in: vault)
        let note = Note(title: "Ideas", fileURL: fileURL, lastModified: .now)

        let editor = EditorModel()
        await editor.open(note)

        editor.text = "my unsaved edit"          // dirty buffer
        try write("their external edit", to: fileURL)
        await editor.reconcileWithDisk()

        #expect(editor.hasConflict == true)
        #expect(editor.text == "my unsaved edit") // not clobbered

        // Reloading adopts the disk copy.
        editor.resolveConflictReloading()
        #expect(editor.text == "their external edit")
        #expect(editor.hasConflict == false)
    }

    @Test @MainActor
    func switchingNotesFlushesPreviousEdits() async throws {
        let vault = try copiedSampleVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let firstURL = note("Ideas", in: vault)
        let secondURL = note("Welcome", in: vault)
        let secondOnDisk = try String(contentsOf: secondURL, encoding: .utf8)

        let first = Note(title: "Ideas", fileURL: firstURL, lastModified: .now)
        let second = Note(title: "Welcome", fileURL: secondURL, lastModified: .now)

        let editor = EditorModel()
        await editor.open(first)
        editor.text = "first edited"

        // Opening another note must flush the previous buffer first.
        await editor.open(second)

        let firstOnDisk = try String(contentsOf: firstURL, encoding: .utf8)
        #expect(firstOnDisk == "first edited")
        #expect(editor.text == secondOnDisk)
    }

    // MARK: - Collection

    @Test
    func scanFindsMarkdownFilesOnly() throws {
        let vault = try copiedSampleVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        // A non-Markdown file dropped into the vault must be ignored.
        try write("not markdown", to: vault.appendingPathComponent("Notes.txt"))

        let indexer = Collection(rootURL: vault)
        indexer.scan()

        let titles = Set(indexer.notes.map(\.title))
        // Every sample note (including those in Projects/ and Templates/) is found…
        #expect(titles == Self.sampleNoteTitles)
        // …and the .txt file is not indexed.
        #expect(!titles.contains("Notes"))
    }

    @Test
    func createAndDeleteNote() throws {
        let vault = try copiedSampleVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let indexer = Collection(rootURL: vault)
        indexer.scan()

        let created = try #require(indexer.createNote(title: "Fresh"))
        #expect(created.title == "Fresh")
        #expect(FileManager.default.fileExists(atPath: created.fileURL.path))
        #expect(indexer.notes.contains(created))

        indexer.deleteNote(created)
        #expect(FileManager.default.fileExists(atPath: created.fileURL.path) == false)
        #expect(indexer.notes.contains(created) == false)
    }

    @Test
    func createNoteDisambiguatesDuplicateNames() throws {
        let vault = try copiedSampleVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let indexer = Collection(rootURL: vault)
        indexer.scan()

        // "Welcome" already exists in the sample vault, so a new one is disambiguated.
        let first = try #require(indexer.createNote(title: "Welcome"))
        let second = try #require(indexer.createNote(title: "Welcome"))

        #expect(first.fileURL != second.fileURL)
        #expect(first.fileURL.lastPathComponent == "Welcome 2.md")
        #expect(second.fileURL.lastPathComponent == "Welcome 3.md")
    }

    // MARK: - MarkdownParsing

    @Test
    func extractsWikiLinkTargets() {
        let text = "See [[Welcome]] and [[Project Ideas|ideas]] plus [[Notes#Section]]. Ignore ![[img.png]]."
        let targets = MarkdownParsing.wikiLinkTargets(in: text)
        // Alias stripped, heading suffix stripped, image embed (`![[ ]]`) excluded.
        #expect(targets == ["Welcome", "Project Ideas", "Notes"])
    }

    @Test
    func parsesFrontMatter() {
        let withFM = "---\ntitle: My Note\ntags: a, b\n---\n\n# Body"
        let fields = MarkdownParsing.frontMatter(in: withFM)
        #expect(fields == [
            FrontMatterField(key: "title", value: "My Note"),
            FrontMatterField(key: "tags", value: "a, b"),
        ])

        // No closing delimiter → not front matter.
        #expect(MarkdownParsing.frontMatter(in: "---\ntitle: X\n\n# Body") == nil)
        // No opening delimiter → nil.
        #expect(MarkdownParsing.frontMatter(in: "# Just a heading") == nil)
    }

    @Test
    func extractsMermaidBlocks() {
        let text = """
        # Diagrams

        ```mermaid
        graph TD
        A --> B
        ```

        Some text.

        ```swift
        let x = 1
        ```
        """
        let blocks = MarkdownParsing.mermaidBlocks(in: text)
        #expect(blocks == ["graph TD\nA --> B"])
    }

    @Test
    func extractsHeadingsAndTags() {
        let text = "# Title\n\nBody #alpha and #beta/child.\n\n## Sub"
        let headings = MarkdownParsing.headings(in: text)
        #expect(headings == [
            DocumentHeading(level: 1, title: "Title"),
            DocumentHeading(level: 2, title: "Sub"),
        ])
        #expect(MarkdownParsing.tags(in: text) == ["alpha", "beta/child"])
    }

    // MARK: - LinkGraph

    @Test @MainActor
    func backlinksResolveAcrossNotes() async throws {
        let vault = try copiedSampleVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let indexer = Collection(rootURL: vault)
        indexer.scan()

        let graph = LinkGraph()
        await graph.rebuild(from: indexer.notes)

        // In the sample vault, Ideas and Roadmap both link `[[Welcome]]`.
        let welcome = try #require(indexer.notes.first { $0.title == "Welcome" })
        #expect(Set(graph.backlinks(for: welcome, in: indexer.notes).map(\.title)) == ["Ideas", "Roadmap"])

        // The daily note links `[[Ideas]]`; Welcome doesn't back-link itself.
        let ideas = try #require(indexer.notes.first { $0.title == "Ideas" })
        #expect(graph.backlinks(for: ideas, in: indexer.notes).map(\.title) == ["2026-07-11"])
    }

    // MARK: - FuzzyMatch

    @Test
    func fuzzyMatchScoresSubsequences() {
        // Non-subsequence → nil.
        #expect(FuzzyMatch.score(query: "xyz", candidate: "abc") == nil)
        // Empty query trivially matches.
        #expect(FuzzyMatch.score(query: "", candidate: "abc") == 0)
        // Word-boundary matches outrank scattered ones.
        let boundary = try! #require(FuzzyMatch.score(query: "wl", candidate: "wiki-links"))
        let scattered = try! #require(FuzzyMatch.score(query: "ik", candidate: "wiki-links"))
        #expect(boundary > scattered)
    }

    // MARK: - CollectionSearchModel

    @Test @MainActor
    func fullTextSearchFindsBodyMatchesWithSnippet() async throws {
        let vault = try copiedSampleVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let indexer = Collection(rootURL: vault)
        indexer.scan()

        let search = CollectionSearchModel()
        await search.refresh(from: indexer.notes)

        // "local-first" appears only in Welcome's body.
        let hits = search.fullTextResults(query: "local-first")
        #expect(hits.map(\.note.title) == ["Welcome"])
        #expect(hits.first?.snippet.contains("local-first") == true)
    }

    @Test @MainActor
    func openQuicklyMatchesTitlesAndHeadings() async throws {
        let vault = try copiedSampleVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let indexer = Collection(rootURL: vault)
        indexer.scan()

        let search = CollectionSearchModel()
        await search.refresh(from: indexer.notes)

        // The Welcome note and its "Getting Started" heading are both candidates.
        let all = search.quickOpenResults(query: "")
        #expect(all.contains { $0.kind == .note && $0.title == "Welcome" })

        // Fuzzy query surfaces the heading candidate.
        let hits = search.quickOpenResults(query: "getting")
        #expect(hits.contains { $0.kind == .heading && $0.subtitle == "Getting Started" })
    }

    @Test @MainActor
    func tagsAreIndexedAndFilterable() async throws {
        let vault = try copiedSampleVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let indexer = Collection(rootURL: vault)
        indexer.scan()

        let search = CollectionSearchModel()
        await search.refresh(from: indexer.notes)

        // The sample vault's inline hashtags: #intro (Ideas) and #todo (Ideas, Roadmap, daily note).
        #expect(search.allTags() == ["intro", "todo"])
        #expect(Set(search.notesTagged("todo").map(\.title)) == ["Ideas", "Roadmap", "2026-07-11"])
        #expect(search.notesTagged("intro").map(\.title) == ["Ideas"])
    }

    @Test
    func tagTreeNestsBySlash() {
        let tree = TagTree.build(from: ["project/website", "project/hellonotes", "urgent"])
        #expect(tree.map(\.name) == ["project", "urgent"])       // levels sorted

        let project = tree.first { $0.name == "project" }
        #expect(project?.fullPath == "project")
        #expect(project?.children.map(\.name) == ["hellonotes", "website"])
        #expect(project?.children.first?.fullPath == "project/hellonotes")
        #expect(tree.first { $0.name == "urgent" }?.children.isEmpty == true)
    }

    @Test @MainActor
    func notesTaggedMatchesNestedChildren() async throws {
        let vault = try copiedSampleVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        // Add nested-tag notes on top of the sample vault (which has no `project/*` tags).
        try write("# A\n\n#project/hellonotes", to: vault.appendingPathComponent("A.md"))
        try write("# B\n\n#project here", to: vault.appendingPathComponent("B.md"))
        try write("# C\n\n#personal", to: vault.appendingPathComponent("C.md"))

        let indexer = Collection(rootURL: vault)
        indexer.scan()
        let search = CollectionSearchModel()
        await search.refresh(from: indexer.notes)

        // Selecting the parent matches the parent tag and any nested child.
        #expect(Set(search.notesTagged("project").map(\.title)) == ["A", "B"])
        // Selecting the child matches only the child.
        #expect(search.notesTagged("project/hellonotes").map(\.title) == ["A"])
        // The tree nests the child under the parent.
        #expect(search.tagTree().first { $0.name == "project" }?.children.map(\.name) == ["hellonotes"])
    }

    // MARK: - Aliases, links & mentions

    @Test
    func aliasesParsedFromFrontMatter() {
        #expect(MarkdownParsing.aliases(in: "---\naliases: [NL, NoteLens]\ntitle: X\n---\nbody") == ["NL", "NoteLens"])
        #expect(MarkdownParsing.aliases(in: "---\naliases:\n  - NL\n  - Note Lens\n---\n") == ["NL", "Note Lens"])
        #expect(MarkdownParsing.aliases(in: "---\naliases: NL\n---\n") == ["NL"])
        #expect(MarkdownParsing.aliases(in: "no front matter here") == [])
    }

    @Test @MainActor
    func linkGraphResolvesAliasesAndOutgoing() async throws {
        let vault = try copiedSampleVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let indexer = Collection(rootURL: vault)
        indexer.scan()
        let graph = LinkGraph()
        await graph.rebuild(from: indexer.notes)

        let welcome = try #require(indexer.notes.first { $0.title == "Welcome" })
        let ideas = try #require(indexer.notes.first { $0.title == "Ideas" })
        // Welcome declares `aliases: [Home, Intro]`, so both resolve to its file.
        #expect(graph.resolve("home") == welcome.fileURL)
        #expect(graph.resolve("intro") == welcome.fileURL)
        // Ideas links `[[Welcome]]`, `[[Roadmap]]`, and `[[Welcome#Getting Started]]` →
        // resolving to the two distinct notes Welcome and Roadmap.
        #expect(Set(graph.outgoingLinks(for: ideas, in: indexer.notes).map(\.title)) == ["Welcome", "Roadmap"])
    }

    @Test
    func mentionScannerDetectsAndLinks() {
        #expect(MentionScanner.containsMention(of: ["Welcome"], in: "See Welcome for intro. Also [[Welcome]].") == true)
        #expect(MentionScanner.containsMention(of: ["Welcome"], in: "Only [[Welcome]] here.") == false)
        #expect(MentionScanner.containsMention(of: ["Missing"], in: "no mention") == false)
        #expect(MentionScanner.linkingFirstMention(of: "Welcome", in: "See Welcome now.") == "See [[Welcome]] now.")
        #expect(MentionScanner.linkingFirstMention(of: "Welcome", in: "Only [[Welcome]].") == nil)
    }

    // MARK: - Templates, properties & graph layout

    @Test
    func templateExpanderExpandsPlaceholders() {
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_782_777_600)
        let out = TemplateExpander.expand("# {{title}} — {{date}} {{time}}", title: "Note", date: date, timeZone: utc)
        #expect(out.contains("# Note — "))
        #expect(!out.contains("{{"))
        #expect(TemplateExpander.dailyNoteName(for: date, format: "yyyy-MM-dd", timeZone: utc).count == 10)
    }

    @Test
    func frontMatterParsesTypesAndRoundTrips() {
        let text = """
        ---
        title: Hello World
        published: true
        count: 3
        due: 2026-07-11
        tags:
          - a
          - b
        ---
        Body text here.
        """
        let props = FrontMatter.properties(in: text)
        #expect(props.map(\.key) == ["title", "published", "count", "due", "tags"])
        #expect(props.first { $0.key == "published" }?.kind == .checkbox)
        #expect(props.first { $0.key == "published" }?.bool == true)
        #expect(props.first { $0.key == "count" }?.kind == .number)
        #expect(props.first { $0.key == "due" }?.kind == .date)
        #expect(props.first { $0.key == "tags" }?.items == ["a", "b"])

        let applied = FrontMatter.applying(props, to: text)
        #expect(applied.contains("Body text here."))
        let reparsed = FrontMatter.properties(in: applied)
        #expect(reparsed.map(\.key) == props.map(\.key))
        #expect(reparsed.first { $0.key == "tags" }?.items == ["a", "b"])

        // Removing all properties strips the front matter, keeping the body.
        let stripped = FrontMatter.applying([], to: text)
        #expect(stripped.contains("Body text here."))
        #expect(!stripped.contains("---"))
    }

    @Test
    func graphLayoutPlacesNodesInBounds() {
        let size = CGSize(width: 400, height: 300)
        let positions = GraphLayout.positions(
            count: 5, edges: [(0, 1), (1, 2), (2, 3), (3, 4), (4, 0)], size: size, iterations: 50
        )
        #expect(positions.count == 5)
        for point in positions {
            #expect(point.x >= 0 && point.x <= size.width)
            #expect(point.y >= 0 && point.y <= size.height)
        }
        #expect(GraphLayout.positions(count: 0, edges: [], size: size).isEmpty)
    }

    // MARK: - GitService

    @Test @MainActor
    func gitInitStatusAndCommit() async throws {
        let vault = try copiedSampleVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let git = GitService()
        git.rootURL = vault

        await git.refreshStatus()
        #expect(git.status.isRepository == false)

        await git.initializeRepository()
        #expect(git.status.isRepository == true)
        #expect(git.status.changeCount > 0)   // the sample notes are untracked

        // Commit works even without a global git identity (ensureCommitIdentity
        // sets a local one), and leaves the tree clean.
        await git.commitAll(message: "Initial commit")
        #expect(git.lastError == nil)
        #expect(git.status.isClean)
    }

    @Test @MainActor
    func gitNoteHistoryTracksFileRevisions() async throws {
        let vault = try copiedSampleVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let git = GitService()
        git.rootURL = vault
        await git.initializeRepository()
        await git.commitAll(message: "Import sample vault")   // baseline

        // Track a fresh note's revisions on top of the sample-vault baseline.
        let noteURL = vault.appendingPathComponent("History.md")
        try write("# Version one", to: noteURL)
        await git.commitAll(message: "First")
        try write("# Version two", to: noteURL)
        await git.commitAll(message: "Second")

        let history = await git.history(for: noteURL)
        #expect(history.count == 2)               // both commits changed the file
        #expect(history.first?.summary == "Second")   // newest first

        // The oldest revision's content matches the first version we wrote.
        let oldest = try #require(history.last)
        let content = await git.content(ofRevision: oldest.id, for: noteURL)
        #expect(content == "# Version one")
    }

    // MARK: - Document statistics & export

    @Test
    func documentStatistics() {
        let text = "# Title\n\nThe quick brown fox.\n\nAnother short paragraph here."
        let stats = DocumentAnalyzer.analyze(text)
        #expect(stats.words == 9)          // Title + The quick brown fox + Another short paragraph here
        #expect(stats.paragraphs == 3)     // heading, sentence, sentence
        #expect(stats.readingMinutes == 1) // rounds up, min 1
        #expect(DocumentAnalyzer.analyze("").readingMinutes == 0)
    }

    @Test
    func htmlExportRendersMarkdown() {
        let html = MarkdownExport.html(from: "# Hi\n\nSome **bold** text.", title: "Doc")
        #expect(html.contains("<h1>Hi</h1>"))
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("<title>Doc</title>"))
    }

    // MARK: - EditorTabs

    @Test @MainActor
    func editorTabsOpenReuseAndClose() async throws {
        let vault = try copiedSampleVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let a = note("Ideas", in: vault)
        let b = note("Welcome", in: vault)
        let noteA = Note(title: "Ideas", fileURL: a, lastModified: .now)
        let noteB = Note(title: "Welcome", fileURL: b, lastModified: .now)

        let tabs = EditorTabs()
        await tabs.editor(for: noteA)
        await tabs.editor(for: noteB)
        #expect(tabs.openNotes.map(\.title) == ["Ideas", "Welcome"])

        // Reopening an existing note doesn't add a second tab.
        await tabs.editor(for: noteA)
        #expect(tabs.openNotes.count == 2)

        let next = await tabs.close(noteA.id)
        #expect(tabs.openNotes.map(\.title) == ["Welcome"])
        #expect(next == noteB.id)
    }

    // MARK: - Image paste

    @Test @MainActor
    func pastedImageIsSavedAndLinked() throws {
        let vault = try copiedSampleVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let noteURL = note("Welcome", in: vault)

        // Build a 1×1 PNG and put it on a pasteboard.
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!

        let pasteboard = NSPasteboard(name: .init("HelloNotesTestPasteboard"))
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)

        let markdown = try #require(
            ImagePaste.saveImage(from: pasteboard, nextTo: noteURL, subfolder: "assets",
                                 timestamp: Date(timeIntervalSince1970: 1_000_000))
        )

        #expect(markdown.hasPrefix("![](assets/Pasted-"))
        #expect(markdown.hasSuffix(".png)"))
        // The referenced file exists in the `assets` subfolder next to the note.
        let assetName = markdown.dropFirst("![](assets/".count).dropLast(")".count)
        let assetURL = vault.appendingPathComponent("assets").appendingPathComponent(String(assetName))
        #expect(FileManager.default.fileExists(atPath: assetURL.path))
    }

    @Test @MainActor
    func pastedImageWithEmptySubfolderSavesNextToNote() throws {
        let vault = try copiedSampleVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let noteURL = note("Welcome", in: vault)

        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 1, height: 1).fill(); image.unlockFocus()
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!

        let pasteboard = NSPasteboard(name: .init("HelloNotesTestPasteboardSameFolder"))
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)

        let markdown = try #require(
            ImagePaste.saveImage(from: pasteboard, nextTo: noteURL, subfolder: "",
                                 timestamp: Date(timeIntervalSince1970: 2_000_000))
        )

        // No subfolder in the link, and the file sits beside the note.
        #expect(markdown.hasPrefix("![](Pasted-"))
        #expect(!markdown.contains("/"))
        let assetName = markdown.dropFirst("![](".count).dropLast(")".count)
        let assetURL = noteURL.deletingLastPathComponent().appendingPathComponent(String(assetName))
        #expect(FileManager.default.fileExists(atPath: assetURL.path))
    }

    // MARK: - CollectionTree

    @Test
    func buildsFolderTreeWithFoldersFirst() throws {
        let vault = try copiedSampleVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let indexer = Collection(rootURL: vault)
        indexer.scan()

        let tree = CollectionTree.build(from: indexer.notes, rootURL: vault, sort: .name)

        // The sample vault's folders (Projects, Skills, Templates) sort before root-level notes.
        #expect(tree.prefix(3).map(\.name) == ["Projects", "Skills", "Templates"])
        #expect(tree[0].isFolder && tree[1].isFolder && tree[2].isFolder)
        // Root notes follow the folders.
        #expect(tree.contains { $0.note?.title == "Welcome" })

        // Each folder's children are its notes.
        let projects = try #require(tree.first { $0.name == "Projects" })
        #expect(projects.children?.compactMap { $0.note?.title } == ["Roadmap"])
        let templates = try #require(tree.first { $0.name == "Templates" })
        #expect(templates.children?.compactMap { $0.note?.title } == ["Daily"])
    }
}
