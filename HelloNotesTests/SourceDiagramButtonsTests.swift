//
//  SourceDiagramButtonsTests.swift
//  HelloNotesTests
//
//  The View diagram button on every diagram in the Markdown source — Markdown
//  and Split mode's way of saying which diagram it means, where Edit and
//  Preview have a button on each picture. The zoom used to open on the first
//  diagram from there.
//

import Testing
import Foundation
import CoreGraphics
import MarkdownCore
import MarkdownEditor
@testable import HelloNotes
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@Suite @MainActor
struct SourceDiagramButtonsTests {

    static let flow = "graph TD\n  A --> B"
    private static func fence(_ source: String) -> String { "```mermaid\n\(source)\n```" }

    /// Two identical diagrams and a code block that is not one: two buttons,
    /// each on its own fence's opening line at the right — and a press on the
    /// second opens the second, which only a place can tell from the first.
    @Test func everyDiagramGetsItsOwnButtonOnItsFence() async throws {
        let text = "Intro\n\n\(Self.fence(Self.flow))\n\nMiddle\n\n\(Self.fence(Self.flow))"
            + "\n\n```swift\nlet x = 1\n```\n\nEnd"
        let (textView, host) = try sourceView(text)
        defer { withExtendedLifetime(host) {} }
        let buttons = SourceDiagramButtons(textView: textView)
        textView.diagramButtons = buttons
        var opened: [DiagramZoom] = []
        buttons.onPress = { opened.append($0) }

        buttons.textDidChange()
        for _ in 0..<200 where buttons.diagrams.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        layOut(textView)
        buttons.place()

        let shown = buttons.buttons.filter { !$0.isHidden }.sorted { $0.frame.minY < $1.frame.minY }
        #expect(shown.count == 2, "two diagrams and a swift fence that is not one, and \(shown.count) buttons")
        let ns = text as NSString
        let fences = [ns.range(of: "```mermaid").location, ns.range(of: "```mermaid", options: .backwards).location]
        let layoutManager = try #require(textView.textLayoutManager)
        let content = try #require(layoutManager.textContentManager)
        for (button, at) in zip(shown, fences) {
            let location = try #require(content.location(content.documentRange.location, offsetBy: at))
            let fragment = try #require(layoutManager.textLayoutFragment(for: location))
            let line = containerTop(textView) + fragment.layoutFragmentFrame.midY
            #expect(abs(button.frame.midY - line) < 2, "a button sits at \(button.frame.midY), its fence at \(line)")
            #expect(button.frame.maxX > textView.bounds.width - 40, "a button is not at the right edge")
        }
        guard shown.count == 2 else { return }
        #expect(press(shown[1]))
        #expect(opened == [DiagramZoom(source: Self.flow, location: fences[1])])
        #expect(DiagramZoomRequest.make(text: text, zoom: opened.first, caret: nil)?.start == 1,
                "the second diagram's button opened another")
    }

    #if canImport(AppKit)
    private func sourceView(_ text: String) throws -> (SourceTextView, NSWindow) {
        let scroll = SourceEditor.scrollableSourceView(fontSize: 13)
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(scroll)
        let textView = try #require(scroll.documentView as? SourceTextView)
        textView.string = text
        return (textView, window)
    }
    private func layOut(_ textView: SourceTextView) { textView.window?.contentView?.layoutSubtreeIfNeeded() }
    private func containerTop(_ textView: SourceTextView) -> CGFloat { textView.textContainerOrigin.y }
    private func press(_ button: DiagramButtonView) -> Bool { button.accessibilityPerformPress() }
    #else
    private func sourceView(_ text: String) throws -> (SourceTextView, UIWindow) {
        let textView = SourceEditor.sourceTextView(fontSize: 13)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        textView.frame = window.bounds
        window.addSubview(textView)
        window.isHidden = false
        textView.text = text
        return (textView, window)
    }
    private func layOut(_ textView: SourceTextView) { textView.layoutIfNeeded() }
    private func containerTop(_ textView: SourceTextView) -> CGFloat { textView.textContainerInset.top }
    private func press(_ button: DiagramButtonView) -> Bool { button.accessibilityActivate() }
    #endif
}
