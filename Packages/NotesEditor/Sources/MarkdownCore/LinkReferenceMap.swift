//
//  LinkReferenceMap.swift
//  MarkdownCore
//
//  What `[foo]` stands for — the document's link reference definitions, keyed
//  by the label CommonMark says they answer to.
//
//  A reference link is the one inline construct whose meaning is not in the
//  span being parsed: `![foo]` is a picture only because `[foo]: /url` appears
//  somewhere else entirely, possibly further down the note. `InlineParser` is
//  handed one block's content at a time and can no more see that than it can
//  see the next paragraph, so until this existed it read `![foo]` as four
//  characters of prose — the editor reserved a line of text where the Preview
//  drew a 20pt image, on every reference-style illustration in the corpus.
//
//  Matching is by *normalised* label, and the rule is CommonMark's own:
//  Unicode case fold, trim the ends, collapse each internal run of whitespace
//  to one space. So `[FOOBAR]`, `[foobar]` and `[foo  bar]`-with-a-line-break
//  in it all name the same definition — and a later definition never displaces
//  an earlier one with the same label, which is why this builds first-wins.
//

import Foundation

public struct LinkReferenceMap: Sendable, Equatable {

    /// What a label resolves to.
    public struct Target: Sendable, Equatable {
        public var destination: String
        public var title: String

        public init(destination: String, title: String) {
            self.destination = destination
            self.title = title
        }
    }

    private var byLabel: [String: Target]

    /// A document with no definitions in it — the default every caller that
    /// has no document to hand gets, so `[foo]` stays prose unless something
    /// has actually said otherwise.
    public static let empty = LinkReferenceMap()

    public init() { byLabel = [:] }

    public init(_ definitions: [ReferenceDefinition.Found]) {
        byLabel = [:]
        byLabel.reserveCapacity(definitions.count)
        for found in definitions {
            let key = Self.normalized(found.definition.label)
            // First wins. CommonMark is explicit that a repeated label keeps
            // the *earlier* definition, and `byLabel[key] = …` in a loop keeps
            // the later one — the opposite, and silently.
            guard !key.isEmpty, byLabel[key] == nil else { continue }
            byLabel[key] = Target(destination: found.definition.destination,
                                  title: found.definition.title)
        }
    }

    /// Every definition in `text`, as found by `ReferenceDefinition`.
    public init(scanning text: NSString, document: ParseResult) {
        self.init(ReferenceDefinition.all(in: text, document: document))
    }

    public var isEmpty: Bool { byLabel.isEmpty }
    public var count: Int { byLabel.count }

    /// The target for a label written as it appears between the brackets.
    public subscript(label: String) -> Target? { byLabel[Self.normalized(label)] }

    /// CommonMark label normalisation: strip the ends, collapse internal
    /// whitespace runs to a single space, case fold.
    ///
    /// The fold has to be a *fold*, not `lowercased()`: the labels in the
    /// corpus include `[ẞ]` against `[ss]`, and simple lowercasing keeps those
    /// apart. Whitespace includes newlines, because a label may be written
    /// across lines and the break counts as one space.
    public static func normalized(_ label: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(label.unicodeScalars.count)
        var pendingSpace = false
        for scalar in label.unicodeScalars {
            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
                if !out.isEmpty { pendingSpace = true }
                continue
            }
            if pendingSpace { out.append(" "); pendingSpace = false }
            out.append(scalar)
        }
        return String(out).folding(options: [.caseInsensitive], locale: nil)
    }
}
