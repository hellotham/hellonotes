//
//  chrome-parity-compare.swift — are the Mac's and the iPad's chrome the same pixels?
//
//  Compares two folders of PNGs written by `ChromeParityTests` (one per
//  platform), scene by scene: same dimensions, and how many pixels differ by
//  how much in any channel. Writes a red difference map beside each pair.
//
//  The tolerance is antialiasing, not layout: a glyph's edge can land a few
//  levels apart when two rasterisers draw the same outline, and nothing else
//  can. A shifted line, a different size or a different colour moves hundreds
//  of pixels by tens of levels, so the thresholds below separate the two with
//  room to spare (measured on 23 September 2026: every scene within Δ1 except
//  the tip of one symbol at Δ6).
//
//  Usage: swift scripts/chrome-parity-compare.swift <mac folder> <ios folder> <diff folder>
//

import Foundation
import CoreGraphics
import ImageIO

/// A pixel counts as different beyond this channel delta…
let noise = 2
/// …and a scene fails if any channel moves more than this, or if more than
/// this share of its pixels are different.
let worstAllowed = 12
let shareAllowed = 0.001

func load(_ path: String) -> (width: Int, height: Int, pixels: [UInt8])? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (width, height, pixels)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    print("usage: chrome-parity-compare <mac folder> <ios folder> <diff folder>")
    exit(2)
}
let (mac, ios, out) = (arguments[1], arguments[2], arguments[3])
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let names = ((try? FileManager.default.contentsOfDirectory(atPath: mac)) ?? [])
    .filter { $0.hasSuffix(".png") }.sorted()
guard !names.isEmpty else { print("FAIL  no renders in \(mac)"); exit(1) }

var failed = false
for name in names {
    guard let a = load("\(mac)/\(name)") else { print("FAIL  \(name): unreadable on the Mac"); failed = true; continue }
    guard let b = load("\(ios)/\(name)") else { print("FAIL  \(name): missing on iOS"); failed = true; continue }
    guard a.width == b.width, a.height == b.height else {
        print("FAIL  \(name): size differs — Mac \(a.width)×\(a.height), iOS \(b.width)×\(b.height)")
        failed = true
        continue
    }
    var differing = 0, worst = 0
    var map = [UInt8](repeating: 0, count: a.pixels.count)
    for index in stride(from: 0, to: a.pixels.count, by: 4) {
        var delta = 0
        for channel in 0..<4 {
            delta = max(delta, abs(Int(a.pixels[index + channel]) - Int(b.pixels[index + channel])))
        }
        worst = max(worst, delta)
        if delta > noise { differing += 1 }
        map[index] = UInt8(min(255, delta * 8)); map[index + 3] = delta > 0 ? 255 : 24
    }
    let share = Double(differing) / Double(a.width * a.height)
    let ok = worst <= worstAllowed && share <= shareAllowed
    failed = failed || !ok
    print(String(format: "%@  %-22@ %4d×%-4d  worst Δ%-3d  %6d px beyond noise (%.3f%%)",
                 ok ? "ok  " : "FAIL", name as NSString, a.width, a.height, worst, differing, share * 100))
    if let context = CGContext(data: &map, width: a.width, height: a.height, bitsPerComponent: 8,
                               bytesPerRow: a.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
       let image = context.makeImage(),
       let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(out)/diff-\(name)") as CFURL,
                                                         "public.png" as CFString, 1, nil) {
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
exit(failed ? 1 : 0)
