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
/// These are the claims the inspector's chips make by existing. Each one is a
/// place the obvious implementation is subtly wrong — appending a link is easy,
/// appending the *fourth* link without leaving four `## Related` headings is
/// where it goes astray — so they are tested rather than commented.
struct NoteEditsTests {

    // MARK: - Tags

    @Test func tagJoinsAnExistingTagLine() {
        let note = "Some thoughts.\n\n#reading #ideas"
        #expect(NoteEdits.addingTag("focus", to: note) == "Some thoughts.\n\n#reading #ideas #focus")
    }

    @Test func tagStartsItsOwnLineAfterProse() {
        let note = "Some thoughts."
        #expect(NoteEdits.addingTag("focus", to: note) == "Some thoughts.\n\n#focus")
    }

    /// A trailing `#` alone is a heading marker or a stray character, not a tag,
    /// so the line must not be joined.
    @Test func tagDoesNotJoinALineOfBareHashes() {
        #expect(NoteEdits.addingTag("focus", to: "text\n\n#") == "text\n\n#\n\n#focus")
    }

    @Test func tagIntoAnEmptyNoteAddsNoLeadingBlankLines() {
        #expect(NoteEdits.addingTag("focus", to: "") == "#focus")
    }

    /// Three accepted suggestions give one tag line, not three.
    @Test func repeatedTagsAccumulateOnOneLine() {
        var note = "Body."
        for tag in ["a", "b", "c"] { note = NoteEdits.addingTag(tag, to: note) }
        #expect(note == "Body.\n\n#a #b #c")
    }

    // MARK: - Related links

    @Test func firstLinkCreatesTheRelatedSection() {
        #expect(NoteEdits.addingRelatedLink("Zettelkasten", to: "Body.")
                == "Body.\n\n## Related\n- [[Zettelkasten]]\n")
    }

    /// The invariant the whole function exists for.
    @Test func repeatedLinksShareOneRelatedSection() {
        var note = "Body."
        for title in ["One", "Two", "Three", "Four"] {
            note = NoteEdits.addingRelatedLink(title, to: note)
        }
        #expect(note.components(separatedBy: "## Related").count - 1 == 1)
        #expect(note.contains("- [[One]]\n- [[Two]]\n- [[Three]]\n- [[Four]]"))
    }

    /// A `## Related` section in the middle of a note must grow in place, not
    /// spill its new links into whatever heading follows it.
    @Test func linkLandsInsideAMidNoteRelatedSection() {
        let note = """
        # Title

        ## Related
        - [[One]]

        ## Notes

        Trailing prose.
        """
        let updated = NoteEdits.addingRelatedLink("Two", to: note)
        #expect(updated.contains("- [[One]]\n- [[Two]]\n\n## Notes"))
        #expect(updated.hasSuffix("Trailing prose."))
    }

    /// Repeated inserts into a mid-note section must not widen the blank gap
    /// before the next heading each time.
    @Test func midNoteInsertsKeepASingleBlankLineBeforeTheNextHeading() {
        var note = "## Related\n- [[One]]\n\n## Notes\n"
        for title in ["Two", "Three"] { note = NoteEdits.addingRelatedLink(title, to: note) }
        #expect(!note.contains("\n\n\n"))
        #expect(note.contains("- [[Three]]\n\n## Notes"))
    }

    /// Matching is on the heading text, so casing and stray spacing still find
    /// the section a previous run wrote.
    @Test func relatedHeadingMatchIgnoresCaseAndSurroundingSpace() {
        let note = "Body.\n\n##  related  \n- [[One]]\n"
        let updated = NoteEdits.addingRelatedLink("Two", to: note)
        #expect(updated.components(separatedBy: .newlines).filter { $0.contains("elated") }.count == 1)
        #expect(updated.contains("- [[Two]]"))
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

    // MARK: - Summary callout

    @Test func summaryGoesAboveTheBodyOfAPlainNote() {
        let updated = NoteEdits.insertingSummaryCallout("It is about notes.", into: "# Title\n\nBody.")
        #expect(updated == "> [!summary] Summary\n> It is about notes.\n\n# Title\n\nBody.")
    }

    /// The one position that would corrupt the note is above the front matter,
    /// so that is the case worth pinning.
    @Test func summaryGoesBelowFrontMatterNotAboveIt() {
        let note = "---\ntitle: Thing\n---\n# Title\n\nBody."
        let updated = NoteEdits.insertingSummaryCallout("Short.", into: note)
        #expect(updated.hasPrefix("---\ntitle: Thing\n---\n"))
        #expect(updated.contains("---\n> [!summary] Summary\n> Short.\n\n# Title"))
    }

    /// A multi-line summary has to be quoted on every line, or the callout ends
    /// at the first newline and the rest becomes body text.
    @Test func everyLineOfAMultiLineSummaryIsQuoted() {
        let updated = NoteEdits.insertingSummaryCallout("One.\nTwo.\nThree.", into: "Body.")
        #expect(updated.hasPrefix("> [!summary] Summary\n> One.\n> Two.\n> Three.\n\n"))
    }
}
