//
//  SmartPasteIOSTests.swift
//  HelloNotesTests
//
//  The UIKit half of smart paste, which had no tests at all.
//
//  `SmartPasteTests` builds its fixtures from an `NSPasteboard`, so it is
//  genuinely macOS-only and stayed that way. But most of what it *asserts* —
//  URL detection, title extraction, HTML → Markdown — runs through
//  `fromAttributed`, whose bold / italic / monospaced predicates each branch on
//  `canImport(AppKit)`. Those three UIKit branches ask `UIFontDescriptor` for
//  symbolic traits where AppKit asks `NSFontDescriptor`, and nothing had ever
//  run them. Pasting rich text into a note on iPad was writing a `.md` file
//  through code no test had executed.
//
//  So this is not the macOS suite ported: it is the part that differs.
//

#if os(iOS)
import UIKit
import Testing
@testable import HelloNotes

@MainActor
struct SmartPasteIOSTests {

    /// A private pasteboard, so a test never reads or clobbers the device's.
    private func pasteboard() throws -> UIPasteboard {
        try #require(UIPasteboard(name: .init("SmartPasteTest-\(UUID().uuidString)"), create: true))
    }

    // MARK: - The pasteboard accessors

    @Test func readsPlainTextFromTheiOSPasteboard() throws {
        let pb = try pasteboard()
        pb.string = "https://example.com/page"
        #expect(SmartPaste.pasteboardString(pb) == "https://example.com/page")

        let link = SmartPaste.urlLink(fromString: SmartPaste.pasteboardString(pb))
        #expect(link?.markdown == "[https://example.com/page](https://example.com/page)")
    }

    @Test func readsHTMLFromTheiOSPasteboard() throws {
        let pb = try pasteboard()
        let html = "<p>a <b>bold</b> word</p>"
        pb.setValue(html, forPasteboardType: "public.html")
        let read = try #require(SmartPaste.pasteboardHTML(pb))
        #expect(read.contains("<b>bold</b>"))
    }

    @Test func plainTextThatIsNotAURLIsNotALink() throws {
        let pb = try pasteboard()
        pb.string = "just some text"
        #expect(SmartPaste.urlLink(fromString: SmartPaste.pasteboardString(pb)) == nil)
    }

    // MARK: - The UIKit font predicates, through HTML → Markdown

    /// Bold and italic have to survive `UIFontDescriptor.symbolicTraits`, which
    /// is a different type and a different spelling from the AppKit path the
    /// macOS suite covers.
    @Test func boldAndItalicSurviveTheUIKitFontPath() throws {
        let html = "<p>This is <b>bold</b> and <i>italic</i> and a <a href=\"https://x.com\">link</a>.</p>"
        let md = try #require(SmartPaste.markdownFromHTML(html: html))
        #expect(md.contains("**bold**"))
        #expect(md.contains("*italic*"))
        #expect(md.contains("[link](https://x.com"))   // NSURL may add a trailing slash
    }

    @Test func headingsAndListsSurviveTheUIKitFontPath() throws {
        let html = "<h1>Title</h1><ul><li>one</li><li>two</li></ul>"
        let md = try #require(SmartPaste.markdownFromHTML(html: html))
        #expect(md.contains("# Title"))
        #expect(md.contains("- one"))
        #expect(md.contains("- two"))
    }

    @Test func monospacedRunsBecomeInlineCode() throws {
        let html = "<p>call <code>reindex()</code> first</p>"
        let md = try #require(SmartPaste.markdownFromHTML(html: html))
        #expect(md.contains("`reindex()`"))
    }

    /// Unformatted HTML is refused on iOS exactly as on macOS — pasting a bare
    /// paragraph should insert the text, not an HTML round trip of it.
    @Test func unformattedHTMLIsRefused() {
        #expect(SmartPaste.markdownFromHTML(html: "<p>just a paragraph</p>") == nil)
    }
}
#endif
