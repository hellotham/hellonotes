import Testing
import Foundation
@testable import MarkdownEditor

/// Blockquote reveal is per **line**, the way Bear and Obsidian behave.
///
/// Reported as *"sometimes with vertical bar, sometimes with `>` unformatted"*,
/// then pinned down as *"after converting a paragraph to a blockquote by adding
/// `>` and moving away, the vertical bar does not show"*.
///
/// Reveal used to be per *block*, and a blockquote is one block however many
/// lines it spans — so a caret anywhere inside a quote showed the raw `>` on
/// every line of it and dropped every bar. That reads as the formatting
/// breaking at random, because whether it "works" depends on where the caret
/// happens to be and how many lines the quote has.
@Suite @MainActor
struct QuoteRevealTests {

    /// Is the character at `offset` concealed (collapsed to the 0.1pt font)?
    private func concealed(_ document: EditorDocument, at offset: Int) -> Bool {
        (document.storage.attributes(at: offset, effectiveRange: nil)[.font] as? PlatformFont)?
            .pointSize == 0.1
    }

    /// Does the line at `offset` carry the gutter-bar attribute the fragment draws?
    private func hasBar(_ document: EditorDocument, at offset: Int) -> Bool {
        document.storage.attribute(blockquotePlainAttribute,
                                   at: offset, effectiveRange: nil) != nil
    }

    /// The paragraph is one block *containing two lines*, so quoting the second
    /// line splits it in two and every later block index shifts.
    @Test func quotingTheSecondLineOfAParagraphStillGetsABar() {
        let document = EditorDocument(text: "alpha\nbravo\n")
        let insertAt = 6                                    // start of "bravo"

        document.selectionDidChange(NSRange(location: insertAt, length: 0))
        document.storage.replaceCharacters(in: NSRange(location: insertAt, length: 0), with: "> ")
        document.selectionDidChange(NSRange(location: insertAt + 2, length: 0))

        // Move the caret away, back up into "alpha".
        document.selectionDidChange(NSRange(location: 0, length: 0))

        let marker = (document.storage.string as NSString).range(of: ">").location
        #expect(concealed(document, at: marker), "the `>` is still showing raw")
        #expect(hasBar(document, at: marker), "the blockquote has no gutter bar")
    }

    /// The simple case: a one-line paragraph, quoted in place.
    @Test func quotingAWholeParagraphStillGetsABar() {
        let document = EditorDocument(text: "alpha\n\nbravo\n")
        let insertAt = 7                                    // start of "bravo"

        document.selectionDidChange(NSRange(location: insertAt, length: 0))
        document.storage.replaceCharacters(in: NSRange(location: insertAt, length: 0), with: "> ")
        document.selectionDidChange(NSRange(location: insertAt + 2, length: 0))
        document.selectionDidChange(NSRange(location: 0, length: 0))

        let marker = (document.storage.string as NSString).range(of: ">").location
        #expect(concealed(document, at: marker), "the `>` is still showing raw")
        #expect(hasBar(document, at: marker), "the blockquote has no gutter bar")
    }

    /// The caret on one line of a multi-line quote reveals *that line only*.
    @Test func onlyTheCaretsLineRevealsItsMarker() {
        let text = "> one\n> two\n> three\n"
        let document = EditorDocument(text: text)
        let ns = text as NSString
        let first = ns.range(of: ">").location
        let second = ns.range(of: ">", options: [], range: NSRange(location: first + 1, length: ns.length - first - 1)).location
        let third = ns.range(of: ">", options: [], range: NSRange(location: second + 1, length: ns.length - second - 1)).location

        document.selectionDidChange(NSRange(location: second + 2, length: 0))   // on "two"

        #expect(!concealed(document, at: second), "the caret's own line should show its `>`")
        #expect(!hasBar(document, at: second), "the revealed line sits at its natural indent, no bar")

        #expect(concealed(document, at: first), "line 1 is not the caret's line; its `>` should stay hidden")
        #expect(hasBar(document, at: first), "line 1 lost its gutter bar")
        #expect(concealed(document, at: third), "line 3 is not the caret's line; its `>` should stay hidden")
        #expect(hasBar(document, at: third), "line 3 lost its gutter bar")
    }

    /// Moving the caret between lines of the same block must restyle it — the
    /// block set is unchanged, so a block-only diff would skip the work.
    @Test func movingWithinAQuoteRestylesIt() {
        let text = "> one\n> two\n"
        let document = EditorDocument(text: text)
        let ns = text as NSString
        let first = ns.range(of: ">").location
        let second = ns.range(of: ">", options: [], range: NSRange(location: first + 1, length: ns.length - first - 1)).location

        document.selectionDidChange(NSRange(location: first + 2, length: 0))
        #expect(!concealed(document, at: first))
        #expect(concealed(document, at: second))

        document.selectionDidChange(NSRange(location: second + 2, length: 0))
        #expect(concealed(document, at: first), "line 1 stayed revealed after the caret left it")
        #expect(hasBar(document, at: first), "line 1 never got its bar back")
        #expect(!concealed(document, at: second))
    }
}
