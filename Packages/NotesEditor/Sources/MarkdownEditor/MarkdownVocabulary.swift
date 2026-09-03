//
//  MarkdownVocabulary.swift
//  MarkdownEditor
//
//  The words this app is *made of*, so it stops underlining them in red.
//
//  Continuous spell checking is on in the Mac editor and should be: prose is
//  what people write here. But the vocabulary of a Markdown note-taker is not
//  in the system dictionary, so "transclusion", "backlink", "frontmatter",
//  "Mermaid" and "YAML" all drew the misspelling squiggle — including in the
//  app's own bundled manual, which is the first thing a new user reads, and in
//  the App Store screenshots, where it reads as a typo in the marketing.
//
//  This does **not** touch the user's dictionary. `setIgnoredWords` is scoped
//  to one spell-check document tag — the text view's own — so it lasts as long
//  as that view and teaches the checker nothing about any other app. Learning
//  the words globally would have been easier and would have edited a file in
//  the user's home directory to fix a cosmetic problem in ours.
//
//  Two rules for the list. It holds only words the *app or the format* forces
//  on the writer, never words that merely appear in the sample notes — the
//  checker must still catch a real misspelling in a real note. And it is
//  case-insensitive in effect: `setIgnoredWords` matches exactly, so each entry
//  that is normally capitalised carries both spellings.
//

#if canImport(AppKit)
import AppKit
#else
import Foundation
#endif

enum MarkdownVocabulary {

    /// Terms of the format and of this app. Sorted, so a diff reads.
    /// Derived from the bundled collection, not from memory: `/tmp/spellscan`
    /// ran `NSSpellChecker` over every `DefaultCollection/*.md` with code,
    /// math, front matter, link targets, URLs and tags stripped, and these are
    /// the words it flagged that are the format's or the app's rather than
    /// mistakes. (It also flagged `colour`, `licence`, `Organising` and
    /// `Summarise` — British spellings, correct, and not flagged by the
    /// dictionary the app actually runs against; and `frac`, `infty`, `sqrt`,
    /// which are LaTeX inside `$$` blocks and only ever visible while the caret
    /// is in the block.)
    static let words: [String] = [
        "backlink", "Backlink",
        "backlinks", "Backlinks",
        "blockquote", "Blockquote",
        "blockquotes", "Blockquotes",
        "callout", "Callout",
        "callouts", "Callouts",
        "changelog", "Changelog",
        "frontmatter", "Frontmatter",
        "GFM",
        "HelloNotes",
        "markdown", "Markdown",
        "mermaid", "Mermaid",
        "Obsidian",
        "transclude", "Transclude",
        "transcluded", "Transcluded",
        "transclusion", "Transclusion",
        "unlinked", "Unlinked",
        "unstyled", "Unstyled",
        "wikilink", "Wikilink",
        "wikilinks", "Wikilinks",
        "yaml", "YAML",
    ]

    /// Tell `view`'s spell checker to leave the app's own vocabulary alone.
    ///
    /// Per **document tag**, never global: nothing here reaches the user's
    /// learned-words file or any other application.
    #if canImport(AppKit)
    static func ignore(in view: NSTextView) {
        NSSpellChecker.shared.setIgnoredWords(words,
                                              inSpellDocumentWithTag: view.spellCheckerDocumentTag)
    }
    #else
    // Deliberately nothing on iOS, and the list above is still shared so the
    // vocabulary is one thing rather than two. iOS sets
    // `spellCheckingType = .no` on the editor for a *measured* reason — the
    // keyboard's autocorrection controller blocks the main thread for ~90ms per
    // keystroke behind `UIKeyboardTaskQueue` (see `MarkdownEditorView`) — so
    // there is no checker there to teach. Spelled as an `#else` rather than a
    // narrower gate because `ShellComplianceTests` is right that "this platform
    // gets nothing" should be a decision on the page.
    #endif
}
