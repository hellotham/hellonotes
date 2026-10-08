//
//  MermaidDiagramsTests.swift
//  MarkdownCoreTests
//
//  One rule for which fences are diagrams, asked by the editor (to draw them),
//  by the app (to list them) and by Preview (to draw them there). The app used
//  to keep a regular expression of its own that knew one spelling, so a diagram
//  drawn in the note could be missing from every list the app made of the
//  note's diagrams; Preview kept another copy, which wanted the one word.
//

import Foundation
import Testing
@testable import MarkdownCore

@Suite struct MermaidDiagramsTests {

    private func diagrams(_ text: String) -> [MermaidDiagram] {
        let ns = text as NSString
        return BlockParser.fullParse(ns).mermaidDiagrams(in: ns)
    }

    /// Every spelling the editor draws as a picture is a diagram — including
    /// the four the app's old `` ```mermaid[ \t]*\n `` expression could not see.
    @Test(arguments: [("```mermaid", "```"), ("~~~mermaid", "~~~"), ("```Mermaid", "```"),
                      ("```mermaid theme=dark", "```"), ("```mermaid\ttheme=dark", "```"),
                      ("````mermaid", "````")])
    func everySpellingTheEditorDrawsIsADiagram(open: String, close: String) {
        let text = "Before\n\n\(open)\ngraph TD\n  A --> B\n\(close)\n\nAfter"
        #expect(diagrams(text).map(\.source) == ["graph TD\n  A --> B"])
    }

    /// The rule itself, as Preview asks it of the raw text after the fence:
    /// the first word, in any case, ended by any whitespace — a tab as well as
    /// a space, which is where cmark-gfm ends the language it writes out.
    @Test func theRuleIsTheInfoStringsFirstWord() {
        for info in ["mermaid", "Mermaid", "MERMAID", "mermaid theme=dark", "mermaid\ttheme", " mermaid "] {
            #expect(MermaidDiagram.isDiagram(info: info), "\(info) opens a diagram")
        }
        for info in ["", "text", "mermaidish", "mermaid-js", "js mermaid"] {
            #expect(!MermaidDiagram.isDiagram(info: info), "\(info) does not")
        }
    }

    /// And what is not one: code that only looks like a diagram, a fence still
    /// being typed, a fence with nothing in it, and a longer word.
    @Test func codeAndUnfinishedFencesAreNotDiagrams() {
        #expect(diagrams("```text\ngraph TD\n```").isEmpty, "the info string decides")
        #expect(diagrams("```mermaid\ngraph TD\n  A --> B").isEmpty, "an unclosed fence is still being typed")
        #expect(diagrams("```mermaid\n```").isEmpty, "an empty fence draws nothing")
        #expect(diagrams("```mermaidish\ngraph TD\n```").isEmpty, "the first word, not a prefix of it")
    }

    /// In document order, each with its fence — a caret inside the fence is
    /// inside the diagram's range, which is how the zoom finds "this one".
    @Test func diagramsComeInOrderWithTheirFences() {
        let text = "```mermaid\ngraph TD\n```\n\nText\n\n```mermaid\npie\n```\n"
        let ns = text as NSString
        let found = diagrams(text)
        #expect(found.map(\.source) == ["graph TD", "pie"])
        #expect(ns.substring(with: found[1].range).hasPrefix("```mermaid\npie\n```"))
        #expect(NSLocationInRange(ns.range(of: "pie").location, found[1].range))
        #expect(!NSLocationInRange(ns.range(of: "Text").location, found[0].range))
    }

    /// Two identical diagrams are two diagrams, at two places.
    @Test func identicalDiagramsAreListedTwice() {
        let fence = "```mermaid\ngraph TD\n```"
        let found = diagrams("\(fence)\n\(fence)")
        #expect(found.map(\.source) == ["graph TD", "graph TD"])
        #expect(found.count == 2 && found[0].range.location != found[1].range.location)
    }
}
