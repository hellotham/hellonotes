//
//  ChromeUnderTextTests.swift
//  MarkdownEditorTests
//
//  A code block's box is painted *behind* its code, on both platforms.
//
//  On the Mac a fragment draws its own chrome, band first and text over it.
//  UIKit does not call a fragment's `draw`, so on iPad the chrome is painted by
//  a view laid over the text — and the code band, an opaque fill, was painted
//  there too: over the code. Every code block in Edit on iPad was an empty
//  grey box. Backgrounds go on a view *under* the text now; this renders a live
//  editor and looks for the code's ink inside its box.
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
@Suite struct ChromeUnderTextTests {

    static let note = "Intro\n\n```swift\nlet wwwwwwwwwwww = 111111111111\n```\n\nAfter"

    @Test func aCodeBlocksTextIsDrawnOverItsBand() async throws {
        let document = EditorDocument(text: Self.note)
        document.styleEverythingNow()
        let size = CGSize(width: 600, height: 300)

        #if canImport(AppKit)
        let (scrollView, textView) = MarkdownTextView.scrollableEditor(document: document)
        scrollView.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // The light theme, whatever the Mac is set to: the band this looks for
        // is the light code band, and a Mac that turns dark at sunset otherwise
        // fails this every evening for a reason that is not the test's.
        window.appearance = NSAppearance(named: .aqua)
        window.contentView?.addSubview(scrollView)
        defer { window.contentView = nil }
        let origin = textView.textContainerOrigin
        #else
        let textView = MarkdownUITextView.make(document: document)
        textView.frame = CGRect(origin: .zero, size: size)
        let window = UIWindow(frame: textView.frame)
        window.overrideUserInterfaceStyle = .light   // the light band, as on the Mac
        window.addSubview(textView)
        window.isHidden = false
        defer { textView.removeFromSuperview(); window.isHidden = true }
        textView.layoutIfNeeded()
        textView.refreshChrome()
        let origin = CGPoint(x: textView.textContainerInset.left, y: textView.textContainerInset.top)
        #endif

        // The code line's box, in the view.
        let layoutManager = try #require(textView.textLayoutManager)
        let content = try #require(layoutManager.textContentManager)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let codeAt = (Self.note as NSString).range(of: "let www").location
        let location = try #require(content.location(content.documentRange.location, offsetBy: codeAt))
        let fragment = try #require(layoutManager.textLayoutFragment(for: location))
        let line = try #require(fragment.textLineFragments.first)
        let box = CGRect(x: origin.x + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX,
                         y: origin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY,
                         width: 300, height: line.typographicBounds.height)

        let (pixels, width, scale) = try render(textView, size: size)
        var ink = 0, band = 0
        for y in Int(box.minY * scale)..<Int(box.maxY * scale) {
            for x in Int(box.minX * scale)..<Int(box.maxX * scale) {
                let p = (y * width + x) * 4
                let r = Int(pixels[p]), g = Int(pixels[p + 1]), b = Int(pixels[p + 2])
                if r + g + b < 3 * 110 { ink += 1 }
                if abs(r - 0xf6) <= 3, abs(g - 0xf8) <= 3, abs(b - 0xfa) <= 3 { band += 1 }
            }
        }
        #expect(band > 0, "no band behind the code — this test is not looking at a code box")
        #expect(ink > 50, "the code line has no ink: its band was painted over it (ink \(ink), band \(band))")
    }

    /// The view drawn into a bitmap, white under it, as RGBA bytes.
    private func render(_ view: AnyObject, size: CGSize) throws -> ([UInt8], Int, CGFloat) {
        let scale: CGFloat = 2
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let context = try #require(CGContext(data: nil, width: width, height: height,
                                             bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        #if canImport(AppKit)
        let textView = try #require(view as? NSView)
        let rep = try #require(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
        textView.cacheDisplay(in: textView.bounds, to: rep)
        let image = try #require(rep.cgImage)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        #else
        let textView = try #require(view as? UIView)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        textView.layer.render(in: context)
        #endif
        let data = try #require(context.data)
        return (Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                          count: width * height * 4)), width, scale)
    }
}
