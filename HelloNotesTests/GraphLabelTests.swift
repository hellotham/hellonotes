//
//  GraphLabelTests.swift
//  HelloNotesTests
//
//  The Graph names its nodes where they are.
//
//  The window root makes every line its size plus three (`chromeDefaults`), and
//  that reaches text drawn into a `Canvas` too — where `draw(_:at:)` then
//  ignores the point it is given. Every node's label came out in one pile at
//  the canvas's top-left corner, on both platforms, and no orb had a name. A
//  render without the root's defaults drew them correctly, which is why a
//  probe that left them out saw nothing wrong.
//

import Foundation
import SwiftUI
import Testing
@testable import HelloNotes
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@Suite(.serialized) @MainActor
struct GraphLabelTests {

    private static let size = CGSize(width: 360, height: 520)

    /// A note and four neighbours, under the window root's defaults — what the
    /// app draws the graph under.
    private func graph() -> some View {
        let urls = (0..<5).map { URL(fileURLWithPath: "/tmp/graph-labels/N\($0).md") }
        let nodes = ["Linking", "Start Here", "Organising", "Index", "Rich Content"].enumerated()
            .map { GraphNode(url: urls[$0.offset], label: $0.element) }
        let edges = [GraphEdge(from: 0, to: 1), GraphEdge(from: 1, to: 0), GraphEdge(from: 0, to: 2),
                     GraphEdge(from: 0, to: 3), GraphEdge(from: 4, to: 0)]
        return GraphView(nodes: nodes, edges: edges, onSelect: { _ in }, accent: .purple,
                         focusedURL: urls[0], onFocusChange: { _ in })
            .environment(AppearanceSettings())
            .environment(\.colorScheme, .light)
            .frame(width: Self.size.width, height: Self.size.height)
            .chromeDefaults()
    }

    /// The graph as a window draws it, once its layout has run. Light, so the
    /// labels are dark whatever the Mac's appearance is at the time.
    ///
    /// **Once its layout has run — seen, not timed.** The layout is worked
    /// out off the main actor and nothing is drawn until it lands, so this
    /// looks until there are labels, and then once more, so the picture is
    /// of the graph at rest.
    private func render() async throws -> CGImage {
        #if canImport(AppKit)
        // **Ordered in, far off any screen**: a window as a window is, whose
        // view has appeared — the layout starts in the graph's `.task`.
        // Borderless, because a titled window is moved back onto a screen
        // when it is ordered in — the person's. (It was once thought CI's
        // runner drew no graph without this. It drew one; what it could not
        // do was pass `labelInk` at one pixel a point — see there.)
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: Self.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: graph())
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        func picture() throws -> CGImage {
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return try #require(rep.cgImage)
        }
        #else
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(origin: .zero, size: Self.size)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = UIHostingController(rootView: graph())
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        func picture() throws -> CGImage {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            return try #require(image.cgImage)
        }
        #endif
        var latest = try picture()
        for _ in 0..<Waits.looks(in: .seconds(30), every: .milliseconds(250)) where labelInk(in: latest) == nil {
            try await Task.sleep(for: .milliseconds(250))
            latest = try picture()
        }
        // At rest: whatever moved the labels into place has finished moving them.
        try await Task.sleep(for: .milliseconds(500))
        return try picture()
    }

    /// The box around the label ink between the graph's header and its
    /// legend, in pixels: the pixels that are **grey and about as dark as
    /// the darkest grey in the picture**. The labels are the one thing drawn
    /// in the text colour; the orbs, the arrows and the ring are coloured,
    /// and an orb's shadow is a grey far lighter.
    ///
    /// **Not "near-black", which is a fact about the display.** That was the
    /// test — a pixel whose channels sum to under 150 — and on a display of
    /// two pixels a point it holds: the darkest grey of this picture is 82.
    /// At one pixel a point a label's strokes fill no pixel: this Mac's
    /// picture at half size has nothing darker than 261, and no near-black
    /// pixel at all. CI's runner, by its count, has such a display. It drew the graph —
    /// 2,621 pixels of it, where the half-size picture here has 2,735 — and
    /// for two runs the failure read "the graph drew no labels at all", and
    /// was put down first to a slow layout and then to a window never shown
    /// (implemented.md §51.49).
    private func labelInk(in image: CGImage) -> CGRect? { Self.reading(of: image).ink }

    /// A picture's darkest grey between the header and the legend, as the
    /// sum of its channels — 765 is the page — and the box round the greys
    /// about that dark; no box when the darkest is no darker than a mid grey,
    /// which is no text. (A shadow is black at three parts in ten before it
    /// is blurred: 535 at the very most, and past the limit either way.)
    private static func reading(of image: CGImage) -> (darkest: Int, ink: CGRect?) {
        let width = image.width, height = image.height
        guard let pixels = pixels(of: image) else { return (765, nil) }
        let rows = Int(Double(height) * 0.15)..<Int(Double(height) * 0.88)
        // Plain counters, on purpose. Written as `for x in 0..<width`, the
        // first picture of a run took twelve seconds of the main actor in a
        // debug build (a later one a tenth of a second): sampled, the time
        // was in the range's iterator and the generic-metadata lookups under
        // it, while the host was still starting. Every test in the suite
        // shares that actor (implemented.md §51.49).
        return pixels.withUnsafeBufferPointer { pixels -> (Int, CGRect?) in
            /// The sum of a grey pixel's channels; the page's for a coloured
            /// one or a clear one.
            func grey(_ i: Int) -> Int {
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                var low = r, high = r
                if g < low { low = g }; if b < low { low = b }
                if g > high { high = g }; if b > high { high = b }
                return pixels[i + 3] > 200 && high - low <= 24 ? r + g + b : 765
            }
            let first = rows.lowerBound * width * 4, end = rows.upperBound * width * 4
            var darkest = 765
            var i = first
            while i < end {
                let sum = grey(i)
                if sum < darkest { darkest = sum }
                i += 4
            }
            guard darkest < 450 else { return (darkest, nil) }
            var minX = width, minY = height, maxX = -1, maxY = -1
            var x = 0, y = rows.lowerBound
            i = first
            while i < end {
                if grey(i) <= darkest + 80 {
                    if x < minX { minX = x }; if x > maxX { maxX = x }
                    if y < minY { minY = y }; if y > maxY { maxY = y }
                }
                i += 4; x += 1
                if x == width { x = 0; y += 1 }
            }
            return (darkest, CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
        }
    }

    /// The picture's pixels, RGBA, over white.
    private static func pixels(of image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// The picture at half its size — what a display of one pixel a point
    /// has of a graph drawn at two. Not that display's own drawing, which
    /// only it can make; near enough that a way of reading the picture which
    /// fails there fails here.
    private static func halved(_ image: CGImage) throws -> CGImage {
        let width = image.width / 2, height = image.height / 2
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .high
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// How many pixels between the header and the legend are not the page's
    /// white — orbs, arrows, labels, anything. Said when no label is found:
    /// none means the graph was never drawn, not that its labels were lost.
    private static func drawn(in image: CGImage) -> Int {
        let width = image.width, height = image.height
        guard let pixels = pixels(of: image) else { return 0 }
        return pixels.withUnsafeBufferPointer { pixels -> Int in
            var count = 0
            var i = Int(Double(height) * 0.15) * width * 4
            let end = Int(Double(height) * 0.88) * width * 4
            while i < end {
                if pixels[i + 3] > 200, Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) < 700 { count += 1 }
                i += 4
            }
            return count
        }
    }

    /// The five labels are spread across the graph, under their orbs — not in
    /// a pile in one corner of it. Read as drawn, and at one pixel a point
    /// where this display has two: the scale CI's runner draws at, which this
    /// Mac otherwise never reads.
    @Test func eachLabelIsDrawnByItsNode() async throws {
        let image = try await render()
        let pictures = image.width > Int(Self.size.width) ? [image, try Self.halved(image)] : [image]
        for picture in pictures {
            let size = "\(picture.width)×\(picture.height)"
            let ink = try #require(labelInk(in: picture),
                                   "the \(size) picture has no label ink: its darkest grey is \(Self.reading(of: picture).darkest) of 765, with \(Self.drawn(in: picture)) pixels of anything in the graph's area")
            #expect(ink.width > CGFloat(picture.width) * 0.5 && ink.height > CGFloat(picture.height) * 0.25,
                    "the labels are piled in \(ink) of a \(size) graph, not under their nodes")
        }
    }
}
