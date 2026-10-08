//
//  PreviewSupersetTests.swift
//  HelloNotesTests
//
//  Preview renders the note, not a GitHub approximation of it.
//
//  GFM parity is the floor. A HelloNotes note is a *superset* of GFM, and the
//  parts that make it one — LaTeX, `![[transclusion]]`, Mermaid — are the
//  reasons to use the app. Preview drew none of them: `$$…$$` arrived as
//  literal dollars, a Mermaid fence stayed source, and an embed became
//  `![](Some%20Note)`, an `<img>` pointing at a Markdown file, which a web view
//  cannot load — so the page had a silent blank where the note should be.
//
//  What is asserted here is mostly the *opposite* of the feature: the cases
//  that must come through untouched. A note that documents the syntax has to
//  render as text, exactly as GitHub and the editor render it, and that is the
//  half a substitution pass gets wrong.
//

import Testing
import Foundation
@testable import HelloNotes

@Suite @MainActor
struct PreviewSupersetTests {

    private func apply(_ text: String) async -> String {
        await PreviewSuperset.apply(to: text, isDark: true, embeds: nil)
    }

    /// The renderer works at all in this environment — otherwise every
    /// "was substituted" assertion below would pass vacuously by falling back
    /// to the original text.
    @Test func theMathRendererIsAvailable() async {
        let out = await apply("$$x^2$$")
        #expect(out.contains("hn-math-block"),
                "no image was produced, so the substitution tests prove nothing")
        #expect(out.contains("data:image/png;base64,"), "the image must be inline, not fetched")
    }

    /// Inline and block maths are different shapes and must stay different.
    @Test func inlineAndBlockMathAreDistinct() async {
        let inline = await apply("Euler: $e^{i\\pi}+1=0$ is neat.")
        #expect(inline.contains("hn-math-inline"))
        #expect(inline.contains("Euler:"), "the surrounding prose survives")
        #expect(inline.contains("is neat."))

        let block = await apply("$$\\int_0^\\infty e^{-x^2}\\,dx$$")
        #expect(block.contains("hn-math-block"))
        #expect(!block.contains("hn-math-inline"))
    }

    /// A `$$` spanning lines is one construct.
    @Test func multiLineBlockMathIsCollected() async {
        let out = await apply("$$\n\\frac{a}{b}\n$$")
        #expect(out.contains("hn-math-block"))
        #expect(!out.contains("\\frac{a}{b}") || out.contains("alt="),
                "the source may survive only as the alt text")
    }

    /// **Code is never a construct.** This is the rule the feature is most
    /// likely to break, and the one a note that explains the syntax depends on.
    @Test func codeIsLeftExactlyAsItWas() async {
        let fenced = "```\n$$x^2$$\n![[Some Note]]\n```"
        #expect(await apply(fenced) == fenced, "a fenced block is verbatim, including maths")

        let span = "Write `$x$` for inline maths and `![[Note]]` to embed."
        #expect(await apply(span) == span, "an inline code span is verbatim")

        let mixed = "Real: $a$ — documented: `$a$`"
        let out = await apply(mixed)
        #expect(out.contains("hn-math-inline"), "the real one is drawn")
        #expect(out.contains("`$a$`"), "the documented one is not")
    }

    /// A Mermaid fence is drawn; a fence that merely *quotes* Mermaid is not.
    @Test func onlyAMermaidFenceBecomesADiagram() async {
        let quoted = "```text\nflowchart LR\n  A --> B\n```"
        #expect(await apply(quoted) == quoted,
                "the info string decides — `text` is code even if it looks like a diagram")

        let real = "```mermaid\nflowchart LR\n  A --> B\n```"
        let out = await apply(real)
        #expect(!out.contains("```"), "the fence itself is consumed")
    }

    /// An unterminated construct is not a construct.
    ///
    /// Half a document must never disappear because someone typed `$$` and
    /// then thought better of it.
    @Test func anUnterminatedConstructGivesTheTextBack() async {
        let dangling = "before\n$$\nx^2\nstill writing"
        let out = await apply(dangling)
        #expect(out.contains("before"))
        #expect(out.contains("still writing"), "text after an unclosed $$ must survive")

        let openFence = "```mermaid\nflowchart LR"
        let fenceOut = await apply(openFence)
        #expect(fenceOut.contains("flowchart LR"))
    }

    /// Plain GFM is not touched at all — the whole point of keeping parity.
    @Test func ordinaryMarkdownPassesThroughUnchanged() async {
        let plain = """
        # Heading

        A paragraph with **bold**, `code`, and a [link](https://example.com).

        | a | b |
        |---|---|
        | 1 | 2 |

        - [ ] a task
        """
        #expect(await apply(plain) == plain)
    }

    /// A callout keeps the editor's taxonomy: same word, same colour class.
    @Test func calloutsCarryTheEditorsTaxonomy() async {
        let out = await apply("> [!warning] They come in several kinds\n> note, tip, danger")
        #expect(out.contains("hn-callout-warning"), "the type decides the class")
        #expect(out.contains("They come in several kinds"), "the title survives")
        #expect(out.contains("note, tip, danger"), "so does the body")
        #expect(!out.contains("[!warning]"), "the marker itself is chrome, not content")

        for (word, cls) in [("tip", "tip"), ("caution", "warning"), ("bug", "danger"),
                            ("done", "success"), ("faq", "question"), ("tldr", "abstract")] {
            #expect(PreviewSuperset.Callout.cssClass(word) == cls,
                    "“\(word)” should colour as \(cls), as it does in the editor")
        }
    }

    /// A callout's body is still Markdown — it must reach cmark-gfm, not be
    /// frozen into the HTML.
    @Test func aCalloutBodyIsStillMarkdown() async {
        let out = await apply("> [!note] Title\n> Some **bold** and a [link](https://x.com)")
        #expect(out.contains("**bold**"), "the body is handed on as Markdown, not pre-rendered")
        #expect(out.contains("\n\n"), "blank lines are what let cmark-gfm see it")
    }

    /// An ordinary blockquote is not a callout and must not become one.
    @Test func aPlainBlockquoteIsUntouched() async {
        let quote = "> Just a quotation.\n> Second line."
        #expect(await apply(quote) == quote)
    }

    /// The dialect's inline spellings.
    @Test func highlightAndCommentAreRendered() async {
        let out = await apply("A ==highlighted== phrase and %%a note to self%%.")
        #expect(out.contains("<mark class=\"hn-highlight\">highlighted</mark>"))
        #expect(out.contains("hn-comment"))
        #expect(out.contains("a note to self"),
                "a comment is dimmed, never deleted — Preview must not disagree with Edit about what the document says")

        let code = "Type `==x==` and `%%y%%` to get them."
        #expect(await apply(code) == code, "documented syntax stays literal")
    }

    /// An embed with no provider stays as written rather than becoming a
    /// broken image — the state Preview was in before this existed.
    @Test func anEmbedWithoutAProviderIsLeftForTheNormalRewrite() async {
        let out = await apply("A whole note:\n\n![[Examples/Nested Note]]")
        #expect(out.contains("![[Examples/Nested Note]]"),
                "with no provider it must reach NoteMarkdown untouched")
    }

    // MARK: - Drawn once

    /// A diagram source no other test has drawn.
    private func freshDiagram() -> String {
        "graph TD\n  Start --> N\(UUID().uuidString.prefix(8))"
    }

    /// A pass keeps the diagrams it draws, as the tags they became.
    @Test func aDrawnDiagramIsKept() async {
        let source = freshDiagram()
        let out = await apply("```mermaid\n\(source)\n```\n")
        #expect(out.contains("hn-diagram"), "the diagram was not drawn, so this tests nothing")
        let kept = PreviewSuperset.rendered.tag(for: PreviewSuperset.diagramKey(source, isDark: true))
        #expect(kept?.contains("data:image/png;base64,") == true, "the drawn diagram was not kept")
    }

    /// And the next pass takes what was kept rather than drawing it again —
    /// every diagram was drawn again at every change to the note, and in
    /// Split mode that was every keystroke. Seeded with a tag no renderer
    /// draws, so the only way into the page is the cache.
    @Test func aKeptDiagramIsNotDrawnAgain() async {
        let source = freshDiagram()
        let kept = "<img class=\"hn-diagram\" alt=\"kept\" width=\"1\" height=\"1\" src=\"data:image/png;base64,AA==\">"
        PreviewSuperset.rendered.store(kept, for: PreviewSuperset.diagramKey(source, isDark: true))
        let out = await apply("```mermaid\n\(source)\n```\n")
        #expect(out.contains(kept), "the diagram was drawn again rather than taken from the cache")
    }

    /// The same for a formula, which is drawn on the main actor.
    @Test func aKeptFormulaIsNotDrawnAgain() async {
        let source = "x^{2} + \(Int.random(in: 100_000...999_999))"   // no other test's
        let kept = "<img class=\"hn-math-block\" alt=\"kept\" width=\"1\" height=\"1\" src=\"data:image/png;base64,AA==\">"
        PreviewSuperset.rendered.store(kept, for: PreviewSuperset.mathKey(source, fontSize: 20, isDark: true,
                                                                         class: "hn-math-block"))
        let out = await apply("$$\(source)$$")
        #expect(out.contains(kept), "the formula was drawn again rather than taken from the cache")
    }

    /// A pass whose task is cancelled — the note changed again, or Preview
    /// went away — stops, and draws nothing more. Drawing ran to the end
    /// whoever had stopped waiting for it.
    @Test func aCancelledPassDrawsNothing() async {
        let source = freshDiagram()
        let text = "```mermaid\n\(source)\n```\n"
        let pass = Task { await PreviewSuperset.apply(to: text, isDark: true, embeds: nil) }
        pass.cancel()
        let out = await pass.value
        #expect(out == text)
        #expect(PreviewSuperset.rendered.tag(for: PreviewSuperset.diagramKey(source, isDark: true)) == nil,
                "a cancelled pass drew a diagram")
    }
}

/// What `PreviewSuperset` keeps of what it drew (`RenderedTags`): bounded by
/// size, evicted by pass.
struct RenderedTagsTests {

    /// A note whose images outgrow the budget is drawn once, not at every
    /// pass: the pass that drew them keeps them, and the next, visiting them in
    /// the same order, finds every one. Evicting the oldest stored first, it
    /// evicted each before the next pass reached it, and found almost none.
    @Test func aPassThatOutgrowsTheBudgetFindsEverythingNextTime() {
        let tags = RenderedTags(limit: 1_000)
        let first = tags.beginPass()
        for index in 0..<20 {
            tags.store(String(repeating: "x", count: 200), for: "diagram \(index)", pass: first)
        }
        let second = tags.beginPass()
        let found = (0..<20).filter { tags.tag(for: "diagram \($0)", pass: second) != nil }.count
        #expect(found == 20, "the next pass found \(found) of 20")
    }

    /// Room is made from what the oldest passes used, never from what the
    /// pass storing has used — a hit counts as use.
    @Test func roomIsMadeFromTheOldestPasses() {
        let tags = RenderedTags(limit: 1_000)
        let old = tags.beginPass()
        tags.store(String(repeating: "a", count: 600), for: "old", pass: old)
        let later = tags.beginPass()
        tags.store(String(repeating: "b", count: 600), for: "used", pass: later)
        #expect(tags.tag(for: "old") == nil, "the oldest pass's entry was kept over budget")

        let now = tags.beginPass()
        #expect(tags.tag(for: "used", pass: now) != nil)
        tags.store(String(repeating: "c", count: 600), for: "new", pass: now)
        #expect(tags.tag(for: "used") != nil, "an entry the storing pass used was evicted")
        #expect(tags.tag(for: "new") != nil)
    }

    /// A key carries the whole diagram or formula it names, and an entry for
    /// one that drew nothing is all key: keys count.
    @Test func keysCountTowardsTheBudget() {
        let tags = RenderedTags(limit: 1_000)
        tags.store("", for: String(repeating: "k", count: 900), pass: tags.beginPass())
        #expect(tags.size >= 900)
    }

    /// A card is kept for the image it was drawn from: the provider draws
    /// again when the note it shows changes, under the same name.
    @Test func aCardIsKeptForTheImageItWasDrawnFrom() {
        let tags = RenderedTags(limit: 1 << 20)
        let drawn = NSObject(), redrawn = NSObject()
        tags.store("<img>", for: "card", drawnFrom: drawn)
        #expect(tags.tag(for: "card", drawnFrom: drawn) == "<img>")
        #expect(tags.tag(for: "card", drawnFrom: redrawn) == nil, "a card drawn again was taken from the cache")
    }
}
