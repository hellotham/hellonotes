//
//  PreviewLinkTests.swift
//  MarkdownEditorTests
//
//  What a link clicked in Preview asks for (`GFMPreview.linkTap`,
//  implemented.md §51.36). Preview's web view had no navigation delegate, so
//  a click was WebKit's: a wiki link went nowhere the app could see, and a web
//  link replaced the preview with the page it named.
//

import Foundation
import Testing
import GFMRender
@testable import MarkdownEditor

struct PreviewLinkTests {

    private let page = URL(fileURLWithPath: "/vault/Folder/", isDirectory: true)

    /// A wiki link's destination is a `hellonotes-wiki:` address — on the
    /// page as in Edit — and asks for the note it names, as Edit's tap does.
    @Test func aWikiLinkAsksForItsNote() throws {
        let url = try #require(URL(string: "hellonotes-wiki:Examples/Nested%20Note"))
        guard case .wiki(let target)? = GFMPreview.linkTap(for: url, page: page) else {
            Issue.record("a wiki link was not handed over as one"); return
        }
        #expect(target == "Examples/Nested Note")

        let heading = try #require(URL(string: "hellonotes-wiki:Note%23Part"))
        guard case .wiki(let named)? = GFMPreview.linkTap(for: heading, page: page) else {
            Issue.record("a link to a heading was not handed over"); return
        }
        #expect(named == "Note#Part")
    }

    /// The link Preview draws for a table's aliased link — through the rewrite
    /// and cmark-gfm, as the page has it — asks for the note.
    @Test func aTablesAliasedLinkOnThePageAsksForTheNote() throws {
        let html = GFMRenderer.html(NoteMarkdown.prepare("| Link |\n| --- |\n| [[Examples/Nested Note\\|an alias]] |\n"))
        let href = try #require(html.firstMatch(of: /href="([^"]*)"/)).1
        let url = try #require(URL(string: String(href)))
        guard case .wiki(let target)? = GFMPreview.linkTap(for: url, page: page) else {
            Issue.record("the table's link was not handed over as a wiki link: \(href)"); return
        }
        #expect(target == "Examples/Nested Note")
    }

    /// Any other link goes to whoever opens it — the browser for the web.
    @Test func anyOtherLinkIsHandedOver() throws {
        for written in ["https://example.com/a?b=c", "mailto:someone@example.com", "file:///vault/Folder/report.pdf"] {
            let url = try #require(URL(string: written))
            guard case .url(let handed)? = GFMPreview.linkTap(for: url, page: page) else {
                Issue.record("\(written) was not handed over"); continue
            }
            #expect(handed == url)
        }
    }

    /// A place in the page itself — a footnote and the way back from it — is
    /// the page's to scroll to.
    @Test func aPlaceInThePageIsThePagesOwn() throws {
        let footnote = try #require(URL(string: "#fn-1", relativeTo: page)?.absoluteURL)
        #expect(GFMPreview.linkTap(for: footnote, page: page) == nil)
        let blank = try #require(URL(string: "about:blank#fnref-1"))
        #expect(GFMPreview.linkTap(for: blank, page: URL(string: "about:blank")) == nil)
        // A fragment of another document is that document's.
        let other = try #require(URL(string: "https://example.com/#top"))
        #expect(GFMPreview.linkTap(for: other, page: page) != nil)
    }
}
