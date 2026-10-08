//
//  window-parity-compare.swift — one Mac window against one iPad screen.
//
//  The iPad capture is the whole screen in landscape: it is turned upright
//  (the file may carry its orientation rather than its pixels in it), cut to
//  the safe area the app draws in — below the 24pt status bar and above the
//  20pt home indicator — and compared with the Mac window, which is that size.
//  Masked: the Mac's traffic lights (the 78×40pt the bar leaves them) and the
//  window's rounded corners, which are the OS's.
//
//  Prints how much differs and where it clusters (a 16pt grid), writes a
//  difference map and a side-by-side picture, and fails past antialiasing.
//
//  Usage: swift scripts/window-parity-compare.swift <mac.png> <ipad.png> <diff.png> <side.png>
//

import Foundation
import CoreGraphics
import ImageIO

let scale = 2
let top = 24 * scale, bottom = 20 * scale
let noise = 2
let shareAllowed = 0.001

func image(_ path: String, upright: Bool) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    if !upright { return CGImageSourceCreateImageAtIndex(source, 0, nil) }
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                    kCGImageSourceCreateThumbnailWithTransform: true,
                                    kCGImageSourceThumbnailMaxPixelSize: 100_000]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

func pixels(_ image: CGImage, crop: CGRect? = nil) -> (Int, Int, [UInt8]) {
    let region = crop ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let width = Int(region.width), height = Int(region.height)
    var data = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Draw so that `region` (top-left origin) lands in the context.
    context.draw(image, in: CGRect(x: -region.minX, y: region.maxY - CGFloat(image.height),
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
    return (width, height, data)
}

func write(_ data: inout [UInt8], _ width: Int, _ height: Int, to path: String) {
    let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                      "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
}

let arguments = CommandLine.arguments
guard arguments.count == 5,
      let mac = image(arguments[1], upright: false),
      let ipad = image(arguments[2], upright: true) else {
    print("usage: window-parity-compare <mac.png> <ipad.png> <diff.png> <side.png>")
    exit(2)
}
let name = URL(fileURLWithPath: arguments[1]).deletingPathExtension().lastPathComponent
let (width, height, a) = pixels(mac)
guard ipad.width == width, ipad.height - top - bottom == height else {
    print("FAIL  \(name): Mac window \(width)×\(height)px, iPad safe area \(ipad.width)×\(ipad.height - top - bottom)px")
    exit(1)
}
let (_, _, b) = pixels(ipad, crop: CGRect(x: 0, y: top, width: width, height: height))

let corner = 26 * scale
func masked(_ x: Int, _ y: Int) -> Bool {
    if x < 78 * scale && y < 40 * scale { return true }                       // traffic lights
    // iPadOS's window-resize grabber, drawn into the window's bottom-right.
    if x >= width - 36 * scale && y >= height - 36 * scale { return true }
    let nearX = x < corner || x >= width - corner, nearY = y < corner || y >= height - corner
    return nearX && nearY                                                       // rounded corners
}

var differing = 0, worst = 0, counted = 0
var map = [UInt8](repeating: 0, count: width * height * 4)
var cells: [Int: Int] = [:]
let cell = 16 * scale
for y in 0..<height {
    for x in 0..<width {
        let i = (y * width + x) * 4
        if masked(x, y) { map[i + 1] = 60; map[i + 3] = 255; continue }
        counted += 1
        var delta = 0
        for c in 0..<3 { delta = max(delta, abs(Int(a[i + c]) - Int(b[i + c]))) }
        worst = max(worst, delta)
        if delta > noise {
            differing += 1
            cells[(y / cell) * 10_000 + x / cell, default: 0] += 1
        }
        map[i] = UInt8(min(255, delta * 4)); map[i + 3] = delta > noise ? 255 : 30
    }
}
write(&map, width, height, to: arguments[3])

// Side by side at half size: Mac | iPad (safe area).
let sideWidth = width, sideHeight = height / 2
var side = [UInt8](repeating: 255, count: sideWidth * sideHeight * 4)
for y in 0..<sideHeight {
    for x in 0..<(width / 2) {
        for (offset, source) in [(0, a), (width / 2, b)] {
            let s = ((y * 2) * width + x * 2) * 4, d = (y * sideWidth + x + offset) * 4
            for c in 0..<4 { side[d + c] = source[s + c] }
        }
    }
}
write(&side, sideWidth, sideHeight, to: arguments[4])

let share = Double(differing) / Double(counted)
let ok = share <= shareAllowed
print(String(format: "%@  %-10@ %d×%dpx  worst Δ%d  %d px beyond noise (%.3f%%)",
             ok ? "ok  " : "FAIL", name as NSString, width, height, worst, differing, share * 100))
for (key, count) in cells.sorted(by: { $0.value > $1.value }).prefix(12) where count > 8 {
    let (row, column) = (key / 10_000, key % 10_000)
    print("      \(count) px near (\(column * 16), \(row * 16))pt")
}
exit(ok ? 0 : 1)
