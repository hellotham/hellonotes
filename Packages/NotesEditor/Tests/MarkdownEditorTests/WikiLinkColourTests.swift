//
//  WikiLinkColourTests.swift
//  MarkdownEditorTests
//
//  The name Edit asks about when it colours a wiki link found or broken
//  (`StyleApplier.baseTitle`) — read by the rule every reader of a link
//  shares (`WikiLinkSyntax`, implemented.md §51.36).
//

import Testing
@testable import MarkdownEditor

struct WikiLinkColourTests {

    @Test func aLinkIsColouredByTheNoteItNames() {
        #expect(StyleApplier.baseTitle(of: "Note") == "Note")
        #expect(StyleApplier.baseTitle(of: "Note|alias") == "Note")
        #expect(StyleApplier.baseTitle(of: "Note#Heading|alias") == "Note")
        #expect(StyleApplier.baseTitle(of: " Note #Heading") == "Note")
    }

    /// `[[Note\|alias]]` — how a table writes an aliased link, and the same
    /// link anywhere else — is coloured as `Note`. Outside a table it was
    /// asked about as `Note\` and drawn as a broken link, while following it
    /// reached `Note`.
    @Test func anEscapedAliasPipeIsNotPartOfTheName() {
        #expect(StyleApplier.baseTitle(of: #"Note\|alias"#) == "Note")
        #expect(StyleApplier.baseTitle(of: #"Note#Heading\|alias"#) == "Note")
        // An even run is escaped backslashes, and the name's.
        #expect(StyleApplier.baseTitle(of: #"Note\\|alias"#) == #"Note\\"#)
    }
}
