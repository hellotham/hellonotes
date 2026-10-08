//
//  LiveFragmentTests.swift
//  MarkdownEditorTests
//
//  A live editor lays its note out in the editor's own fragments — the ones
//  that draw bullets, rules, bands, tables and diagrams — from the very first
//  layout, however the note got to it.
//
//  UIKit lays a text view's text out inside `init`, and TextKit keeps a
//  fragment per paragraph until that paragraph changes. `MarkdownUITextView`
//  installed its fragment delegate afterwards, in `bind`, so a note already
//  styled when its view was made — every note the document store hands back,
//  on each rotation and each return to Edit — kept plain fragments wherever
//  nothing restyled it. `ChromeOverlayView` draws only the editor's fragments,
//  so there it drew nothing: no bullets, no rules, no bands, and a blank band
//  where each table and diagram should have been. Found by the diagram zoom's
//  test, which could not find the button a plain fragment never draws.
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
@Suite struct LiveFragmentTests {

    static let note = """
    # Heading

    - one
    - two

    > quoted

    ```swift
    let x = 1
    ```

    After
    """

    @Test func aNoteStyledBeforeItsViewIsLaidOutInTheEditorsFragments() throws {
        let document = EditorDocument(text: Self.note)
        // Styled before any view exists, as every note the store keeps is.
        document.styleEverythingNow()

        #if canImport(AppKit)
        let (scrollView, textView) = MarkdownTextView.scrollableEditor(document: document)
        scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(scrollView)
        defer { window.contentView = nil }
        #else
        let textView = MarkdownUITextView.make(document: document)
        textView.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        let window = UIWindow(frame: textView.frame)
        window.addSubview(textView)
        window.isHidden = false
        defer { textView.removeFromSuperview(); window.isHidden = true }
        textView.layoutIfNeeded()
        #endif

        let layoutManager = try #require(textView.textLayoutManager)
        let content = try #require(layoutManager.textContentManager)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        var count = 0
        var plain: [String] = []
        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location,
                                                   options: [.ensuresLayout]) { fragment in
            count += 1
            if !(fragment is RenderedBlockFragment) {
                let start = content.offset(from: content.documentRange.location,
                                           to: fragment.rangeInElement.location)
                let text = document.text as NSString
                plain.append(text.substring(with: NSRange(location: start,
                                                          length: min(10, text.length - start))))
            }
            return true
        }
        #expect(count >= 8, "the note was not laid out: \(count) fragments")
        #expect(plain.isEmpty, "laid out in plain fragments, which draw no chrome: \(plain)")
    }
}
