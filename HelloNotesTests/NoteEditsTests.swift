//
//  NoteEditsTests.swift
//  HelloNotesTests
//
//  Created by Chris Tham on 16/8/2026.
//

import Testing
import Foundation
@testable import HelloNotes

/// What happens when an accepted suggestion lands in a note.
///
/// **The body is the author's.** Every one of these used to write prose: a tag
/// appended after the last paragraph, a link under a `## Related` heading the
/// app invented, a summary callout pushed above the note's first line. They all
/// write front matter now, which is where metadata belongs, is removable in the
/// Properties pane, and is the convention every other Markdown tool reads.
///
/// The cases below are the ones where the obvious implementation is subtly
/// wrong — YAML quoting above all, since an unquoted `[[Note]]` is a nested
/// sequence rather than a string.
struct NoteEditsTests {

    // MARK: - Tags

    @Test func aTagLandsInFrontMatterNotInTheProse() {
        let updated = NoteEdits.addingTag("focus", to: "Some thoughts.")
        #expect(updated == "---\ntags:\n  - focus\n---\nSome thoughts.")
        #expect(FrontMatter.body(of: updated) == "Some thoughts.",
                "the body must come back byte-identical")
    }

    @Test func repeatedTagsJoinOneList() {
        var note = "Body."
        for tag in ["a", "b", "c"] { note = NoteEdits.addingTag(tag, to: note) }
        #expect(FrontMatter.properties(in: note).first { $0.key == "tags" }?.items == ["a", "b", "c"])
        #expect(FrontMatter.body(of: note) == "Body.")
    }

    @Test func anExistingTagIsNotAddedTwice() {
        let once = NoteEdits.addingTag("focus", to: "Body.")
        #expect(NoteEdits.addingTag("focus", to: once) == once)
        #expect(NoteEdits.addingTag("FOCUS", to: once) == once, "case-insensitively")
    }

    /// A note that spelled its tags as a scalar keeps them — the existing value
    /// is the user's, so it is promoted to a list rather than replaced.
    @Test func aScalarTagsKeyBecomesAListWithoutLosingWhatWasThere() {
        let note = "---\ntags: reading\n---\nBody."
        let updated = NoteEdits.addingTag("focus", to: note)
        #expect(FrontMatter.properties(in: updated).first { $0.key == "tags" }?.items
                == ["reading", "focus"])
    }

    @Test func otherPropertiesSurviveATagBeingAdded() {
        let note = "---\ntitle: Thing\naliases:\n  - Other\n---\nBody."
        let updated = NoteEdits.addingTag("focus", to: note)
        let keys = FrontMatter.properties(in: updated).map(\.key)
        #expect(keys.contains("title") && keys.contains("aliases") && keys.contains("tags"))
        #expect(MarkdownParsing.aliases(in: updated) == ["Other"])
    }

    // MARK: - Related links

    /// The bug this pins: `- [[Note]]` unquoted is a YAML *nested sequence*,
    /// not a string. It would not survive its own round trip, and every other
    /// tool reading the vault would see something the author never wrote.
    @Test func aRelatedLinkIsQuotedSoYAMLReadsItAsText() {
        let updated = NoteEdits.addingRelatedLink("Zettelkasten", to: "Body.")
        #expect(updated.contains("\"[[Zettelkasten]]\""), "got: \(updated)")
        #expect(FrontMatter.properties(in: updated).first { $0.key == "related" }?.items
                == ["[[Zettelkasten]]"], "and reads back unquoted")
    }

    /// Still a real link: the graph scans the whole document, so a related
    /// property is an outgoing link exactly as the body version was.
    @Test func aRelatedLinkIsStillSeenByTheGraph() {
        let updated = NoteEdits.addingRelatedLink("Zettelkasten", to: "Body.")
        #expect(MarkdownParsing.wikiLinkTargets(in: updated).contains("Zettelkasten"))
    }

    @Test func repeatedLinksShareOneList() {
        var note = "Body."
        for title in ["One", "Two", "Three"] { note = NoteEdits.addingRelatedLink(title, to: note) }
        #expect(FrontMatter.properties(in: note).first { $0.key == "related" }?.items
                == ["[[One]]", "[[Two]]", "[[Three]]"])
        #expect(FrontMatter.body(of: note) == "Body.", "the prose is untouched")
    }

    // MARK: - Wiki links from a selection

    @Test func linkingAPhraseThatIsTheTitleNeedsNoAlias() {
        #expect(NoteEdits.wikiLink(to: "Zettelkasten", shownAs: "Zettelkasten") == "[[Zettelkasten]]")
    }

    /// The sentence has to survive the link. Aliasing is the only way the words
    /// the author chose stay the words on the page.
    @Test func linkingADifferentPhraseKeepsTheWordsTheAuthorWrote() {
        #expect(NoteEdits.wikiLink(to: "Second Brain", shownAs: "second brains")
                == "[[Second Brain|second brains]]")
    }

    /// Case differences alias too — silently recasing a word mid-sentence is an
    /// edit nobody asked for.
    @Test func casingDifferencesStillAlias() {
        #expect(NoteEdits.wikiLink(to: "Second Brain", shownAs: "second brain")
                == "[[Second Brain|second brain]]")
    }

    /// Whether a phrase is worth a link lookup at all.
    @Test func multiLinePassagesAreNotLinkCandidates() {
        #expect(SelectionActions.isLinkable("second brain"))
        #expect(!SelectionActions.isLinkable("a passage\nspanning two lines"))
        #expect(!SelectionActions.isLinkable(String(repeating: "x", count: 121)))
    }

    // MARK: - Summary

    @Test func aSummaryLandsInFrontMatterAndLeavesTheBodyAlone() {
        let updated = NoteEdits.settingSummary("It is about notes.", in: "# Title\n\nBody.")
        #expect(FrontMatter.properties(in: updated).first { $0.key == "summary" }?.text
                == "It is about notes.")
        #expect(FrontMatter.body(of: updated) == "# Title\n\nBody.",
                "the note's first line must still be its first line")
    }

    /// YAML scalars are one line, so a multi-sentence summary is folded rather
    /// than breaking the block.
    @Test func aMultiLineSummaryIsFoldedToOneLine() {
        let updated = NoteEdits.settingSummary("One.\nTwo.\nThree.", in: "Body.")
        #expect(FrontMatter.properties(in: updated).first { $0.key == "summary" }?.text
                == "One. Two. Three.")
        #expect(!updated.contains("summary: One.\n"), "no raw newline inside the scalar")
    }

    /// Re-summarising replaces, never accumulates.
    @Test func summarisingTwiceLeavesOneSummary() {
        let once = NoteEdits.settingSummary("First.", in: "Body.")
        let twice = NoteEdits.settingSummary("Second.", in: once)
        let summaries = FrontMatter.properties(in: twice).filter { $0.key == "summary" }
        #expect(summaries.count == 1)
        #expect(summaries.first?.text == "Second.")
    }

    /// A summary quoting a hashtag must not become a tag. This is the trap that
    /// opened up the moment summaries moved into front matter, because the tag
    /// scanner used to read the whole document.
    @Test func aHashInASummaryIsNotATag() {
        let note = NoteEdits.settingSummary("Covers #hashtag syntax.", in: "Body.")
        #expect(MarkdownParsing.tags(in: note).isEmpty, "got: \(MarkdownParsing.tags(in: note))")
    }

    // MARK: - Reading back

    @Test func frontMatterTagsAreIndexed() {
        let note = "---\ntags:\n  - research\n  - ai\n---\nBody with #inline too."
        #expect(MarkdownParsing.tags(in: note) == ["research", "ai", "inline"])
    }

    @Test func aFlowListAndAScalarBothRead() {
        #expect(MarkdownParsing.tags(in: "---\ntags: [a, b]\n---\nx") == ["a", "b"])
        #expect(MarkdownParsing.tags(in: "---\ntags: solo\n---\nx") == ["solo"])
    }

    /// Obsidian writes both spellings; a leading `#` is not part of the name.
    @Test func aLeadingHashInAFrontMatterTagIsStripped() {
        #expect(MarkdownParsing.tags(in: "---\ntags:\n  - \"#focus\"\n---\nx") == ["focus"])
    }
}
