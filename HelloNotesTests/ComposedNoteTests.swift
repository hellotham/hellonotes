//
//  ComposedNoteTests.swift
//  HelloNotesTests
//
//  Created by Chris Tham on 16/8/2026.
//

import Testing
import Foundation
@testable import HelloNotes

/// What a model's reply must survive before it is allowed to become a note.
///
/// The stakes here are different from the rest of the AI surface. Summarise and
/// Suggest Tags put their output in a panel, where a bad answer is visibly a bad
/// answer. Composition writes a *file*, and a research note is the one kind of
/// note nobody re-reads: it is generated, skimmed, filed, and thereafter trusted
/// exactly as much as a note the user wrote themselves. So every test below is a
/// way the composed note could be wrong in a way that never looks wrong.
struct ComposedNoteTests {

    private let day = Date(timeIntervalSince1970: 1_755_302_400)   // 2026-08-16 UTC

    // MARK: - Invented links

    /// The whole reason this layer exists. A model told which notes exist will
    /// still name ones that don't, and `[[Nonexistent]]` renders identically to
    /// a real link — it just quietly adds a node to the graph.
    @Test func aWikiLinkNamingNoNoteIsUnwrappedToPlainText() {
        let resolved = ComposedNote.resolveWikiLinks(
            in: "Compare [[Zettelkasten]] with [[Memex]].",
            knownTitles: ["Zettelkasten"])
        #expect(resolved.text == "Compare [[Zettelkasten]] with Memex.")
        #expect(resolved.kept == ["Zettelkasten"])
        #expect(resolved.dropped == ["Memex"])
    }

    /// Unwrapping must not damage the sentence: an aliased link keeps the words
    /// the author's prose was built around, not the note title it invented.
    @Test func anUnwrappedAliasedLinkKeepsItsDisplayText() {
        let resolved = ComposedNote.resolveWikiLinks(
            in: "the [[Memex|memory extender]] idea",
            knownTitles: [])
        #expect(resolved.text == "the memory extender idea")
        #expect(resolved.dropped == ["Memex"])
    }

    /// A kept link is rewritten to the note's real title so it matches the file
    /// on disk, while an alias survives untouched.
    @Test func aKeptLinkIsRewrittenToTheCanonicalTitle() {
        let resolved = ComposedNote.resolveWikiLinks(
            in: "see [[zettelkasten]] and [[SLIP BOX|slip boxes]]",
            knownTitles: ["Zettelkasten", "Slip Box"])
        #expect(resolved.text == "see [[Zettelkasten]] and [[Slip Box|slip boxes]]")
        #expect(resolved.kept == ["Zettelkasten", "Slip Box"])
    }

    /// Reversed iteration is an implementation detail of applying edits safely;
    /// it must not leak into what the user is told was linked.
    @Test func linksAreReportedInReadingOrder() {
        let resolved = ComposedNote.resolveWikiLinks(
            in: "[[Alpha]] then [[Beta]] then [[Gamma]]",
            knownTitles: ["Alpha", "Beta", "Gamma"])
        #expect(resolved.kept == ["Alpha", "Beta", "Gamma"])
    }

    /// A fence is sample text. Validating it would edit the example — turning a
    /// documented `[[Target]]` placeholder into either a link or bare prose,
    /// both of which change what the code block says.
    @Test func wikiLinksInsideAFenceAreLeftAlone() {
        let text = """
        Use this syntax:

        ```markdown
        [[Some Note That Does Not Exist]]
        ```

        as in [[Real Note]].
        """
        let resolved = ComposedNote.resolveWikiLinks(in: text, knownTitles: ["Real Note"])
        #expect(resolved.text.contains("[[Some Note That Does Not Exist]]"))
        #expect(resolved.dropped.isEmpty)
        #expect(resolved.kept == ["Real Note"])
    }

    /// Embeds are a different feature and fail visibly; rewriting them here
    /// would break a transclusion in a way the user never asked for.
    @Test func embedsAreNotTouched() {
        let resolved = ComposedNote.resolveWikiLinks(
            in: "![[Diagram]] and [[Diagram]]", knownTitles: [])
        #expect(resolved.text == "![[Diagram]] and Diagram")
    }

    // MARK: - Sources

    @Test func sourcesAreDistinctAndInOrderOfAppearance() {
        let body = """
        As reported by [Nature](https://nature.com/a) and again at https://example.org/b.
        Nature covered it first: https://nature.com/a
        """
        let urls = ComposedNote.sources(in: body).map(\.absoluteString)
        #expect(urls == ["https://nature.com/a", "https://example.org/b"])
    }

    /// Sentence punctuation is not part of the URL. Citing `…/b.` produces a
    /// source link that 404s, which is worse than no source list at all.
    @Test func trailingSentencePunctuationIsNotPartOfTheURL() {
        let urls = ComposedNote.sources(in: "See https://example.org/b, then stop.")
        #expect(urls.map(\.absoluteString) == ["https://example.org/b"])
    }

    @Test func aResearchDraftGathersItsSources() {
        let draft = ComposedNote.researchDraft(
            question: "What is a Zettelkasten?",
            synthesis: "# Zettelkasten\n\nA slip box, per https://example.org/z.",
            date: day)
        #expect(draft.body.contains("## Sources"))
        #expect(draft.body.contains("<https://example.org/z>"))
    }

    /// A synthesis that already lists its sources must not get a second list.
    @Test func anExistingSourceSectionIsNotDuplicated() {
        let draft = ComposedNote.researchDraft(
            question: "Q",
            synthesis: "Body text https://example.org/z\n\n## References\n\n- https://example.org/z",
            date: day)
        #expect(!draft.body.contains("## Sources"))
    }

    // MARK: - Front matter

    /// A question with a colon in it is the common case, and a bare YAML scalar
    /// would make the front matter unparseable — in a note nobody inspects.
    @Test func theQuestionIsQuotedSoPunctuationCannotBreakTheFrontMatter() {
        let draft = ComposedNote.researchDraft(
            question: "Zettelkasten: what is it? \"really\"",
            synthesis: "Body.", date: day)
        #expect(draft.body.contains(#"question: "Zettelkasten: what is it? \"really\"""#))
        #expect(FrontMatter.body(of: draft.body).trimmingCharacters(in: .whitespacesAndNewlines) == "Body.")
    }

    @Test func researchNotesRecordThatTheyWereSynthesised() {
        let draft = ComposedNote.researchDraft(question: "Q", synthesis: "Body.", date: day)
        #expect(draft.body.contains("source: research"))
        #expect(draft.body.hasPrefix("---\n"))
    }

    // MARK: - Title

    @Test func aLeadingHeadingBecomesTheTitleAndLeavesTheBody() {
        let draft = ComposedNote.draft(from: "# Slip Boxes\n\nThey work.", prompt: "ignored")
        #expect(draft.title == "Slip Boxes")
        #expect(draft.body == "They work.")
    }

    /// Only a *leading* heading is the title — a body that opens with prose and
    /// uses headings for sections must keep all of them.
    @Test func aHeadingLaterInTheBodyIsNotTheTitle() {
        let draft = ComposedNote.draft(from: "Intro line.\n\n# Section", prompt: "My Prompt")
        #expect(draft.title == "My Prompt")
        #expect(draft.body.contains("# Section"))
    }

    @Test func aTitlelessReplyFallsBackToTheShortenedPrompt() {
        let draft = ComposedNote.draft(
            from: "Some prose.",
            prompt: "Write me a note about the history of the slip box method and its modern descendants.")
        #expect(draft.title.count <= 60)
        #expect(draft.title.hasPrefix("Write me a note about the history"))
        #expect(!draft.title.hasSuffix(" "))
    }

    /// `appendingPathComponent` does not reject a slash, so an unsanitised
    /// title silently writes the note into a subdirectory — or somewhere else
    /// entirely.
    @Test func aTitleCannotBecomeAPath() {
        #expect(ComposedNote.filename("Notes/2026: Review") == "Notes-2026- Review")
        #expect(ComposedNote.filename("   ") == "Untitled")
    }

    // MARK: - Fences

    @Test func aWholeDocumentMarkdownFenceIsUnwrapped() {
        let draft = ComposedNote.draft(from: "```markdown\n# Title\n\nBody.\n```", prompt: "p")
        #expect(draft.title == "Title")
        #expect(draft.body == "Body.")
    }

    /// A reply that really is one code block must survive: unwrapping it would
    /// turn a shell script into prose that renders as a paragraph.
    @Test func aReplyThatIsGenuinelyCodeKeepsItsFence() {
        let reply = "```bash\necho hello\n```"
        #expect(ComposedNote.unwrappingWholeDocumentFence(reply) == reply)
    }

    /// Two separate fences means the reply is a document *containing* code, not
    /// a document wrapped in one.
    @Test func aDocumentContainingTwoFencesIsNotUnwrapped() {
        let reply = "```\na\n```\n\ntext\n\n```\nb\n```"
        #expect(ComposedNote.unwrappingWholeDocumentFence(reply) == reply)
    }
}

/// Landing a draft on disk.
///
/// `createNote` makes an **empty** file and the body is written after it, so a
/// write that fails silently leaves a zero-byte note that looks like a note.
/// That is the one outcome worth a test with real I/O in it.
@MainActor
struct ComposedNoteCreationTests {

    private func makeCollection() throws -> (Collection, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComposeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let collection = Collection(rootURL: base)
        collection.scan()
        return (collection, base)
    }

    @Test func aCreatedNoteHoldsTheDraftAndIsFindable() async throws {
        let (collection, root) = try makeCollection()
        defer { try? FileManager.default.removeItem(at: root) }

        let draft = NoteDraft(title: "Slip Boxes", body: "# ignored\n\nThe body survives.")
        let note = await NoteComposer().create(draft, in: collection)

        let created = try #require(note)
        #expect(created.title == "Slip Boxes")
        #expect(try FileIO.readString(at: created.fileURL).contains("The body survives."))
        #expect(collection.note(titled: "Slip Boxes") != nil)
    }

    /// A title that would escape the folder must have been sanitised before it
    /// reaches `appendingPathComponent`, which does not reject a slash — and
    /// the sanitised result must not begin with a dot, or the scanner skips it
    /// and the note is written but never seen.
    @Test func aDraftTitleWithASlashStaysInsideTheCollectionAndIsVisible() async throws {
        let (collection, root) = try makeCollection()
        defer { try? FileManager.default.removeItem(at: root) }

        let draft = NoteDraft(title: ComposedNote.filename("../Escaped/Note"), body: "Body.")
        let note = try #require(await NoteComposer().create(draft, in: collection))
        #expect(note.fileURL.deletingLastPathComponent().standardizedFileURL
                == root.standardizedFileURL)
        #expect(!note.fileURL.lastPathComponent.hasPrefix("."))
        #expect(collection.notes.contains { $0.fileURL == note.fileURL })
    }
}
