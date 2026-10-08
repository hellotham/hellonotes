//
//  WikiLinkSyntax.swift
//  MarkdownCore
//
//  What a `[[wiki link]]` names, as it is written — one rule for every reader.
//

import Foundation

/// What a `[[wiki link]]` names, as written: the text between its brackets,
/// split where its alias begins.
///
/// One rule, because each reader of a link had its own, and an escaped alias
/// pipe — `[[Note\|alias]]`, the way an aliased link is written in a table's
/// row, where a bare pipe would end the cell — was read two ways: Preview and
/// following the link dropped the backslash, and the link graph, a rename's
/// rewrite of the links to a note, the mind map, a composed note's links,
/// Preview's transclusions and Edit's colour kept it, and named `Note\`
/// (implemented.md §51.36).
///
/// **The alias begins at the first `|`, and a backslash escaping that pipe is
/// not part of the target** — in a table and out of one: a row moved out of a
/// table keeps its links. Only an *odd* run of backslashes ends in the escape;
/// an even run is escaped backslashes, and stays.
///
/// In a table the row is read first: a backslash directly before a pipe is
/// the row's escape, and the cell holds the pipe without it
/// (`GFMTableLayout.cells`). What reaches a link from a cell has been through
/// that already, so a reader working on a table's raw row reads the row's
/// escape off before this.
public enum WikiLinkSyntax {
    /// The scheme of a wiki link's destination wherever one is drawn as a
    /// link — Edit's `.link` attribute and Preview's `<a href>` — so a click
    /// on either is told from any other link and handed to the app's
    /// wiki-link navigation (implemented.md §51.36).
    public static let urlScheme = "hellonotes-wiki"

    /// `inner` — everything between `[[` and `]]` — as the target it names and
    /// the alias it shows, if it has one.
    public static func split(_ inner: Substring) -> (target: Substring, alias: Substring?) {
        guard let pipe = inner.firstIndex(of: "|") else { return (inner, nil) }
        return (target(written: inner[..<pipe], aliased: true), inner[inner.index(after: pipe)...])
    }

    public static func split(_ inner: String) -> (target: Substring, alias: Substring?) {
        split(inner[...])
    }

    /// The target of a link written as `written` up to where its alias would
    /// begin — `aliased` when a pipe followed — less the escape on that pipe.
    /// For a reader whose pattern stops at the pipe.
    public static func target(written: Substring, aliased: Bool) -> Substring {
        guard aliased, written.reversed().prefix(while: { $0 == "\\" }).count % 2 == 1 else { return written }
        return written.dropLast()
    }

    public static func target(written: String, aliased: Bool) -> String {
        String(target(written: written[...], aliased: aliased))
    }
}
