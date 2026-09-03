//
//  MarkdownVocabularyTests.swift
//  MarkdownEditorTests
//

#if canImport(AppKit)
import AppKit
import Testing
@testable import MarkdownEditor

@MainActor
struct MarkdownVocabularyTests {

    /// The mechanism works — and the control proves the test can fail.
    ///
    /// Asserting only "the ignored word is not flagged" would pass for a word
    /// the system dictionary already knows, and would therefore pass with
    /// `ignore(in:)` deleted. `zzyzxqqq` is flagged either way, so it is the
    /// negative control: if the checker stops flagging *that*, the assertion is
    /// measuring nothing.
    @Test func ignoredWordsAreNotFlaggedAndTheControlStillIs() {
        let view = NSTextView(frame: .init(x: 0, y: 0, width: 200, height: 100))
        let tag = view.spellCheckerDocumentTag
        let checker = NSSpellChecker.shared
        defer { checker.closeSpellDocument(withTag: tag) }

        func flagged(_ word: String) -> Bool {
            checker.checkSpelling(of: word, startingAt: 0, language: "en",
                                  wrap: false, inSpellDocumentWithTag: tag,
                                  wordCount: nil).location != NSNotFound
        }

        #expect(flagged("zzyzxqqq"), "the control must be flagged, or this test proves nothing")
        #expect(flagged("transclusion"), "precondition: the system does not know this word")

        MarkdownVocabulary.ignore(in: view)

        #expect(!flagged("transclusion"))
        #expect(!flagged("backlinks"))
        #expect(!flagged("blockquotes"))
        // Capitalised too. `setIgnoredWords` is not documented as
        // case-insensitive, so the list carries both spellings rather than
        // trusting that it is — a sentence starts with these words as often as
        // not, and "Transclusion" is a heading in the bundled manual.
        #expect(!flagged("Transclusion"))
        #expect(flagged("zzyzxqqq"), "ignoring our vocabulary must not disable checking")
    }

    /// Grouped alphabetically and free of duplicates, so a diff reads.
    @Test func theListIsTidy() {
        let words = MarkdownVocabulary.words
        #expect(Set(words).count == words.count, "duplicate entry")
        // Case-folded order only: each term sits with its own variants, and
        // whether the lower- or upper-case spelling comes first inside a group
        // is not worth a rule.
        let folded = words.map { $0.lowercased() }
        #expect(folded == folded.sorted(), "keep the list alphabetical, case-folded")

        // Every ordinary word carries a sentence-initial twin. Acronyms are
        // exempt — the capitalised form of `yaml` is `YAML`, which is already
        // there, and `Yaml` is not a spelling anyone uses.
        for w in words where w == w.lowercased() && w.count > 3 && !words.contains(w.uppercased()) {
            #expect(words.contains(w.prefix(1).uppercased() + w.dropFirst()),
                    "\(w) has no capitalised twin")
        }
    }
}
#endif
