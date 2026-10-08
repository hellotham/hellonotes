//
//  WikiLinkSyntaxTests.swift
//  MarkdownCoreTests
//
//  What a `[[wiki link]]` names, as written — the one rule every reader of a
//  link reads it by (`WikiLinkSyntax`, implemented.md §51.36).
//

import Testing
import MarkdownCore

struct WikiLinkSyntaxTests {

    private func split(_ inner: String) -> [String?] {
        let (target, alias) = WikiLinkSyntax.split(inner)
        return [String(target), alias.map(String.init)]
    }

    @Test func aLinkWithoutAnAliasNamesWhatIsWritten() {
        #expect(split("Note") == ["Note", nil])
        #expect(split("Folder/Note#Heading") == ["Folder/Note#Heading", nil])
        // A backslash with no pipe after it is the name's.
        #expect(split(#"Note\"#) == [#"Note\"#, nil])
    }

    @Test func theAliasBeginsAtTheFirstPipe() {
        #expect(split("Note|alias") == ["Note", "alias"])
        #expect(split("Note#Heading|alias") == ["Note#Heading", "alias"])
        #expect(split("Note|either|or") == ["Note", "either|or"])
        #expect(split("|alias") == ["", "alias"])
    }

    /// `[[Note\|alias]]` — how an aliased link is written in a table's row —
    /// names `Note`, in a table or out of one.
    @Test func anEscapedAliasPipeIsNotPartOfTheTarget() {
        #expect(split(#"Note\|alias"#) == ["Note", "alias"])
        #expect(split(#"Note#Heading\|alias"#) == ["Note#Heading", "alias"])
    }

    /// Only an odd run of backslashes ends in the pipe's escape; an even run
    /// is escaped backslashes, and stays.
    @Test func onlyAnOddRunEndsInTheEscape() {
        #expect(split(#"Note\\|alias"#) == [#"Note\\"#, "alias"])
        #expect(split(#"Note\\\|alias"#) == [#"Note\\"#, "alias"])
        #expect(split(#"Note\\\\|alias"#) == [#"Note\\\\"#, "alias"])
    }

    /// For a reader whose pattern stops at the pipe: the escape comes off only
    /// when a pipe followed.
    @Test func aWrittenTargetLosesTheEscapeOnlyBeforeAnAlias() {
        #expect(WikiLinkSyntax.target(written: #"Note\"#, aliased: true) == "Note")
        #expect(WikiLinkSyntax.target(written: #"Note\"#, aliased: false) == #"Note\"#)
        #expect(WikiLinkSyntax.target(written: #"Note\\"#, aliased: true) == #"Note\\"#)
    }
}
