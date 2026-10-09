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
    private func render() async throws -> CGImage {
        #if canImport(AppKit)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: graph())
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .seconds(2))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try #require(rep.cgImage)
        #else
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(origin: .zero, size: Self.size)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = UIHostingController(rootView: graph())
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .seconds(2))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return try #require(image.cgImage)
        #endif
    }

    /// The box around the near-black pixels — the node labels — between the
    /// graph's header and its legend, in pixels. The orbs, the arrows and the
    /// header's grey are not near-black.
    private func labelInk(in image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in Int(Double(height) * 0.15)..<Int(Double(height) * 0.88) {
            for x in 0..<width {
                let i = (y * width + x) * 4
                guard pixels[i + 3] > 200,
                      Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) < 150 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The five labels are spread across the graph, under their orbs — not in
    /// a pile in one corner of it.
    @Test func eachLabelIsDrawnByItsNode() async throws {
        let image = try await render()
        let ink = try #require(labelInk(in: image), "the graph drew no labels at all")
        #expect(ink.width > CGFloat(image.width) * 0.5 && ink.height > CGFloat(image.height) * 0.25,
                "the labels are piled in \(ink) of a \(image.width)×\(image.height) graph, not under their nodes")
    }
}
