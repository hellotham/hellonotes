//
//  NoteMarkdownTests.swift
//  GFMRenderTests
//
//  `NoteMarkdown.prepare` is the first half of Preview: the note goes through
//  it before cmark-gfm ever sees it, so what it does *is* what Preview shows.
//  While it lived in the app (`GitHubMarkdown`) nothing tested it and nothing
//  else could reach it — which is how `RenderParity` came to render its
//  preview side from the raw note and name a `![[foo]]` embed a permanent
//  divergence. The two app surfaces had agreed all along.
//

import Foundation
import Testing
import MarkdownCore
@testable import GFMRender

struct NoteMarkdownTests {

    // MARK: - The wiki constructs

    @Test func embedBecomesAnImage() {
        #expect(NoteMarkdown.prepare("![[foo]]\n") == "![](foo)\n")
    }

    @Test func wikiLinkBecomesALink() {
        #expect(NoteMarkdown.prepare("[[foo]]\n") == "[foo](foo)\n")
    }

    @Test func aliasBecomesTheLinkText() {
        #expect(NoteMarkdown.prepare("[[Target|Display]]") == "[Display](Target)")
    }

    /// An embed has nowhere to *show* an alias, so it is dropped rather than
    /// turned into alt text — the same choice Obsidian makes.
    @Test func embedDropsItsAlias() {
        #expect(NoteMarkdown.prepare("![[foo|caption]]") == "![](foo)")
    }

    /// The destination is percent-encoded, so a note with a space in its name
    /// resolves; the *text* keeps the name as written.
    @Test func destinationIsEncodedAndTextIsNot() {
        #expect(NoteMarkdown.prepare("[[Second Brain]]") == "[Second Brain](Second%20Brain)")
        #expect(NoteMarkdown.prepare("[[Note#Heading]]") == "[Note#Heading](Note%23Heading)")
    }

    // MARK: - What must survive untouched

    /// Documentation of the syntax is not use of the syntax. GitHub prints
    /// `` `[[Note]]` `` literally and so must Preview — otherwise the sentence
    /// explaining wiki links turns into a wiki link.
    @Test func codeSpansAreLiteral() {
        let line = "Type `[[Note]]` to link, or `![[Note]]` to embed."
        #expect(NoteMarkdown.prepare(line) == line)
    }

    @Test func fencedCodeIsLiteral() {
        let note = """
        ```markdown
        [[Note]] and ![[Note]]
        ```

        """
        #expect(NoteMarkdown.prepare(note) == note)
    }

    // MARK: - Front matter

    /// Stripped, because Preview shows the note and not its metadata — and
    /// stripped by asking `BlockParser`, so Preview removes exactly the block
    /// the editor folds. Two rules would eventually be two answers.
    @Test func frontMatterIsDropped() {
        let note = """
        ---
        title: Meeting notes
        tags: [a, b]
        ---
        # Body

        """
        #expect(NoteMarkdown.prepare(note) == "# Body\n")
    }

    /// Two `---` lines are not front matter on their own. A note that opens
    /// with a horizontal rule would otherwise have everything down to its next
    /// rule deleted from Preview and merely concealed in Edit.
    @Test func aRuleIsNotFrontMatter() {
        let note = """
        ---
        Just a paragraph between two rules.
        ---
        Body.

        """
        #expect(NoteMarkdown.prepare(note) == note)
    }

    // MARK: - The whole point: Preview draws the embed

    /// End to end, through the renderer Preview actually uses. This is the
    /// assertion `RenderParity` was missing: `![[foo]]` reaches WebKit as an
    /// `<img>`, which is what the editor draws in its place.
    @Test func theEmbedReachesTheRendererAsAnImage() {
        let html = GFMRenderer.html(NoteMarkdown.prepare("![[foo]]\n"))
        #expect(html.contains("<img"))
        #expect(html.contains("src=\"foo\""))
        #expect(!html.contains("[["))
    }

    /// …and the construct the editor calls an embed is the construct that gets
    /// rewritten. `InlineParser` is the editor's own answer to "is this a wiki
    /// embed"; if the two ever disagree, one surface draws a picture and the
    /// other prints eight characters of source.
    @Test func theEditorAgreesThisIsAnEmbed() {
        let ns = "![[foo]]" as NSString
        let nodes = InlineParser.parse(ns, in: NSRange(location: 0, length: ns.length))
        #expect(nodes.count == 1)
        guard case .wikiLink(let target, let isEmbed) = nodes.first?.kind else {
            Issue.record("the editor does not read `![[foo]]` as a wiki construct")
            return
        }
        #expect(target == "foo")
        #expect(isEmbed)
    }

    // MARK: - And nothing else moves

    /// Every GFM spec example that holds no wiki construct passes through
    /// unchanged. `RenderParity` renders its preview side through `prepare`
    /// now, so anything this touches is a corpus-wide measurement change —
    /// and the sweep reports an aggregate, which is exactly where a trade
    /// hides behind a win.
    /// The five spec examples that do hold a `[[`, spelled out. Four of them
    /// are CommonMark link tests that merely *look* like wiki syntax, and only
    /// the two the editor also reads as wiki links may change — otherwise the
    /// preview side of the sweep has quietly started rendering a different
    /// corpus than the one the editor is measured against.
    @Test func onlyTheWikiShapedExamplesChange() {
        // #528, #568 — no `]]` to close on, so neither engine sees a wiki link.
        #expect(NoteMarkdown.prepare("![[[foo](uri1)](uri2)](uri3)\n")
                == "![[[foo](uri1)](uri2)](uri3)\n")
        #expect(NoteMarkdown.prepare("[[bar [foo]\n\n[foo]: /url\n")
                == "[[bar [foo]\n\n[foo]: /url\n")
        // #556, #567 — the editor conceals these as wiki links too (target
        // `[foo` and `*foo* bar`), so Preview following it is the agreement,
        // not a break in it. Both stay one line tall either way.
        #expect(NoteMarkdown.prepare("[[[foo]]]\n\n[[[foo]]]: /url\n")
                == "[[foo](%5Bfoo)]\n\n[[foo](%5Bfoo)]: /url\n")
        #expect(NoteMarkdown.prepare("[[*foo* bar]]\n\n[*foo* bar]: /url \"title\"\n")
                == "[*foo* bar](*foo*%20bar)\n\n[*foo* bar]: /url \"title\"\n")
        // #598 — the one that was named as a divergence for the sweep's whole
        // life: the editor draws the embed, and now so does Preview.
        #expect(NoteMarkdown.prepare("![[foo]]\n\n[[foo]]: /url \"title\"\n")
                == "![](foo)\n\n[foo](foo): /url \"title\"\n")
    }

    @Test func theCorpusIsUntouchedWhereItHoldsNoWikiSyntax() throws {
        var examined = 0
        for example in try GFMSpec.examples() where !example.markdown.contains("[[") {
            examined += 1
            #expect(NoteMarkdown.prepare(example.markdown) == example.markdown,
                    "example #\(example.number) changed")
        }
        #expect(examined > 600)
    }
}
