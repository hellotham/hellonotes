//
//  HelloNotesTests.swift
//  HelloNotesTests
//
//  Created by Chris Tham on 11/7/2026.
//

import Testing
import Foundation
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
