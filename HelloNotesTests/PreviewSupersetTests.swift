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
}
