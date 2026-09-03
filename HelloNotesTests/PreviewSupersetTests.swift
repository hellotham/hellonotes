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

    /// An embed with no provider stays as written rather than becoming a
    /// broken image — the state Preview was in before this existed.
    @Test func anEmbedWithoutAProviderIsLeftForTheNormalRewrite() async {
        let out = await apply("A whole note:\n\n![[Examples/Nested Note]]")
        #expect(out.contains("![[Examples/Nested Note]]"),
                "with no provider it must reach NoteMarkdown untouched")
    }
}
