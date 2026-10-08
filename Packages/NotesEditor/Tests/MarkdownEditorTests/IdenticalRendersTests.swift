//
//  IdenticalRendersTests.swift
//  MarkdownEditorTests
//
//  Two blocks that need the same render both get it.
//
//  Every render the document starts off the main actor — syntax colours, inline
//  maths, inline pictures, block pictures — is cached by content, and each kept
//  the keys it had in flight in a set and turned a second request for one away:
//  `contains` meant "someone else is on it". When the render landed, only the
//  block that had started it was refreshed. The second block was already marked
//  styled, so nothing ever came back for it: a code block written twice kept its
//  second copy uncoloured, and a formula or a picture repeated in a later
//  paragraph stayed as source there. Block pictures were fixed first
//  (`TableEmbedTests.identicalTablesAreBothDrawn`); these are the other three.
//
//  Each test styles the whole note in one synchronous pass, which is what makes
//  the collision certain rather than likely: the first block's render cannot
//  start until the pass yields, so the second block always asks while it is in
//  flight. Which of the two asks first is the styling order's business — the
//  block beside the caret is styled ahead of the rest, so for code it was the
//  *second* copy that got its colours and the first that was turned away — so
//  each test asks for both, and first that at least one was drawn: a test that
//  only counted misses would pass for a renderer that never ran at all.
//
//  The second half is the same promise kept across an edit. A waiting block is
//  remembered by where it started, and a render takes long enough to type in:
//  two paragraphs typed above a block that is waiting moved it, and when the
//  render landed the old place held a different block — so the picture, the
//  colours or the formula went to nobody, and the block kept its source.
//

import Foundation
import Testing
@testable import MarkdownEditor

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@MainActor
@Suite struct IdenticalRendersTests {

    /// Colours the whole of any code it is given.
    private struct Highlighter: CodeHighlighting {
        func highlight(_ code: String, language: String) async -> [CodeColorRun] {
            [CodeColorRun(range: NSRange(location: 0, length: (code as NSString).length), color: .systemPink)]
        }
    }

    /// A picture for every inline formula and every image, and nothing for a
    /// block — so no block picture collapses anything these tests look at.
    private struct Renderer: BlockRenderer {
        func render(_ kind: BlockEmbedKind, maxWidth: CGFloat, darkMode: Bool) async -> PlatformImage? {
            guard case .image = kind else { return nil }
            return Self.blank(CGSize(width: 16, height: 16))
        }
        func renderInlineMath(_ latex: String, fontSize: CGFloat, darkMode: Bool) async -> PlatformImage? {
            Self.blank(CGSize(width: 30, height: 12))
        }
        /// `nonisolated`, because `BlockRenderer` is and the suite is not.
        nonisolated static func blank(_ size: CGSize) -> PlatformImage {
            #if canImport(AppKit)
            return NSImage(size: size)
            #else
            return UIGraphicsImageRenderer(size: size).image { _ in }
            #endif
        }
    }

    /// `text` styled whole, with the caret on its last line — outside every
    /// block under test, since a block the caret is in shows its source.
    private func styled(_ text: String, _ services: EditorServices) -> EditorDocument {
        let document = EditorDocument(text: text, services: services)
        document.selectionDidChange(NSRange(location: (text as NSString).length, length: 0))
        document.styleEverythingNow()
        return document
    }

    /// Which of `locations` pass `test`, once all of them do or about a second
    /// has gone by: the renders land after a hop.
    private func settled(_ locations: [Int], _ test: (Int) -> Bool) async throws -> [Int] {
        for _ in 0..<60 {
            if locations.allSatisfy(test) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        return locations.filter(test)
    }

    /// Where `needle` occurs in `text`, first and last.
    private func both(_ needle: String, in text: String) -> [Int] {
        let ns = text as NSString
        return [ns.range(of: needle).location, ns.range(of: needle, options: .backwards).location]
    }

    @Test func identicalCodeBlocksAreBothHighlighted() async throws {
        let fence = "```swift\nlet x = 1\n```"
        let text = "\(fence)\n\nBetween\n\n\(fence)\n\nAfter"
        let document = styled(text, EditorServices(codeHighlighter: Highlighter()))
        let at = both("let x", in: text)
        #expect(at[0] != at[1])
        let coloured = try await settled(at) {
            document.storage.attribute(.foregroundColor, at: $0, effectiveRange: nil) as? PlatformColor == .systemPink
        }
        #expect(!coloured.isEmpty, "neither code block was coloured — nothing was highlighted at all")
        #expect(coloured == at, "one of two identical code blocks was never coloured")
    }

    @Test func aFormulaRepeatedInALaterParagraphIsDrawnInBoth() async throws {
        let text = "One $x^2$ here.\n\nTwo $x^2$ there.\n\nAfter"
        let document = styled(text, EditorServices(blockRenderer: Renderer()))
        let at = both("$x^2$", in: text)
        #expect(at[0] != at[1])
        let drawn = try await settled(at) {
            document.storage.attribute(inlineImageAttribute, at: $0, effectiveRange: nil) != nil
        }
        #expect(!drawn.isEmpty, "neither formula was drawn — nothing was rendered at all")
        #expect(drawn == at, "the formula was drawn in one paragraph and left as source in the other")
    }

    @Test func aPictureRepeatedInALaterParagraphIsDrawnInBoth() async throws {
        let text = "One ![dot](dot.png) here.\n\nTwo ![dot](dot.png) there.\n\nAfter"
        let document = styled(text, EditorServices(blockRenderer: Renderer()))
        let at = both("![dot]", in: text)
        #expect(at[0] != at[1])
        let drawn = try await settled(at) {
            document.storage.attribute(inlineImageAttribute, at: $0, effectiveRange: nil) != nil
        }
        #expect(!drawn.isEmpty, "neither picture was drawn — nothing was rendered at all")
        #expect(drawn == at, "the picture was drawn in one paragraph and left as source in the other")
    }

    // MARK: - A block that moves while it waits

    /// A highlighter and a renderer that take their time, so an edit can land
    /// while a block waits on them.
    private struct SlowHighlighter: CodeHighlighting {
        func highlight(_ code: String, language: String) async -> [CodeColorRun] {
            try? await Task.sleep(for: .milliseconds(150))
            return [CodeColorRun(range: NSRange(location: 0, length: (code as NSString).length), color: .systemPink)]
        }
    }

    private struct SlowRenderer: BlockRenderer {
        func render(_ kind: BlockEmbedKind, maxWidth: CGFloat, darkMode: Bool) async -> PlatformImage? {
            try? await Task.sleep(for: .milliseconds(150))
            return Renderer.blank(CGSize(width: 40, height: 20))
        }
        func renderInlineMath(_ latex: String, fontSize: CGFloat, darkMode: Bool) async -> PlatformImage? {
            try? await Task.sleep(for: .milliseconds(150))
            return Renderer.blank(CGSize(width: 30, height: 12))
        }
    }

    /// `block` two paragraphs down a note, styled, and then two more paragraphs
    /// typed at the very top while its render is still out — which moves it by
    /// more than a block, so the place it asked from now holds another one.
    /// Two blocks above, not one: an edit restyles its neighbours, and a
    /// neighbour that is restyled simply asks again.
    private func movedWhileWaiting(_ block: String, _ services: EditorServices) -> EditorDocument {
        let document = styled("Intro\n\nMiddle\n\n\(block)\n\nAfter", services)
        document.storage.replaceCharacters(in: NSRange(location: 0, length: 0),
                                           with: "Typed while it drew.\n\nAnd again.\n\n")
        return document
    }

    /// Where `needle` is now.
    private func now(_ needle: String, in document: EditorDocument) -> Int {
        (document.storage.string as NSString).range(of: needle).location
    }

    @Test func aTableMovedWhileItRendersIsStillDrawn() async throws {
        let document = movedWhileWaiting("| a | b |\n| - | - |\n| 1 | 2 |",
                                         EditorServices(blockRenderer: SlowRenderer()))
        let at = now("| a |", in: document)
        let drawn = try await settled([at]) {
            document.storage.attribute(blockImageAttribute, at: $0, effectiveRange: nil) != nil
        }
        #expect(drawn == [at], "the table moved while it rendered, and its picture went to nobody")
    }

    @Test func aCodeBlockMovedWhileItIsHighlightedIsStillColoured() async throws {
        let document = movedWhileWaiting("```swift\nlet x = 1\n```",
                                         EditorServices(codeHighlighter: SlowHighlighter()))
        let at = now("let x", in: document)
        let coloured = try await settled([at]) {
            document.storage.attribute(.foregroundColor, at: $0, effectiveRange: nil) as? PlatformColor == .systemPink
        }
        #expect(coloured == [at], "the code block moved while it was highlighted, and its colours went to nobody")
    }

    @Test func aFormulaMovedWhileItRendersIsStillDrawn() async throws {
        let document = movedWhileWaiting("A formula $x^2$ here.", EditorServices(blockRenderer: SlowRenderer()))
        let at = now("$x^2$", in: document)
        let drawn = try await settled([at]) {
            document.storage.attribute(inlineImageAttribute, at: $0, effectiveRange: nil) != nil
        }
        #expect(drawn == [at], "the formula moved while it rendered, and its picture went to nobody")
    }

    @Test func aPictureMovedWhileItRendersIsStillDrawn() async throws {
        let document = movedWhileWaiting("A picture ![dot](dot.png) here.", EditorServices(blockRenderer: SlowRenderer()))
        let at = now("![dot]", in: document)
        let drawn = try await settled([at]) {
            document.storage.attribute(inlineImageAttribute, at: $0, effectiveRange: nil) != nil
        }
        #expect(drawn == [at], "the picture moved while it rendered, and went to nobody")
    }
}
