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
        #expect(NoteMarkdown.prepare("[[foo]]\n") == "[foo](hellonotes-wiki:foo)\n")
    }

    @Test func aliasBecomesTheLinkText() {
        #expect(NoteMarkdown.prepare("[[Target|Display]]") == "[Display](hellonotes-wiki:Target)")
    }

    /// An embed has nowhere to *show* an alias, so it is dropped rather than
    /// turned into alt text — the same choice Obsidian makes.
    @Test func embedDropsItsAlias() {
        #expect(NoteMarkdown.prepare("![[foo|caption]]") == "![](foo)")
    }

    /// The destination is percent-encoded, so a note with a space in its name
    /// resolves; the *text* keeps the name as written.
    @Test func destinationIsEncodedAndTextIsNot() {
        #expect(NoteMarkdown.prepare("[[Second Brain]]") == "[Second Brain](hellonotes-wiki:Second%20Brain)")
        #expect(NoteMarkdown.prepare("[[Note#Heading]]") == "[Note#Heading](hellonotes-wiki:Note%23Heading)")
    }

    // MARK: - In a table, an alias's pipe is escaped

    /// The row a table holds an aliased link in: the pipe that starts the alias
    /// has to be escaped there, or it divides the cell.
    private static let tableWithAlias = """
    | Link | Kind |
    | --- | --- |
    | [[Examples/Nested Note\\|an alias]] | aliased |

    """

    /// A table's aliased link names the note, not the note with a backslash.
    /// The rewrite read the target up to the pipe, so the table's escape stayed
    /// in it — `Examples/Nested%20Note%5C` — while Edit, which reads a cell after
    /// the table has unescaped its pipes, named the note.
    @Test func aTablesAliasedLinkNamesTheNote() {
        let prepared = NoteMarkdown.prepare(Self.tableWithAlias)
        #expect(prepared.contains("[an alias](hellonotes-wiki:Examples/Nested%20Note)"), "\(prepared)")
        #expect(!prepared.contains("%5C"), "the table's escape is in the link: \(prepared)")
    }

    /// …through the renderer Preview uses: one link, in its own cell, the row
    /// still two cells wide.
    @Test func aTablesAliasedLinkReachesTheRendererWhole() {
        let html = GFMRenderer.html(NoteMarkdown.prepare(Self.tableWithAlias))
        #expect(html.contains("<td><a href=\"hellonotes-wiki:Examples/Nested%20Note\">an alias</a></td>"), "\(html)")
        #expect(html.components(separatedBy: "<td").count - 1 == 2, "the row lost or gained a cell: \(html)")
    }

    /// …and it is the note the editor follows. Edit reads the cell after the
    /// table has unescaped its pipes, and a wiki link's target is what comes
    /// before the first pipe; the two surfaces must name the same note.
    @Test func theEditorFollowsTheSameNote() throws {
        let row = try #require(Self.tableWithAlias.components(separatedBy: "\n").dropFirst(2).first)
        let cell = try #require(GFMTableLayout.cells(row).first)
        let ns = cell as NSString
        guard case .wikiLink(let content, false) = InlineParser.parse(ns, in: NSRange(location: 0, length: ns.length)).first?.kind else {
            Issue.record("the editor does not read the cell as a wiki link: \(cell)")
            return
        }
        let editors = String(WikiLinkSyntax.split(content).target)
        let prepared = NoteMarkdown.prepare(Self.tableWithAlias)
        let href = try #require(prepared.firstMatch(of: /\]\(hellonotes-wiki:([^)]*)\)/)).1
        #expect(String(href).removingPercentEncoding == editors, "Preview links to \(href); the editor to \(editors)")
    }

    /// A picture sized in a table — `![[picture.png\|300]]` — is the picture.
    @Test func aTablesSizedEmbedNamesThePicture() {
        let note = "| Picture |\n| --- |\n| ![[picture.png\\|300]] |\n"
        #expect(NoteMarkdown.prepare(note) == "| Picture |\n| --- |\n| ![](picture.png) |\n")
    }

    /// An alias holding an escaped pipe of its own keeps it escaped, or the
    /// rewritten link would divide the cell the original did not.
    @Test func anAliasesOwnEscapedPipeStaysEscaped() {
        let note = "| Link |\n| --- |\n| [[Note\\|either\\|or]] |\n"
        #expect(NoteMarkdown.prepare(note) == "| Link |\n| --- |\n| [either\\|or](hellonotes-wiki:Note) |\n")
        let html = GFMRenderer.html(NoteMarkdown.prepare(note))
        #expect(html.contains("<td><a href=\"hellonotes-wiki:Note\">either|or</a></td>"), "\(html)")
    }

    /// **Out of a table, `\|` begins an alias too** — the same link, so a
    /// row moved out of a table keeps its links, and the one rule every
    /// reader of a link reads it by (`WikiLinkSyntax`). Preview linked
    /// `Note%5C` here, as Edit coloured it, while following it reached `Note`
    /// (implemented.md §51.36). A line is a table row because the block
    /// parser says so, not because it holds a pipe.
    @Test func outOfATableAnEscapedAliasPipeIsAnAliasToo() {
        #expect(NoteMarkdown.prepare(#"[[Note\|alias]]"# + "\n") == "[alias](hellonotes-wiki:Note)\n")
        #expect(NoteMarkdown.prepare(#"a | [[Note\|alias]] | b"# + "\n") == "a | [alias](hellonotes-wiki:Note) | b\n")
        // An even run is escaped backslashes, and the name's.
        #expect(NoteMarkdown.prepare(#"[[Note\\|alias]]"# + "\n") == "[alias](hellonotes-wiki:Note%5C%5C)\n")
    }

    /// In a table the row's escape comes off first, as it does in the editor,
    /// which reads a cell after the row: `[[Note\\|alias]]` is `[[Note\|alias]]`
    /// in the cell, and names `Note` on both surfaces.
    @Test func inATableTheRowIsReadBeforeTheLink() throws {
        for (written, named) in [(#"Note\|alias"#, "Note"), (#"Note\\|alias"#, "Note"),
                                 (#"Note\\\|alias"#, #"Note\\"#)] {
            let table = "| Link |\n| --- |\n| [[\(written)]] |\n"
            let prepared = NoteMarkdown.prepare(table)
            let href = try #require(prepared.firstMatch(of: /\]\(hellonotes-wiki:([^)]*)\)/)).1
            #expect(String(href).removingPercentEncoding == named, "Preview: \(written) → \(href)")

            let row = try #require(table.components(separatedBy: "\n").dropFirst(2).first)
            let cell = try #require(GFMTableLayout.cells(row).first)
            let ns = cell as NSString
            guard case .wikiLink(let content, false) = InlineParser.parse(ns, in: NSRange(location: 0, length: ns.length)).first?.kind else {
                Issue.record("the editor does not read \(cell) as a wiki link")
                continue
            }
            #expect(String(WikiLinkSyntax.split(content).target) == named, "the editor: \(written) → \(content)")
        }
    }

    // MARK: - A row is read as cmark-gfm reads it

    /// The rows a probe found the two engines reading differently, through
    /// both: as many cells, and the same text in each. `| a \\| b |` was two
    /// cells in Edit and one on the page (implemented.md §51.36).
    @Test func aRowHasTheCellsThePageGivesIt() throws {
        for row in [#"| a \| b |"#, #"| a \\| b |"#, #"| a \\\| b |"#, #"| a \\\\| b |"#,
                    #"| a | b \| c |"#, #"| x \\| y | z |"#] {
            let header = Array(repeating: "h", count: GFMTableLayout.cells(row).count)
            let table = "| " + header.joined(separator: " | ") + " |\n"
                + "|" + header.map { _ in " --- |" }.joined() + "\n" + row + "\n"
            let html = GFMRenderer.html(table)
            let page = html.matches(of: /<td>(.*?)<\/td>/).map { String($0.1) }
            let editor = GFMTableLayout.cells(row).map(Self.shown)
            #expect(editor == page, "\(row): Edit \(editor), the page \(page)")
        }
    }

    /// A cell's text as the inline styler shows it: a backslash before ASCII
    /// punctuation escapes it, and is not drawn.
    private static func shown(_ cell: String) -> String {
        var out = ""
        var rest = Substring(cell)
        while let c = rest.first {
            rest = rest.dropFirst()
            if c == "\\", let next = rest.first, next.isASCII, next.isPunctuation || next.isSymbol {
                out.append(next)
                rest = rest.dropFirst()
            } else {
                out.append(c)
            }
        }
        return out
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
                == "[[foo](hellonotes-wiki:%5Bfoo)]\n\n[[foo](hellonotes-wiki:%5Bfoo)]: /url\n")
        #expect(NoteMarkdown.prepare("[[*foo* bar]]\n\n[*foo* bar]: /url \"title\"\n")
                == "[*foo* bar](hellonotes-wiki:*foo*%20bar)\n\n[*foo* bar]: /url \"title\"\n")
        // #598 — the one that was named as a divergence for the sweep's whole
        // life: the editor draws the embed, and now so does Preview.
        #expect(NoteMarkdown.prepare("![[foo]]\n\n[[foo]]: /url \"title\"\n")
                == "![](foo)\n\n[foo](hellonotes-wiki:foo): /url \"title\"\n")
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
