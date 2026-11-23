//
//  PictureSizeTests.swift
//  GFMRenderTests
//
//  Obsidian's size on a Markdown image — `![A cat|300](cat.png)` — on the
//  page Preview shows. cmark, as GitHub, writes it as the description; the
//  page gives the `<img>` the size, as Edit draws it.
//

import Testing
@testable import GFMRender

@Suite struct PictureSizeTests {

    @Test func thePageSizesAPictureItsDescriptionSizes() {
        let page = GFMRenderer.page("![A cat|300](cat.png)")
        #expect(page.contains("<p><img src=\"cat.png\" alt=\"A cat\" width=\"300\" /></p>"), "\(page)")
        let boxed = GFMRenderer.page("![|300x200](cat.png \"Asleep\")")
        #expect(boxed.contains("<img src=\"cat.png\" alt=\"\" width=\"300\" height=\"200\" title=\"Asleep\" />"),
                "\(boxed)")
        // Behind a reference, inside a line, in a table's cell with its pipe
        // escaped, and from the web.
        let referenced = GFMRenderer.page("![A cat|90][c]\n\n[c]: cat.png\n")
        #expect(referenced.contains("alt=\"A cat\" width=\"90\""), "\(referenced)")
        let inLine = GFMRenderer.page("Look: ![A cat|40](cat.png) there.")
        #expect(inLine.contains("<p>Look: <img src=\"cat.png\" alt=\"A cat\" width=\"40\" /> there.</p>"), "\(inLine)")
        let inTable = GFMRenderer.page("| Picture |\n| --- |\n| ![A cat\\|60](cat.png) |\n")
        #expect(inTable.contains("<td><img src=\"cat.png\" alt=\"A cat\" width=\"60\" /></td>"), "\(inTable)")
        let remote = GFMRenderer.page("![|100x145](https://example.com/e.jpg)")
        #expect(remote.contains("alt=\"\" width=\"100\" height=\"145\""), "\(remote)")
    }

    /// Words are words: a description without a size, or with one that is
    /// not a size, is left as cmark wrote it.
    @Test func aDescriptionWithoutASizeIsLeftAlone() {
        for (note, alt) in [("![A cat](cat.png)", "A cat"), ("![300](cat.png)", "300"),
                            ("![A cat|asleep](cat.png)", "A cat|asleep"), ("![A cat|0](cat.png)", "A cat|0"),
                            ("![A cat|300x](cat.png)", "A cat|300x")] {
            let page = GFMRenderer.page(note)
            #expect(page.contains("<img src=\"cat.png\" alt=\"\(alt)\" />"), "\(note): \(page)")
            #expect(!page.contains("width=\""), "\(note)")
        }
    }

    /// GitHub's rendering is GitHub's: the page reads the note's dialect,
    /// `GFMRenderer.html` — what the specification sweep grades — does not.
    @Test func gitHubsRenderingIsUntouched() {
        #expect(GFMRenderer.html("![A cat|300](cat.png)") == "<p><img src=\"cat.png\" alt=\"A cat|300\" /></p>\n")
    }
}
