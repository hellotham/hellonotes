//
//  FileViewerDrawsTests.swift
//  HelloNotesTests
//
//  The attachment viewer draws a local file — the model behind it is tested
//  on its own (`AttachmentDownloadTests`), and a model that reaches "here"
//  says nothing about whether the view it drives draws anything: it now holds
//  a blank while it asks, and a view stuck there would be a blank page again
//  (docs/implemented.md §51.52). Read from the window's picture: in-process,
//  SwiftUI's accessibility tree came back empty — the bottom bar's name and
//  all — so it could not tell a table from a blank.
//

#if canImport(AppKit)
import AppKit
import SwiftUI
import Testing
@testable import HelloNotes

@Suite(.serialized) @MainActor
struct FileViewerDrawsTests {

    /// The lines of dark ink above the bottom bar, each as wide as its ink
    /// runs, in pixels. A table is several lines across the width; the blank
    /// while the bytes are asked for is none, and an empty-state placeholder a
    /// short line or two in the middle.
    private static func inkLines(in image: CGImage) -> [Int] {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var lines: [Int] = []
        var current = 0
        // From the top down to where the bottom bar begins.
        for y in 0..<Int(Double(height) * 0.85) {
            var minX = width, maxX = -1
            var x = 0
            while x < width {
                let i = (y * width + x) * 4
                // Darker than a mid grey: text at one pixel a point fills no
                // pixel and is never near-black (`GraphLabelTests`); the
                // header's tint and the row rules are far lighter.
                if pixels[i + 3] > 200, Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) < 450 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                }
                x += 1
            }
            if maxX >= 0 {
                current = max(current, maxX - minX + 1)
            } else if current > 0 {
                lines.append(current)
                current = 0
            }
        }
        if current > 0 { lines.append(current) }
        return lines
    }

    /// The picture at half its size (`GraphLabelTests.halved`).
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

    /// A CSV on this device is drawn as its table.
    @Test func aLocalAttachmentIsDrawnNotLeftBlank() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "FileViewerDraws-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sample = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "SampleVault/tasks.csv")
        let csv = dir.appending(path: "tasks.csv")
        try FileManager.default.copyItem(at: sample, to: csv)

        let viewer = FileViewerView(file: CollectionFile(url: csv, lastModified: Date()),
                                    isPlaceholder: { _ in false }, prepare: { _ in })
        // Ordered in, far off any screen and borderless: a window as a window
        // is, whose views appear and whose tasks run (`GraphLabelTests`).
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 640, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Light, so text is dark whatever the Mac's appearance is just now.
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: viewer.chromeDefaults().environment(\.colorScheme, .light))
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }

        // A table: the header and the rows, each across over half the width.
        var lines: [Int] = []
        var wide = 0
        var patience = Waits.Patience(.seconds(20), every: .milliseconds(100))
        while patience.lasts {
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let picture = try #require(rep.cgImage)
            lines = Self.inkLines(in: picture)
            // And as a display of one pixel a point has it — CI's.
            let half = try Self.halved(picture)
            wide = min(lines.filter { $0 > picture.width / 2 }.count,
                       Self.inkLines(in: half).filter { $0 > half.width / 2 }.count)
            if wide >= 4 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(wide >= 4, "the table was never drawn; lines of ink, as wide as \(lines)")
    }
}
#endif
