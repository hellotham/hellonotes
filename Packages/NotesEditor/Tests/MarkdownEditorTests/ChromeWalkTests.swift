//
//  ChromeWalkTests.swift
//  MarkdownEditorTests
//
//  How far the iPad's chrome walk goes.
//
//  UIKit does not call a fragment's `draw`, so the iPad's chrome is painted by
//  two views laid under and over the text, each the text's whole height. Each
//  draw walks the layout fragments to find what to paint — and the walk began
//  at the top of the note, stepping over every fragment above the dirty rect:
//  a third of a microsecond a fragment, once per view, on every keystroke and
//  every scroll frame. So a frame cost more the further down a long note you
//  were, which is the one thing the editor promises never happens. It starts at
//  the viewport now, and this holds it there — while checking that what is on
//  screen is still painted, since a walk that started too late would pass the
//  count by drawing nothing.
//
//  UIKit only: on the Mac each fragment draws its own chrome, and nothing walks.
//

import Foundation
import Testing
@testable import MarkdownEditor

#if !canImport(AppKit)
import UIKit

@MainActor
@Suite struct ChromeWalkTests {

    @Test func aDrawNearTheEndOfALongNoteWalksAScreenfulAndStillPaintsIt() throws {
        let paragraphs = (0..<2_000).map { "Paragraph \($0), one line of a long note." }
        let text = paragraphs.joined(separator: "\n\n")
            + "\n\n```swift\nlet wwwwwwwwwwww = 111111111111\n```\n\nEnd"
        let document = EditorDocument(text: text)
        document.styleEverythingNow()
        let size = CGSize(width: 600, height: 400)
        let textView = MarkdownUITextView.make(document: document)
        textView.frame = CGRect(origin: .zero, size: size)
        let window = UIWindow(frame: textView.frame)
        window.addSubview(textView)
        window.isHidden = false
        defer { textView.removeFromSuperview(); window.isHidden = true }
        textView.layoutIfNeeded()

        // The whole note laid out, so positions are real rather than estimated,
        // and then to the code block at its end — by the block's own frame: the
        // content size can still be trailing the layout at this point.
        let layoutManager = try #require(textView.textLayoutManager)
        let content = try #require(layoutManager.textContentManager)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let codeAt = (text as NSString).range(of: "let www").location
        func codeTop() throws -> CGFloat {
            let location = try #require(content.location(content.documentRange.location, offsetBy: codeAt))
            let fragment = try #require(layoutManager.textLayoutFragment(for: location))
            return textView.textContainerInset.top + fragment.layoutFragmentFrame.minY
        }
        textView.setContentOffset(CGPoint(x: 0, y: try codeTop() - 100), animated: false)
        textView.layoutIfNeeded()
        let visible = CGRect(origin: textView.contentOffset, size: textView.bounds.size)
        let top = try codeTop()
        #expect(visible.minY > 10_000 && top >= visible.minY && top < visible.maxY,
                "the code block at the end is not on screen — this test is not looking at the end of anything")

        // Each view drawn for the visible slice — the rect `refreshChrome`
        // invalidates — as the display pass would draw it.
        let under = draw(textView.chromeUnderlay, visible)
        _ = draw(textView.chromeOverlay, visible)
        let visited = [textView.chromeUnderlay.fragmentsVisited, textView.chromeOverlay.fragmentsVisited]
        #expect(visited.allSatisfy { $0 > 0 }, "a chrome view never walked — this test is not looking at a walk")
        #expect(visited.allSatisfy { $0 < 200 },
                "near the end of a 4,000-block note the walks went \(visited) fragments: they started at the top")

        // What is on screen is still painted: the code box at the end.
        var bandRows = 0
        for y in 0..<under.height {
            var band = 0
            for x in 0..<under.width {
                let p = (y * under.width + x) * 4
                let r = Int(under.bytes[p]), g = Int(under.bytes[p + 1]), b = Int(under.bytes[p + 2])
                if abs(r - 0xf6) <= 3, abs(g - 0xf8) <= 3, abs(b - 0xfa) <= 3 { band += 1 }
            }
            if band > under.width / 4 { bandRows += 1 }
        }
        #expect(bandRows > 0, "the code box at the end of the note was not painted")
    }

    /// `view` drawn for `rect` of its own coordinates, on white, as RGBA bytes at 2×.
    private func draw(_ view: UIView, _ rect: CGRect) -> (bytes: [UInt8], width: Int, height: Int) {
        let scale: CGFloat = 2
        let width = Int(rect.width * scale), height = Int(rect.height * scale)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            // UIKit's orientation — y down — with `rect`'s origin at the top left.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            context.translateBy(x: -rect.minX, y: -rect.minY)
            UIGraphicsPushContext(context)
            view.draw(rect)
            UIGraphicsPopContext()
        }
        return (bytes, width, height)
    }
}
#endif
