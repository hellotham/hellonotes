//
//  HTMLBlockParsingTests.swift
//  MarkdownCoreTests
//
//  Raw HTML had no block kind at all: `<div>` parsed as a paragraph, so the
//  editor ran the inline parser over the markup and styled it as prose, while
//  Preview (cmark with `CMARK_OPT_UNSAFE`, as GitHub does) rendered it. The
//  two could not agree because only one of them knew what it was looking at.
//
//  CommonMark §4.6 defines seven start conditions, and the number matters
//  after the block opens too — it is what says where the block ends.
//

import Foundation
import Testing
@testable import MarkdownCore

@Suite struct HTMLBlockParsingTests {

    private func kinds(_ text: String) -> [BlockKind] {
        BlockParser.fullParse(text as NSString).blocks.map(\.kind)
    }

    /// Block kinds without the empty line every `\n`-terminated document ends
    /// on — it is a real block, and it is never what a test is about.
    private func structure(_ text: String) -> [BlockKind] {
        var all = kinds(text)
        if case .blank = all.last, text.hasSuffix("\n") { all.removeLast() }
        return all
    }

    private func html(_ text: String) -> [(condition: Int, closed: Bool)] {
        kinds(text).compactMap {
            if case .htmlBlock(let condition, let closed) = $0 { return (condition, closed) }
            return nil
        }
    }

    // MARK: - The seven start conditions

    @Test func condition1IsARawTextElement() {
        let blocks = html("<pre>\n*not emphasis*\n\nstill raw\n</pre>\n")
        #expect(blocks.count == 1)
        #expect(blocks[0].condition == 1)
        #expect(blocks[0].closed)
        // The whole thing is one block — a blank line does not end conditions 1–5.
        #expect(structure("<pre>\n*x*\n\ny\n</pre>\n").count == 1)
    }

    @Test func condition2IsAComment() {
        #expect(html("<!-- a comment -->\n").first?.condition == 2)
        // Spanning lines, closing on the line that carries `-->`.
        let multi = html("<!--\nline\n-->\ntail\n")
        #expect(multi.first?.condition == 2)
        #expect(multi.first?.closed == true)
        #expect(structure("<!--\nline\n-->\ntail\n").count == 2)   // block + paragraph
    }

    @Test func conditions3And4And5() {
        #expect(html("<?php echo 1; ?>\n").first?.condition == 3)
        #expect(html("<!DOCTYPE html>\n").first?.condition == 4)
        #expect(html("<![CDATA[ raw ]]>\n").first?.condition == 5)
    }

    @Test func condition6IsAKnownBlockTag() {
        let blocks = html("<div>\nraw *text*\n</div>\n\nA paragraph.\n")
        #expect(blocks.count == 1)
        #expect(blocks[0].condition == 6)
        // Ends at the blank line, which belongs to what follows.
        let all = structure("<div>\nraw\n</div>\n\nA paragraph.\n")
        #expect(all.count == 3)
        if case .blank = all[1] {} else { Issue.record("expected a blank run after the block") }
        if case .paragraph = all[2] {} else { Issue.record("expected a trailing paragraph") }
    }

    @Test func aClosingBlockTagAlsoOpensCondition6() {
        #expect(html("</div>\n").first?.condition == 6)
    }

    @Test func condition7IsAnyCompleteTagAlone() {
        #expect(html("<custom-element>\n").first?.condition == 7)
        #expect(html("<a href=\"x\" data-n='1'>\n").first?.condition == 7)
        #expect(html("<br/>\n").first?.condition == 7)
        // Not alone on the line → not a block.
        #expect(html("<custom-element> trailing words\n").isEmpty)
        // Not a complete tag → not a block.
        #expect(html("<custom-element\n").isEmpty)
    }

    // MARK: - Interaction with paragraphs

    /// The one asymmetry in the spec: condition 7 may not interrupt a
    /// paragraph, so a lone tag on a continuation line is paragraph text.
    @Test func condition7CannotInterruptAParagraph() {
        #expect(html("Some prose.\n<custom-element>\n").isEmpty)
        // …but conditions 1–6 can.
        #expect(html("Some prose.\n<div>\n").first?.condition == 6)
        #expect(html("Some prose.\n<!-- c -->\n").first?.condition == 2)
    }

    // MARK: - Unterminated blocks (what you have while typing one)

    @Test func anUnclosedBlockIsStillABlockAndKnowsIt() {
        let open = html("<!-- half a comment\n")
        #expect(open.first?.condition == 2)
        #expect(open.first?.closed == false)
    }

    // MARK: - What must NOT become an HTML block

    @Test func ordinaryTextWithAngleBracketsIsUntouched() {
        #expect(html("5 < 6 and 7 > 6\n").isEmpty)
        #expect(html("a <not a tag\n").isEmpty)
        #expect(html("<3\n").isEmpty)
        // An autolink is inline, not a block.
        #expect(html("<https://example.com>\n").isEmpty)
        // Four spaces of indent is code, whatever it contains.
        #expect(html("    <div>\n").isEmpty)
    }

    @Test func inlineMarkdownIsNotParsedInsideAnHTMLBlock() {
        let blocks = BlockParser.fullParse("<div>\n*not emphasis*\n</div>\n" as NSString).blocks
        let htmlBlock = try? #require(blocks.first { if case .htmlBlock = $0.kind { return true }; return false })
        #expect(htmlBlock?.hasInlineContent == false)
    }

    // MARK: - The specification's own corpus

    /// Every example in the spec's "HTML blocks" section whose input starts an
    /// HTML block: the parser must agree that one starts there. This is the
    /// check that catches a start condition written from memory.
    @Test func specHTMLBlockExamplesOpenAnHTMLBlock() throws {
        let url = Bundle.module.url(forResource: "spec", withExtension: "txt")
        guard let url, let corpus = try? String(contentsOf: url, encoding: .utf8) else { return }
        var checked = 0, agreed = 0
        var missed: [String] = []
        for example in SpecCorpus.examples(in: corpus, section: "HTML blocks") {
            // Only the examples that really are HTML blocks. cmark wraps
            // inline HTML in a paragraph, so a `<p>` on the front of the
            // expected output is the section telling us this one is *not* a
            // block — `<del>*foo*</del>` is a paragraph containing tags, and
            // the parser is right to leave it alone.
            guard example.html.hasPrefix("<"),
                  !example.html.hasPrefix("<p>"),
                  !example.markdown.hasPrefix("    "),
                  example.markdown.hasPrefix("<") else { continue }
            checked += 1
            let opened = BlockParser.fullParse(example.markdown as NSString)
                .blocks.contains { if case .htmlBlock = $0.kind { return true }; return false }
            if opened { agreed += 1 } else { missed.append(example.markdown) }
        }
        #expect(checked > 20, "the corpus section should supply plenty of cases")
        #expect(agreed == checked,
                "failed to open an HTML block: \(missed.map { "\n---\n" + $0 }.joined())")
    }
}

/// Minimal reader for the spec corpus's fenced example format.
enum SpecCorpus {
    struct Example { let markdown: String; let html: String }

    static func examples(in corpus: String, section: String) -> [Example] {
        var out: [Example] = []
        var current = ""
        var lines = corpus.components(separatedBy: "\n")[...]
        while let line = lines.first {
            lines = lines.dropFirst()
            if line.hasPrefix("#") {
                current = line.drop(while: { $0 == "#" || $0 == " " }).description
                continue
            }
            guard line.hasPrefix("```````````````````````````````` example") else { continue }
            var markdown: [String] = [], html: [String] = [], inHTML = false
            while let body = lines.first {
                lines = lines.dropFirst()
                if body.hasPrefix("````````````````````````````````") { break }
                if body == "." { inHTML = true; continue }
                if inHTML { html.append(body) } else { markdown.append(body) }
            }
            guard current == section else { continue }
            out.append(Example(markdown: markdown.joined(separator: "\n") + "\n",
                               html: html.joined(separator: "\n")))
        }
        return out
    }
}

/// Which raw HTML blocks the editor may render on its own.
///
/// CommonMark block boundaries are not element boundaries, so an opening tag
/// alone is a complete block. Rendering one in isolation asks WebKit to close
/// it and draws a box around content that is not inside it.
@Suite struct HTMLBlockShapeTests {

    @Test func balancedFragmentsAreSelfContained() {
        #expect(HTMLBlockShape.isSelfContained("<div>text</div>"))
        #expect(HTMLBlockShape.isSelfContained("<table><tr><td>hi</td></tr></table>"))
        #expect(HTMLBlockShape.isSelfContained("<div>\n  <b>x</b>\n</div>"))
        #expect(HTMLBlockShape.isSelfContained("<DIV>x</DIV>"))          // case-insensitive
        #expect(HTMLBlockShape.isSelfContained("<img src=\"a.png\">"))   // void element
        #expect(HTMLBlockShape.isSelfContained("<br/>"))
        #expect(HTMLBlockShape.isSelfContained("<!-- a comment -->"))
        #expect(HTMLBlockShape.isSelfContained("<!DOCTYPE html>"))
    }

    @Test func halfElementsAreNot() {
        #expect(!HTMLBlockShape.isSelfContained("<div class=\"foo\">"))
        #expect(!HTMLBlockShape.isSelfContained("</div>"))
        #expect(!HTMLBlockShape.isSelfContained("<div><span>x</div>"))   // crossed
        #expect(!HTMLBlockShape.isSelfContained("<div>\n*hello*\n<foo><a>"))
        #expect(!HTMLBlockShape.isSelfContained("<!-- unterminated"))
        #expect(!HTMLBlockShape.isSelfContained("<div"))                 // no `>`
        #expect(!HTMLBlockShape.isSelfContained(""))
    }

    /// A closing tag that was never opened is not "balanced by luck".
    @Test func aStrayCloseIsNotBalanced() {
        #expect(!HTMLBlockShape.isSelfContained("</ins>\n*bar*"))
        #expect(!HTMLBlockShape.isSelfContained("<b>x</b></i>"))
    }

    /// Lines the browser throws away: nothing but tags, and every tag one the
    /// spec's own grammar accepts.
    @Test func wellFormedTagsOnlyLines() {
        #expect(HTMLBlockShape.isWellFormedTagsOnlyLine("</a></foo >"))
        #expect(HTMLBlockShape.isWellFormedTagsOnlyLine("<a><bab><c2c>"))
        #expect(HTMLBlockShape.isWellFormedTagsOnlyLine("<a/><b2/>"))
        #expect(HTMLBlockShape.isWellFormedTagsOnlyLine("<div class=\"x\">"))
        #expect(HTMLBlockShape.isWellFormedTagsOnlyLine("<a href='bar' title=title>"))
        #expect(HTMLBlockShape.isWellFormedTagsOnlyLine("<input disabled>"))   // valueless
        #expect(HTMLBlockShape.isWellFormedTagsOnlyLine("<!-- c --><b>"))
        #expect(HTMLBlockShape.isWellFormedTagsOnlyLine("<!DOCTYPE html>"))
    }

    /// The cases that make the strict grammar worth having. Every one of these
    /// satisfies `isTagsOnly` — it starts with `<` and reaches a `>` — and every
    /// one is text the page prints, so the loose predicate would have hidden it.
    @Test func autolinksAndMalformedTagsAreNotTags() {
        for text in ["<http://foo.bar.baz>", "<foo@bar.example.com>", "<m:abc>",
                     "<foo.bar.baz>", "< http://foo.bar >", "<>", "<33> <__>",
                     "<a h*#ref=\"hi\">", "<a href=\"hi'> <a href=hi'>",
                     "<a href='bar'title=title>", "</a href=\"foo\">"] {
            #expect(HTMLBlockShape.isTagsOnly(text), "loose predicate should accept \(text)")
            #expect(!HTMLBlockShape.isWellFormedTagsOnlyLine(text), "strict should reject \(text)")
        }
    }

    /// GitHub's tag filter escapes these, so the reader sees the angle brackets.
    @Test func tagFilteredElementsPrintThemselves() {
        #expect(HTMLBlockShape.isEscapedByTagFilter("<strong> <title> <style> <em>"))
        #expect(HTMLBlockShape.isEscapedByTagFilter("</xmp>"))
        #expect(!HTMLBlockShape.isEscapedByTagFilter("<strong> <em>"))
    }

    /// …and an escaped tag is text, so it opens no element. `<blockquote>` /
    /// `<xmp> is disallowed.` / `</blockquote>` used to read as unbalanced —
    /// half an element, nothing rendered — over an `<xmp>` the page never gets.
    @Test func aTagFilteredTagOpensNothing() {
        #expect(HTMLBlockShape.isSelfContained(
            "<blockquote>\n  <xmp> is disallowed.  <XMP> is also disallowed.\n</blockquote>"))
        #expect(HTMLBlockShape.opensTagFilteredElement("<style\n  type=\"text/css\">"))
        #expect(HTMLBlockShape.opensTagFilteredElement("</script>"))
        #expect(!HTMLBlockShape.opensTagFilteredElement("<div><style>"))   // first tag only
        #expect(!HTMLBlockShape.opensTagFilteredElement("<pre>"))          // not filtered
    }

    /// Where the HTML *tokenizer* runs off the end — a different question from
    /// "is this a well-formed tag", and the one that decides what the page
    /// paints. cmark prints `<div *???-&&&-<---` as text; the browser eats it.
    @Test func aTagWithNoCloseSwallowsTheRest() {
        #expect(HTMLBlockShape.unterminatedRunStart("<div id=\"foo\"\n*hi*") == 0)
        #expect(HTMLBlockShape.unterminatedRunStart("<div class\nfoo") == 0)
        #expect(HTMLBlockShape.unterminatedRunStart("<div *???-&&&-<---\n*foo*") == 0)
        #expect(HTMLBlockShape.unterminatedRunStart("<!-- never closed") == 0)
        // Not at the start: the text before the runaway tag is still painted.
        #expect(HTMLBlockShape.unterminatedRunStart("<div>\ntext\n<span") == 11)
    }

    @Test func closedConstructsSwallowNothing() {
        #expect(HTMLBlockShape.unterminatedRunStart("<div>x</div>") == nil)
        #expect(HTMLBlockShape.unterminatedRunStart("<!-- c --> after") == nil)
        // A `>` inside a quoted attribute value does not end the tag, and a
        // `<` that no letter follows never starts one.
        #expect(HTMLBlockShape.unterminatedRunStart("<a title=\"a>b\">x</a>") == nil)
        #expect(HTMLBlockShape.unterminatedRunStart("a < b and 3 <4") == nil)
    }

    /// One stack across several blocks: what `isSelfContained` asks of a
    /// fragment, asked of a span.
    @Test func theStackCarriesAcrossBlocks() {
        var stack: [String] = []
        #expect(HTMLBlockShape.advance(stack: &stack, through: "<table>\n") == true)
        #expect(stack == ["table"])
        #expect(HTMLBlockShape.advance(stack: &stack, through: "<tr>\n") == true)
        #expect(HTMLBlockShape.advance(stack: &stack, through: "<td>\nHi\n</td>\n") == true)
        #expect(stack == ["table", "tr"])
        #expect(HTMLBlockShape.advance(stack: &stack, through: "</tr>\n") == true)
        #expect(HTMLBlockShape.advance(stack: &stack, through: "</table>\n") == true)
        #expect(stack.isEmpty)
    }

    /// Crossed tags end the search rather than widening it — no walk forward
    /// rescues them, and a span that will never balance must not swallow the
    /// rest of the note looking for one.
    @Test func crossedTagsStopTheWalk() {
        var stack: [String] = []
        #expect(HTMLBlockShape.advance(stack: &stack, through: "<b>x</i>") == nil)
    }
}
