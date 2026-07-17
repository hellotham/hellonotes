//
//  SmartPasteTests.swift
//  HelloNotesTests
//
//  Created by Chris Tham on 12/7/2026.
//

#if os(macOS)
import Testing
import AppKit
@testable import HelloNotes

@MainActor
struct SmartPasteTests {

    private func pasteboard(html: String? = nil, string: String? = nil) -> NSPasteboard {
        let pb = NSPasteboard(name: .init("SmartPasteTest-\(UUID().uuidString)"))
        pb.clearContents()
        if let html { pb.setString(html, forType: .html) }
        if let string { pb.setString(string, forType: .string) }
        return pb
    }

    // MARK: - URL → link

    @Test
    func bareURLBecomesAMarkdownLink() {
        let result = SmartPaste.urlLink(from: pasteboard(string: "https://example.com/page"))
        #expect(result?.markdown == "[https://example.com/page](https://example.com/page)")
        #expect(result?.url.absoluteString == "https://example.com/page")
    }

    @Test
    func nonURLTextIsNotTreatedAsALink() {
        #expect(SmartPaste.urlLink(from: pasteboard(string: "just some text")) == nil)
        #expect(SmartPaste.urlLink(from: pasteboard(string: "see https://x.com now")) == nil) // not a bare URL
        #expect(SmartPaste.urlLink(from: pasteboard(string: "/local/path")) == nil)
    }

    // MARK: - Title extraction

    @Test
    func extractsAndCleansPageTitle() {
        let html = "<html><head><title>  Hello &amp; Welcome —\n Docs </title></head><body>x</body></html>"
        #expect(SmartPaste.title(fromHTML: html) == "Hello & Welcome — Docs")
        #expect(SmartPaste.title(fromHTML: "<html><body>no title</body></html>") == nil)
    }

    // MARK: - Rich text → Markdown

    @Test
    func plainHTMLWithoutFormattingFallsThrough() {
        // No formatting tags → nil so the verbatim plain-text paste is kept.
        #expect(SmartPaste.markdownFromHTML(pasteboard(html: "<p>just a paragraph</p>")) == nil)
    }

    @Test
    func convertsBoldItalicAndLinks() throws {
        let html = "<p>This is <b>bold</b> and <i>italic</i> and a <a href=\"https://x.com\">link</a>.</p>"
        let md = try #require(SmartPaste.markdownFromHTML(pasteboard(html: html)))
        #expect(md.contains("**bold**"))
        #expect(md.contains("*italic*"))
        #expect(md.contains("[link](https://x.com"))   // NSURL may add a trailing slash
    }

    @Test
    func convertsListsAndHeadings() throws {
        let html = "<h1>Title</h1><ul><li>one</li><li>two</li></ul>"
        let md = try #require(SmartPaste.markdownFromHTML(pasteboard(html: html)))
        #expect(md.contains("# Title"))
        #expect(md.contains("- one"))
        #expect(md.contains("- two"))
    }
}

#endif
