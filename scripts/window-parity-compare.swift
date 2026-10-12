//
//  window-parity-compare.swift — one Mac window against one iPad screen.
//
//  The iPad capture is the whole screen in landscape: it is turned upright
//  (the file may carry its orientation rather than its pixels in it), cut to
//  the safe area the app draws in — below the status bar and above the home
//  indicator, **as measured and passed in** — and compared with the Mac
//  window, which is that size. The insets were constants here, 24 and 20, until
//  the simulator's status bar became 32pt: every row was then 8pt out and an
//  empty window that matched failed by 3.5% (implemented.md §51.43).
//
//  Masked: the Mac's traffic lights and the sidebar toggle they displace (the
//  bar's leading end), the window's rounded corners, and iPadOS's resize
//  grabber — all the OS's.
//
//  **With a note open, the editor is reported and not judged.** The note's
//  text is 17pt on iOS and 16pt on the Mac on purpose
//  (`AppearanceSettings.baseEditorFontSize`), so the middle of that picture
//  cannot match and never did. The verdict is the chrome's — the sidebar, the
//  bar, the status row — and the editor column's difference is printed beside
//  it, where a change in it can still be seen.
//
//  Prints how much differs and where it clusters (a 16pt grid), writes a
//  difference map and a side-by-side picture, and fails past antialiasing.
//
//  Usage: swift scripts/window-parity-compare.swift <mac.png> <ipad.png> <diff.png> <side.png>
//             <top inset, pt> <bottom inset, pt> [note]
//

import Foundation
import CoreGraphics
import ImageIO

let scale = 2
let noise = 2
let shareAllowed = 0.001
/// The chrome around the editor, in points — `-sidebarWidth 280` and its 1pt
/// rule, `Chrome.Metric.barHeight`, `Chrome.Metric.statusRow`.
let sidebar = 281, bar = 40, statusRow = 34
/// The bar's leading end, which is the OS's on the Mac: its window controls
/// take 78pt (`WindowControls.leadingInset`) and push the sidebar's toggle —
/// a 44pt target — after them, where the iPad draws the same toggle at the
/// edge. One glyph in two places, and nothing else is in either.
let leadingEnd = 78 + 46

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
guard arguments.count == 7 || (arguments.count == 8 && arguments[7] == "note"),
      let topInset = Int(arguments[5]), let bottomInset = Int(arguments[6]),
      let mac = image(arguments[1], upright: false),
      let ipad = image(arguments[2], upright: true) else {
    print("usage: window-parity-compare <mac.png> <ipad.png> <diff.png> <side.png> <top inset> <bottom inset> [note]")
    exit(2)
}
let top = topInset * scale, bottom = bottomInset * scale
let noteIsOpen = arguments.count == 8
let name = URL(fileURLWithPath: arguments[1]).deletingPathExtension().lastPathComponent
let (width, height, a) = pixels(mac)
guard ipad.width == width, ipad.height - top - bottom == height else {
    print("FAIL  \(name): Mac window \(width)×\(height)px, iPad safe area \(ipad.width)×\(ipad.height - top - bottom)px")
    exit(1)
}
let (_, _, b) = pixels(ipad, crop: CGRect(x: 0, y: top, width: width, height: height))

let corner = 26 * scale
func masked(_ x: Int, _ y: Int) -> Bool {
    if x < leadingEnd * scale && y < bar * scale { return true }               // traffic lights, and the toggle
    // iPadOS's window-resize grabber, drawn into the window's bottom-right.
    if x >= width - 36 * scale && y >= height - 36 * scale { return true }
    let nearX = x < corner || x >= width - corner, nearY = y < corner || y >= height - corner
    return nearX && nearY                                                       // rounded corners
}

/// The note itself, when one is open: everything the sidebar, the bar and the
/// status row leave.
func inEditor(_ x: Int, _ y: Int) -> Bool {
    noteIsOpen && x >= sidebar * scale && y >= bar * scale && y < height - statusRow * scale
}

var differing = 0, worst = 0, counted = 0
var editorDiffering = 0, editorCounted = 0
var map = [UInt8](repeating: 0, count: width * height * 4)
var cells: [Int: Int] = [:]
let cell = 16 * scale
for y in 0..<height {
    for x in 0..<width {
        let i = (y * width + x) * 4
        if masked(x, y) { map[i + 1] = 60; map[i + 3] = 255; continue }
        var delta = 0
        for c in 0..<3 { delta = max(delta, abs(Int(a[i + c]) - Int(b[i + c]))) }
        if inEditor(x, y) {
            // Shown in blue, so the map says which differences were not judged.
            editorCounted += 1
            if delta > noise { editorDiffering += 1 }
            map[i + 2] = UInt8(min(255, 40 + delta * 4)); map[i + 3] = delta > noise ? 255 : 30
            continue
        }
        counted += 1
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
print(String(format: "%@  %-10@ %d×%dpx%@  worst Δ%d  %d px beyond noise (%.3f%%)",
             ok ? "ok  " : "FAIL", name as NSString, width, height, noteIsOpen ? ", the chrome" : "",
             worst, differing, share * 100))
if noteIsOpen {
    print(String(format: "      the note, reported and not judged — its text is 17pt on iOS and 16pt on the Mac: "
                 + "%d px differ (%.1f%% of the editor)",
                 editorDiffering, Double(editorDiffering) / Double(max(editorCounted, 1)) * 100))
}
for (key, count) in cells.sorted(by: { $0.value > $1.value }).prefix(12) where count > 8 {
    let (row, column) = (key / 10_000, key % 10_000)
    print("      \(count) px near (\(column * 16), \(row * 16))pt")
}
exit(ok ? 0 : 1)
