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

struct HelloNotesTests {

    // MARK: - Helpers

    /// Create a unique temporary directory to act as a throwaway vault.
    private func makeTempVault() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelloNotesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    // MARK: - EditorModel

    @Test @MainActor
    func openLoadsFileContents() async throws {
        let vault = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let fileURL = vault.appendingPathComponent("Hello.md")
        try write("# Hello\n\nWorld.", to: fileURL)
        let note = Note(title: "Hello", fileURL: fileURL, lastModified: .now)

        let editor = EditorModel()
        await editor.open(note)

        #expect(editor.text == "# Hello\n\nWorld.")
        #expect(editor.isDirty == false)
    }

    @Test @MainActor
    func editThenFlushPersistsToDisk() async throws {
        let vault = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let fileURL = vault.appendingPathComponent("Note.md")
        try write("original", to: fileURL)
        let note = Note(title: "Note", fileURL: fileURL, lastModified: .now)

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
        let vault = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let fileURL = vault.appendingPathComponent("Note.md")
        try write("original", to: fileURL)
        let note = Note(title: "Note", fileURL: fileURL, lastModified: .now)

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
        let vault = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let fileURL = vault.appendingPathComponent("Note.md")
        try write("original", to: fileURL)
        let note = Note(title: "Note", fileURL: fileURL, lastModified: .now)

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
        let vault = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let firstURL = vault.appendingPathComponent("First.md")
        let secondURL = vault.appendingPathComponent("Second.md")
        try write("first", to: firstURL)
        try write("second", to: secondURL)

        let first = Note(title: "First", fileURL: firstURL, lastModified: .now)
        let second = Note(title: "Second", fileURL: secondURL, lastModified: .now)

        let editor = EditorModel()
        await editor.open(first)
        editor.text = "first edited"

        // Opening another note must flush the previous buffer first.
        await editor.open(second)

        let firstOnDisk = try String(contentsOf: firstURL, encoding: .utf8)
        #expect(firstOnDisk == "first edited")
        #expect(editor.text == "second")
    }

    // MARK: - WorkspaceIndexer

    @Test
    func scanFindsMarkdownFilesOnly() throws {
        let vault = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        try write("# A", to: vault.appendingPathComponent("A.md"))
        try write("# B", to: vault.appendingPathComponent("B.markdown"))
        try write("not markdown", to: vault.appendingPathComponent("C.txt"))

        let indexer = WorkspaceIndexer()
        indexer.selectedVaultURL = vault
        indexer.scanVault()

        let titles = Set(indexer.notes.map(\.title))
        #expect(indexer.notes.count == 2)
        #expect(titles == ["A", "B"])
    }

    @Test
    func createAndDeleteNote() throws {
        let vault = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let indexer = WorkspaceIndexer()
        indexer.selectedVaultURL = vault

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
        let vault = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let indexer = WorkspaceIndexer()
        indexer.selectedVaultURL = vault

        let first = try #require(indexer.createNote(title: "Untitled"))
        let second = try #require(indexer.createNote(title: "Untitled"))

        #expect(first.fileURL != second.fileURL)
        #expect(first.fileURL.lastPathComponent == "Untitled.md")
        #expect(second.fileURL.lastPathComponent == "Untitled 2.md")
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
        let vault = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let welcome = vault.appendingPathComponent("Welcome.md")
        let ideas = vault.appendingPathComponent("Ideas.md")
        try write("# Welcome\n\nNothing links here yet.", to: welcome)
        try write("# Ideas\n\nThoughts about [[Welcome]] and [[welcome]] again.", to: ideas)

        let indexer = WorkspaceIndexer()
        indexer.selectedVaultURL = vault
        indexer.scanVault()

        let graph = LinkGraph()
        await graph.rebuild(from: indexer.notes)

        let welcomeNote = try #require(indexer.notes.first { $0.title == "Welcome" })
        let backlinks = graph.backlinks(for: welcomeNote, in: indexer.notes)

        // Ideas links to Welcome (case-insensitively); Welcome doesn't back-link itself.
        #expect(backlinks.map(\.title) == ["Ideas"])
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

    // MARK: - VaultSearchModel

    @Test @MainActor
    func fullTextSearchFindsBodyMatchesWithSnippet() async throws {
        let vault = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        try write("# Alpha\n\nThe quick brown fox jumps.", to: vault.appendingPathComponent("Alpha.md"))
        try write("# Beta\n\nNothing to see.", to: vault.appendingPathComponent("Beta.md"))

        let indexer = WorkspaceIndexer()
        indexer.selectedVaultURL = vault
        indexer.scanVault()

        let search = VaultSearchModel()
        await search.refresh(from: indexer.notes)

        let hits = search.fullTextResults(query: "brown fox")
        #expect(hits.map(\.note.title) == ["Alpha"])
        #expect(hits.first?.snippet.contains("brown fox") == true)
    }

    @Test @MainActor
    func openQuicklyMatchesTitlesAndHeadings() async throws {
        let vault = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        try write("# Meeting Notes\n\n## Action Items\n\nDo the thing.", to: vault.appendingPathComponent("Meeting Notes.md"))

        let indexer = WorkspaceIndexer()
        indexer.selectedVaultURL = vault
        indexer.scanVault()

        let search = VaultSearchModel()
        await search.refresh(from: indexer.notes)

        // The note and its heading are both candidates.
        let all = search.quickOpenResults(query: "")
        #expect(all.contains { $0.kind == .note && $0.title == "Meeting Notes" })

        // Fuzzy query surfaces the heading candidate.
        let actionHits = search.quickOpenResults(query: "action")
        #expect(actionHits.contains { $0.kind == .heading && $0.subtitle == "Action Items" })
    }

    @Test @MainActor
    func tagsAreIndexedAndFilterable() async throws {
        let vault = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        try write("# One\n\nTagged #project and #urgent.", to: vault.appendingPathComponent("One.md"))
        try write("# Two\n\nJust #project here.", to: vault.appendingPathComponent("Two.md"))
        try write("# Three\n\nNo tags.", to: vault.appendingPathComponent("Three.md"))

        let indexer = WorkspaceIndexer()
        indexer.selectedVaultURL = vault
        indexer.scanVault()

        let search = VaultSearchModel()
        await search.refresh(from: indexer.notes)

        #expect(search.allTags() == ["project", "urgent"])
        #expect(Set(search.notesTagged("project").map(\.title)) == ["One", "Two"])
        #expect(search.notesTagged("urgent").map(\.title) == ["One"])
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
        let vault = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        try write("# A\n\n#project/hellonotes", to: vault.appendingPathComponent("A.md"))
        try write("# B\n\n#project here", to: vault.appendingPathComponent("B.md"))
        try write("# C\n\n#personal", to: vault.appendingPathComponent("C.md"))

        let indexer = WorkspaceIndexer()
        indexer.selectedVaultURL = vault
        indexer.scanVault()
        let search = VaultSearchModel()
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
        let vault = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        try write("---\naliases: [Home]\n---\n# Welcome", to: vault.appendingPathComponent("Welcome.md"))
        try write("Link to [[Home]] and [[Welcome]].", to: vault.appendingPathComponent("Ideas.md"))

        let indexer = WorkspaceIndexer()
        indexer.selectedVaultURL = vault
        indexer.scanVault()
        let graph = LinkGraph()
        await graph.rebuild(from: indexer.notes)

        let welcome = try #require(indexer.notes.first { $0.title == "Welcome" })
        let ideas = try #require(indexer.notes.first { $0.title == "Ideas" })
        // Ideas links Welcome via its alias and title → a single backlink from Ideas.
        #expect(graph.backlinks(for: welcome, in: indexer.notes).map(\.title) == ["Ideas"])
        // Outgoing from Ideas resolves both targets to the one Welcome note.
        #expect(graph.outgoingLinks(for: ideas, in: indexer.notes).map(\.title) == ["Welcome"])
        #expect(graph.resolve("home") == welcome.fileURL)
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
        let vault = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        try write("# Note", to: vault.appendingPathComponent("Note.md"))

        let git = GitService()
        git.vaultURL = vault

        await git.refreshStatus()
        #expect(git.status.isRepository == false)

        await git.initializeRepository()
        #expect(git.status.isRepository == true)
        #expect(git.status.changeCount == 1)   // Note.md is untracked

        // Commit works even without a global git identity (ensureCommitIdentity
        // sets a local one), and leaves the tree clean.
        await git.commitAll(message: "Initial commit")
        #expect(git.lastError == nil)
        #expect(git.status.isClean)
    }

    @Test @MainActor
    func gitNoteHistoryTracksFileRevisions() async throws {
        let vault = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let noteURL = vault.appendingPathComponent("Note.md")

        let git = GitService()
        git.vaultURL = vault
        await git.initializeRepository()

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
        let vault = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let a = vault.appendingPathComponent("A.md")
        let b = vault.appendingPathComponent("B.md")
        try write("# A", to: a)
        try write("# B", to: b)
        let noteA = Note(title: "A", fileURL: a, lastModified: .now)
        let noteB = Note(title: "B", fileURL: b, lastModified: .now)

        let tabs = EditorTabs()
        await tabs.editor(for: noteA)
        await tabs.editor(for: noteB)
        #expect(tabs.openNotes.map(\.title) == ["A", "B"])

        // Reopening an existing note doesn't add a second tab.
        await tabs.editor(for: noteA)
        #expect(tabs.openNotes.count == 2)

        let next = await tabs.close(noteA.id)
        #expect(tabs.openNotes.map(\.title) == ["B"])
        #expect(next == noteB.id)
    }

    // MARK: - Image paste

    @Test @MainActor
    func pastedImageIsSavedAndLinked() throws {
        let vault = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let noteURL = vault.appendingPathComponent("Note.md")
        try write("# Note", to: noteURL)

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
            ImagePaste.saveImage(from: pasteboard, nextTo: noteURL, timestamp: Date(timeIntervalSince1970: 1_000_000))
        )

        #expect(markdown.hasPrefix("![](assets/Pasted-"))
        #expect(markdown.hasSuffix(".png)"))
        // The referenced file exists next to the note.
        let assetName = markdown.dropFirst("![](assets/".count).dropLast(")".count)
        let assetURL = vault.appendingPathComponent("assets").appendingPathComponent(String(assetName))
        #expect(FileManager.default.fileExists(atPath: assetURL.path))
    }

    // MARK: - VaultTree

    @Test
    func buildsFolderTreeWithFoldersFirst() throws {
        let vault = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let projects = vault.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try write("# Root", to: vault.appendingPathComponent("Root.md"))
        try write("# Alpha", to: projects.appendingPathComponent("Alpha.md"))
        try write("# Beta", to: projects.appendingPathComponent("Beta.md"))

        let indexer = WorkspaceIndexer()
        indexer.selectedVaultURL = vault
        indexer.scanVault()

        let tree = VaultTree.build(from: indexer.notes, vaultURL: vault, sort: .name)

        // Folder "Projects" comes before the root-level note "Root".
        #expect(tree.map(\.name) == ["Projects", "Root"])
        #expect(tree[0].isFolder)
        #expect(tree[1].note?.title == "Root")

        // The folder's children are the two notes, name-sorted.
        let childTitles = tree[0].children?.compactMap { $0.note?.title }
        #expect(childTitles == ["Alpha", "Beta"])
    }
}
