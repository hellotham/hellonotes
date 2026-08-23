//
//  main.swift
//  RenderParity
//
//  Lay the same note out in both engines and print where every block landed.
//
//  Usage: scripts/render-parity.sh          — the whole matrix, the gate
//         swift run RenderParity [--base 16] [--width 800]   — one configuration
//
//  It lives here rather than in a test target because a `WKWebView` cannot start
//  its content process under XCTest or `swift test`: every load simply never
//  finishes, in the package's test bundle and in the app's alike
//  ("Could not signal service com.apple.WebKit.WebContent"). An ordinary
//  executable can, so the check is an executable that exits non-zero.
//

import AppKit
import WebKit
import MarkdownCore
import MarkdownEditor
import GFMRender

// MARK: - The document under test

/// One construct per top-level block, each with a word unique to it, so the
/// editor's character offsets and the page's elements can be lined up without
/// either side having to describe its own structure.
let sample = """
# Alpha heading one
Bravo tight paragraph, with no blank line above it at all.

## Charlie heading two

Delta paragraph with **bold**, *italic* and `code` Xi trailing it.

### Echo heading three
#### Foxtrot heading four
##### Golf heading five
###### Hotel heading six

India paragraph before two blank lines.


Juliett paragraph after two blank lines.

- Kilo tight one
- Lima tight two
  - Mike nested item
- November tight three

Oscar separating paragraph.

- Papa loose one

- Quebec loose two

1. Romeo ordered one
2. Sierra ordered two

1. Tango step with a listing under its text:

   ```bash
   sierra --install
   ```

2. Uniform step after it

- Xylo mixed one
- Yoke mixed two

- Zebra mixed three

Whisky separating paragraph.

- [ ] Tango unchecked task
- [x] Uniform checked task

> Victor quoted line
> Whiskey second quoted line

> Quill quoted paragraph one.
>
> Ember quoted paragraph two.

> Fjord outer quote
> > Gable nested quote

# Theta heading with bold under it
**Iota all bold directly under a heading.**

# The Heart Sūtra — Prajñāpāramitāhṛdaya
**Sigma a translation with notes**

Kappa with [a link](https://example.com/a/rather/long/path/index.html) then Lambda after it.

Mu with ~~struck out~~ then Nu after it, and **bold** and *italic* then Omicron after.

```swift
let xray = 1
let yankee = 2
```

    Zulu indented code

Alfa setext heading
===================

***

Final closing paragraph with `inline code` in it.
"""

/// Anchor per top-level block, in document order — matched to the page's
/// `.markdown-body > *` children in the same order.
let anchors = [
    "# Alpha", "Bravo tight",
    "## Charlie", "Delta paragraph",
    "### Echo", "#### Foxtrot", "##### Golf", "###### Hotel",
    "India paragraph", "Juliett paragraph",
    "- Kilo",           // <ul>, tight, with a nested item
    "Oscar separating",
    "- Papa",           // <ul>, loose
    "1. Romeo",         // <ol>
    "- Xylo",           // <ul>, loose but only at one of its two gaps
    "Whisky separating",
    "- [ ] Tango",      // <ul>, task list
    "> Victor",         // <blockquote>
    "> Quill",          // <blockquote>, two paragraphs
    "> Fjord",          // <blockquote>, nested
    "# Theta",          // a heading whose next block is entirely bold
    "**Iota",
    "# The Heart",      // a heading carrying diacritics, bold directly under it
    "**Sigma",
    "Kappa with",       // a link with a long, concealed URL
    "Mu with",          // strikethrough, strong and emphasis mid-line
    "```swift",         // <pre>, fenced
    "    Zulu",         // <pre>, indented
    "Alfa setext",      // <h1>, setext
    "***",              // <hr>
    "Final closing",
]

// A GFM table is deliberately absent from *this* sample, though the corpus
// sweeps eight of them now. The editor replaces a table's source with a
// rendered image and scales that image down to fit the pane; the page wraps its
// cells' text instead. At the sample's narrow widths (420pt at base 24) the two
// therefore diverge for a reason that is nothing to do with the box model, and
// a gate that fails for the wrong reason is a gate people learn to ignore. The
// corpus's tables all fit their pane, so the sweep measures the box model
// cleanly; fitting is the next thing to measure, not something to hide here.
// The size itself comes from `GFMTableGeometry` — see `SweepHTMLRenderer`.

var base: CGFloat = 16
var width: CGFloat = 800
var dump = false
nonisolated(unsafe) var pngDir: String? = nil
/// Sweep every example in the GFM specification corpus rather than the sample
/// above. The sample is hand-written and finds what someone thought to put in
/// it; the corpus is what the renderer is actually held to.
var specPath: String? = nil
/// Sweep whole **documents** rather than one-construct examples. The corpus
/// next door holds each construct up on its own; this holds up the notes
/// people actually write, in which every construct sits next to another one.
/// See `documentFiles`.
var docsPath: String? = nil
/// `--locate <file>`: which block of one document the divergence appears at.
var locatePath: String? = nil
/// How much of the document each PNG shows. The pictures are for looking at,
/// so they show the top of the note at full resolution rather than the whole
/// thing shrunk to nothing.
nonisolated(unsafe) var pngHeight: CGFloat = ProcessInfo.processInfo.environment["PARITY_PNG_HEIGHT"]
    .flatMap { Double($0) }.map { CGFloat($0) } ?? 1400
/// How tall a `--measure --png` pair may be. A snippet is a few hundred points
/// and 400 shows all of it; a whole *document* is thousands, and the flag whose
/// purpose is "look at it" showed the first inch of the note and nothing of the
/// tables, quotes and fences further down. `PARITY_PNG_HEIGHT` raises it.
nonisolated(unsafe) var measurePNGHeight: CGFloat = ProcessInfo.processInfo
    .environment["PARITY_PNG_HEIGHT"].flatMap { Double($0) }.map { CGFloat($0) } ?? 400
/// `--html`: render a handful of raw HTML blocks through the editor's own
/// renderer and report the image each produced. WebKit will not start a content
/// process under `swift test` or XCTest, so this — an ordinary executable — is
/// the only place the HTML embed path can actually be run.
var htmlCheck = false
/// `--chrome`: compare *where chrome is drawn*, not how tall the blocks are.
///
/// `--spec` and the gate both measure heights, and stayed green through three
/// defects you could see at a glance: bullets a half-leading high and 6pt too
/// far right, and quote bars seamed at every line break. This renders both
/// sides and measures the marks themselves.
var chromeCheck = false
/// `--measure "<markdown>"`: lay one snippet out in both engines and print the
/// two heights. The corpus tells you *that* a construct disagrees; this tells
/// you what each side actually does with it, which is the only way to settle a
/// question about CSS margin collapsing without guessing at the spec.
/// `\n` in the argument is read as a newline, so a shell can pass a document.
var measureSource: String?
/// `--baseurl <dir>`: resolve image targets against this folder instead of the
/// fixtures. Only for pointing the tool at a real vault — the corpus needs no
/// flag any more, because `fixtureRoot` is where its own targets live.
var measureBase: URL?
/// Where image targets resolve — `train.jpg`, `/url`, `moon.jpg` and the rest
/// — on **both** sides, sweep and `--measure` alike. It used to be a flag
/// nobody passed: the sweep resolved nothing, so Preview drew a broken-image
/// box, the editor left the source visible, and the corpus reported a tidy 4pt
/// difference between two fallbacks. The default is relative to the working
/// directory exactly as `--spec`'s own default path is, because both are run
/// from the repository root.
var fixtureRoot = URL(fileURLWithPath: "Tools/RenderParity/Fixtures", isDirectory: true)
var args = Array(CommandLine.arguments.dropFirst())
while let flag = args.first {
    args.removeFirst()
    switch flag {
    case "--base": base = CGFloat(Double(args.removeFirst()) ?? 16)
    case "--width": width = CGFloat(Double(args.removeFirst()) ?? 800)
    case "--dump": dump = true
    case "--html": htmlCheck = true
    case "--chrome": chromeCheck = true
    case "--measure": measureSource = args.isEmpty ? nil : args.removeFirst()
    case "--baseurl":
        // As a *directory*: without `isDirectory` the last path component is
        // taken for a file name and `pic.png` resolves beside the folder
        // rather than inside it.
        measureBase = args.isEmpty ? nil
            : URL(fileURLWithPath: args.removeFirst(), isDirectory: true)
        if let measureBase { fixtureRoot = measureBase }
    case "--png": pngDir = args.removeFirst()
    case "--docs":
        if let candidate = args.first, !candidate.hasPrefix("--") {
            docsPath = candidate
            args.removeFirst()
        } else {
            docsPath = "Tools/RenderParity/Documents"
        }
    case "--locate":
        locatePath = args.isEmpty ? nil : args.removeFirst()
    case "--spec":
        // An optional path, but only if what follows is one — `--spec --base 16`
        // must not swallow the next flag as a filename.
        if let candidate = args.first, !candidate.hasPrefix("--") {
            specPath = candidate
            args.removeFirst()
        } else {
            specPath = "Packages/NotesEditor/Tests/GFMRenderTests/spec.txt"
        }
    default: break
    }
}

// The light theme, always — pinned, not inherited.
//
// `EditorTheme`'s colours are dynamic: they resolve against the *process*
// appearance at draw time. Every dump this harness makes paints the light
// canvas explicitly and the page is rendered with `isDark: false`, so on a Mac
// set to Dark the editor's glyphs came out near-white on a white page — about
// 30 of a possible 765 of contrast, under the threshold `Pixels.bright` uses
// for ink. The chrome gate then reported `no list bullet found` and `0 code
// panel(s)` against chrome that was drawn perfectly, and it did so only on some
// machines: a gate whose answer depends on the appearance of the shell that
// started it is a gate that cannot be believed either way.
NSApplication.shared.appearance = NSAppearance(named: .aqua)

// MARK: - Chrome parity

/// One image, read as pixels.
private struct Pixels {
    let width: Int, height: Int, bpr: Int, bpp: Int
    let ptr: UnsafePointer<UInt8>
    let data: CFData
    /// This image's own page colour, as an R+G+B sum. See `bright`.
    let ground: Int

    init?(_ path: String) {
        guard let img = NSImage(contentsOfFile: path),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let d = cg.dataProvider?.data, let p = CFDataGetBytePtr(d) else { return nil }
        let w = cg.width, h = cg.height
        let rowBytes = cg.bytesPerRow, pixelBytes = cg.bitsPerPixel / 8
        width = w; height = h
        bpr = rowBytes; bpp = pixelBytes
        ptr = p; data = d
        // Read the page colour off the border, which is margin in both dumps.
        // Locals, not the properties: the closure would capture a `self` that
        // is not fully initialised yet.
        func sum(_ x: Int, _ y: Int) -> Int {
            let i = y * rowBytes + x * pixelBytes
            return Int(p[i]) + Int(p[i + 1]) + Int(p[i + 2])
        }
        var border: [Int] = []
        for x in stride(from: 0, to: w, by: max(1, w / 64)) {
            border.append(sum(x, 0)); border.append(sum(x, h - 1))
        }
        for y in stride(from: 0, to: h, by: max(1, h / 64)) {
            border.append(sum(0, y)); border.append(sum(w - 1, y))
        }
        border.sort()
        ground = border.isEmpty ? 0 : border[border.count / 2]
    }

    /// Whether this pixel is *ink* — something drawn over the page.
    ///
    /// It used to mean literally bright, `R+G+B > 200`, which reads ink on the
    /// editor's dark dump and reads the **entire page** as ink on the Preview's
    /// light one. Every row being "bright" leaves the band scan with a single
    /// band covering the whole image, so the bullet search walked off the end
    /// and the gate reported `no list bullet found` for chrome that was drawn
    /// perfectly well — for as long as the two sides have rendered in opposite
    /// polarities. Ink is a difference from the page, and the page is whatever
    /// this image's own margin is.
    func bright(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, x < width, y >= 0, y < height else { return false }
        let i = y * bpr + x * bpp
        let sum = Int(ptr[i]) + Int(ptr[i + 1]) + Int(ptr[i + 2])
        // 90 of a possible 765: enough to ignore a code block's tinted panel
        // (24 from white) and to keep a quote bar (133), which is chrome this
        // very gate exists to measure.
        return abs(sum - ground) > 90
    }

    /// Whether this pixel is *tint* — a panel painted over the page, but not
    /// ink drawn on top of one.
    ///
    /// `bright` deliberately cannot see a code block's background: at 24 of a
    /// possible 765 from white it sits under that threshold, which is what
    /// lets the bullet and bar searches ignore it. Measuring the panel needs
    /// the opposite window — anything off the page colour, and nothing dark
    /// enough to be a glyph.
    func tinted(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, x < width, y >= 0, y < height else { return false }
        let i = y * bpr + x * bpp
        let d = abs(Int(ptr[i]) + Int(ptr[i + 1]) + Int(ptr[i + 2]) - ground)
        return d > 4 && d < 200
    }

    /// Rows in `x0..<x1` carrying anything bright, as (first, last).
    func rowSpan(x0: Int, x1: Int, y0: Int, y1: Int) -> (Int, Int)? {
        var first = -1, last = -1
        for y in y0..<min(y1, height) where (x0..<min(x1, width)).contains(where: { bright($0, y) }) {
            if first < 0 { first = y }
            last = y
        }
        return first < 0 ? nil : (first, last)
    }

    /// Columns in `y0..<y1` carrying anything bright.
    func columns(x0: Int, x1: Int, y0: Int, y1: Int) -> [Int] {
        (x0..<min(x1, width)).filter { x in
            (y0..<min(y1, height)).contains { bright(x, $0) }
        }
    }

    /// The longest run of rows with *nothing* bright, inside a band.
    func longestGap(x0: Int, x1: Int, y0: Int, y1: Int) -> Int {
        var worst = 0, run = 0
        for y in y0..<min(y1, height) {
            if (x0..<min(x1, width)).contains(where: { bright($0, y) }) { run = 0 }
            else { run += 1; worst = max(worst, run) }
        }
        return worst
    }
}

/// Measure the first list bullet and the first quote bar in both renders and
/// report the difference. The two images sit at different absolute offsets, so
/// every number here is *relative to something in its own image*.
@MainActor
func checkChrome(dir: String, scale: Int) -> Int {
    guard let editor = Pixels(dir + "/editor.png"), let preview = Pixels(dir + "/preview.png") else {
        print("chrome: could not read the dumps"); return 1
    }
    var failures = 0

    /// The first list item's line, found by *structure* rather than by guessing
    /// row numbers: group the rows into bands of consecutive bright rows, and
    /// take the first band whose leftmost mark is indented past the paragraph
    /// margin but well short of the list's text column. That band is a bullet
    /// beside its item; the text column gives the baseline.
    ///
    /// Anchoring on fixed rows was tried first and reported failures on chrome
    /// that had already been fixed — a gate that cries wolf is worse than none.
    func bullet(_ p: Pixels, trace: inout [String]) -> (centreY: Int, centreX: Int, baseline: Int, textX: Int)? {
        var y = 0
        while y < p.height - 8 {
            guard (25..<700).contains(where: { p.bright($0, y) }) else { y += 1; continue }
            var end = y
            while end < p.height, (25..<700).contains(where: { p.bright($0, end) }) { end += 1 }
            let cols = p.columns(x0: 25, x1: 700, y0: y, y1: end)
            if let left = cols.first, left > 25 + 8 * scale, left < 25 + 45 * scale {
                // A gap between the mark and the text is what makes it a marker.
                if let textX = cols.first(where: { $0 > left + 6 * scale }),
                   textX - left > 8 * scale,
                   let mark = p.rowSpan(x0: left, x1: textX - 2, y0: y, y1: end),
                   mark.1 - mark.0 <= 10 * scale,
                   let text = p.rowSpan(x0: textX, x1: textX + 40 * scale, y0: y, y1: end) {
                    return ((mark.0 + mark.1) / 2, (left + textX - 2) / 2, text.1, textX)
                }
            }
            if trace.count < 14 {
                let gap = cols.first.flatMap { l in cols.first { $0 > l + 6 * scale } }
                trace.append(String(format: "    rows %4d–%-4d  left %@  next %@  ground %d",
                                    y, end,
                                    cols.first.map(String.init) ?? "—",
                                    gap.map(String.init) ?? "—", p.ground))
            }
            y = end + 1
        }
        return nil
    }

    // Kept whether or not the search succeeds: a gate that can only say "not
    // found" cannot be acted on, and this one said exactly that for a bullet
    // both sides were drawing.
    var editorTrace: [String] = [], previewTrace: [String] = []
    let e = bullet(editor, trace: &editorTrace)
    let v = bullet(preview, trace: &previewTrace)
    if let e, let v {
        // Both measured against their own text: the bullet's height above the
        // baseline, and its distance left of the first glyph.
        let eAbove = Double(e.baseline - e.centreY) / Double(scale)
        let vAbove = Double(v.baseline - v.centreY) / Double(scale)
        let eLeft = Double(e.textX - e.centreX) / Double(scale)
        let vLeft = Double(v.textX - v.centreX) / Double(scale)
        print(String(format: "bullet above baseline  edit %.1fpt  preview %.1fpt  Δ%+.1f", eAbove, vAbove, eAbove - vAbove))
        print(String(format: "bullet left of text    edit %.1fpt  preview %.1fpt  Δ%+.1f", eLeft, vLeft, eLeft - vLeft))
        if abs(eAbove - vAbove) > 1 { print("  FAIL: bullet sits at the wrong height"); failures += 1 }
        if abs(eLeft - vLeft) > 2 { print("  FAIL: bullet sits at the wrong column"); failures += 1 }
    } else {
        print("chrome: no list bullet found in \(e == nil ? (v == nil ? "either dump" : "the editor dump") : "the preview dump")")
        print("  bands scanned (leftmost ink column, then the next one past a marker-sized gap):")
        for line in (e == nil ? editorTrace : previewTrace) { print(line) }
        failures += 1
    }

    // Quote bars: the editor's must be as unbroken as the preview's. Drawn per
    // line, they used to leave a hairline seam at every line break.
    //
    // Found by its shape, not by row number: the gutter is the one mark in the
    // left margin that runs for tens of rows. Its *own* extent is then walked,
    // so the measurement is the bar's longest interior break and nothing
    // depends on where in the document the quote happens to fall. Fixed bands
    // were tried first and reported a break in a bar that is solid.
    func barBreak(_ p: Pixels) -> Int? {
        let x0 = 25, x1 = 25 + 25 * scale
        var y = p.height / 3
        while y < p.height - 4 {
            guard (x0..<x1).contains(where: { p.bright($0, y) }) else { y += 1; continue }
            // *Count* the breaks rather than measure the longest. A quote has
            // one legitimate gap in its gutter — the margin between its own
            // paragraphs — and it is 20px wide, so a one-pixel seam at every
            // line break hides completely behind it. Counting catches it:
            // solid is one break, seamed is many. (Measuring the longest was
            // tried, and passed a bar that was visibly striped.)
            var end = y, breaks = 0, run = 0
            while end < p.height {
                if (x0..<x1).contains(where: { p.bright($0, end) }) {
                    if run > 0 { breaks += 1 }
                    run = 0
                } else {
                    run += 1
                    if run > 10 * scale { break }        // past the end of this quote
                }
                end += 1
            }
            if end - y > 30 * scale { return breaks }    // tall enough to be a bar
            y = end + 1
        }
        return nil
    }
    let eGap = barBreak(editor), vGap = barBreak(preview)
    if let eGap, let vGap {
        print("quote bar breaks         edit \(eGap)  preview \(vGap)")
        if eGap > vGap { print("  FAIL: the quote bar is broken where Preview's is solid"); failures += 1 }
    } else {
        print("chrome: no quote bar found"); failures += 1
    }

    // `pre { padding: 16px }`, measured as space rather than as height.
    //
    // The box was always the right height and its listing sat hard against the
    // bottom of it: the padding was reserved as extra *line height* with the
    // glyphs "lifted off it" by a negative `.baselineOffset`, which moves the
    // reported baseline and not the ink, so the two cancelled. Nothing that
    // reads a height or a baseline can see that — this gate's own baseline
    // column reads `glyphOrigin`, which has the offset already applied, so the
    // instrument confirms its own input. What can see it is the distance from
    // the listing's last glyph to the bottom of the painted panel.
    func codePanels(_ p: Pixels) -> [(top: Int, bottom: Int, ink: (Int, Int)?)] {
        // A panel row is one where *most* of the column is tinted: `pre` is
        // painted across the whole content column, and a probe column would
        // have to guess where the listing's text ends.
        let x0 = 25, x1 = p.width - 25
        func isPanel(_ y: Int) -> Bool {
            var n = 0
            for x in stride(from: x0, to: x1, by: 4) where p.tinted(x, y) { n += 1 }
            return n * 4 > (x1 - x0) / 2
        }
        var out: [(Int, Int, (Int, Int)?)] = []
        var y = 0
        while y < p.height {
            guard isPanel(y) else { y += 1; continue }
            var end = y
            while end < p.height, isPanel(end) { end += 1 }
            if end - y > 16 * scale {
                out.append((y, end - 1, p.rowSpan(x0: x0, x1: x1, y0: y, y1: end)))
            }
            y = end + 1
        }
        return out
    }
    let ePanels = codePanels(editor), vPanels = codePanels(preview)
    if ePanels.isEmpty || ePanels.count != vPanels.count {
        print("chrome: \(ePanels.count) code panel(s) in the editor dump, \(vPanels.count) in the preview's")
        print("  (the sample's code blocks are ~1500pt down; PARITY_PNG_HEIGHT has to reach them)")
        failures += 1
    } else {
        for (i, (e, v)) in zip(ePanels, vPanels).enumerated() {
            guard let eInk = e.ink, let vInk = v.ink else {
                print("chrome: code panel \(i) has no listing in it"); failures += 1; continue
            }
            let eTop = Double(eInk.0 - e.top) / Double(scale)
            let vTop = Double(vInk.0 - v.top) / Double(scale)
            let eBot = Double(e.bottom - eInk.1) / Double(scale)
            let vBot = Double(v.bottom - vInk.1) / Double(scale)
            print(String(format: "code box %d padding    edit %.1f/%.1fpt  preview %.1f/%.1fpt  Δ%+.1f/%+.1f",
                         i, eTop, eBot, vTop, vBot, eTop - vTop, eBot - vBot))
            // Four points: the glyphs in Edit are inked a half-leading below
            // their Preview twins everywhere (a known, uniform ~2pt), and the
            // defect this exists for is the whole 16.
            if abs(eTop - vTop) > 4 { print("  FAIL: the listing sits at the wrong height in its box"); failures += 1 }
            if abs(eBot - vBot) > 4 { print("  FAIL: the code box's bottom padding is not drawn"); failures += 1 }
        }
    }

    print(failures == 0 ? "chrome parity: ok" : "chrome parity: \(failures) failure(s)")
    return failures
}

// MARK: - Raw HTML blocks

@MainActor
func checkHTMLRendering() async -> Int {
    let cases: [(String, String)] = [
        ("a styled div", "<div align=\"center\">\n  <b>Rendered</b>\n</div>"),
        ("a comment", "<!-- invisible -->"),
        ("a table", "<table><tr><td>one</td><td>two</td></tr></table>"),
        ("details", "<details><summary>More</summary>\n\nHidden.\n\n</details>"),
        ("an unknown element", "<custom-thing>text</custom-thing>"),
    ]
    let theme = EditorTheme(fontSize: base)
    var failures = 0
    print("html block                      image")
    for (label, source) in cases {
        let image = await HTMLBlockImageRenderer.image(
            source: source, maxWidth: width, fontScale: Double(base / 16),
            palette: theme.pagePalette(isDark: false), isDark: false)
        if let image, image.size.width > 1, image.size.height > 1 {
            print(label.padding(toLength: 30, withPad: " ", startingAt: 0)
                  + String(format: "%.0f x %.0f", image.size.width, image.size.height))
        } else {
            // A comment renders to nothing, and nothing is the right answer:
            // the block must then keep showing its source rather than a blank
            // band the height of an image that was never drawn.
            let expected = label == "a comment"
            print("\(label.padding(toLength: 30, withPad: " ", startingAt: 0))"
                  + (expected ? "(nothing, as it should)" : "FAILED to render"))
            if !expected { failures += 1 }
        }
    }
    return failures
}

// MARK: - Editor side (TextKit 2)

@MainActor
func editorTops() -> [(String, CGFloat)] {
    let document = EditorDocument(text: sample, theme: EditorTheme(fontSize: base))
    let (scrollView, textView) = MarkdownTextView.scrollableEditor(document: document)
    scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 4000)
    let window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView?.addSubview(scrollView)
    window.layoutIfNeeded()
    // **No selection**, so every construct really is caret-away — the state
    // Preview is being compared against. Putting the caret at the end was meant
    // to mean that and did not: the end of the document is *inside* the last
    // block, so that block alone was measured revealed.
    document.styleEverythingNow()
    guard let tlm = textView.textLayoutManager, let cm = tlm.textContentManager else { return [] }
    tlm.ensureLayout(for: tlm.documentRange)
    textView.layoutSubtreeIfNeeded()

    // `--png`: the editor's own side, for looking at rather than measuring.
    //
    // `cacheDisplay` cannot render materials — it paints them flat white — so
    // this is never evidence about window chrome. It is fine for what it is
    // used for here: the text itself, and the bands, bars and rules the
    // fragment draws with CoreGraphics onto a solid canvas.
    if let pngDir {
        // Paint the canvas the pane paints — and paint it in the *theme the
        // glyphs were styled in*. `EditorTheme` resolves its colours against
        // the process appearance, which is Aqua here, so the text is the light
        // theme's near-black; the canvas was nailed to the dark one. The dump
        // was therefore dark ink on a dark page, a page whose text sat 54 of a
        // possible 765 away from its own background — legible to nobody and to
        // nothing. It is why the chrome gate had been reporting `no list bullet
        // found` while both sides drew the bullet correctly.
        scrollView.drawsBackground = true
        scrollView.backgroundColor = EditorTheme.canvas(isDark: false)
        textView.drawsBackground = true
        textView.backgroundColor = EditorTheme.canvas(isDark: false)
        let view = scrollView.documentView ?? textView
        let bounds = CGRect(x: 0, y: 0, width: width, height: min(pngHeight, view.bounds.height))
        if let rep = view.bitmapImageRepForCachingDisplay(in: bounds) {
            view.cacheDisplay(in: bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: pngDir).appendingPathComponent("editor.png"))
            }
        }
    }

    let ns = sample as NSString
    var out: [(String, CGFloat)] = []
    for anchor in anchors {
        let range = ns.range(of: anchor)
        guard range.location != NSNotFound,
              let location = cm.location(cm.documentRange.location, offsetBy: range.location),
              let fragment = tlm.textLayoutFragment(for: location) else {
            out.append((anchor, .nan)); continue
        }
        // The fragment frame is the block's *box*: `paragraphSpacingBefore`
        // (which is how the editor spells a code block's top padding) is inside
        // it, above the first line. That is the same thing
        // `getBoundingClientRect()` reports on the other side — the border box,
        // padding included.
        out.append((anchor, fragment.layoutFragmentFrame.minY))
    }
    // No PNG of the editor here, deliberately. `cacheDisplay` on an
    // `NSTextView` outside a real app process renders the coloured runs and
    // none of the body text — a page of list markers on white — so a picture
    // taken here would be a picture of the instrument, not of the editor.
    // (docs/implemented.md and CLAUDE.md both carry the longer version of that
    // warning; a whole session was once lost to a `cacheDisplay` artefact.)
    // The editor's own snapshot lives in `EditorFidelitySnapshotTests`, which
    // runs inside the app and can draw. What *is* trustworthy here is the
    // layout geometry above, which comes from the layout manager rather than
    // from a drawing pass.
    editorTextView = textView
    editorWindow = window
    if dump {
        print("--- editor layout fragments ---")
        print("textContainer.size = \(tlm.textContainer?.size ?? .zero)  "
              + "usage = \(tlm.usageBoundsForTextContainer.size)  "
              + "textView = \(textView.frame.size)")
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location) { fragment in
            let range = fragment.rangeInElement
            let start = cm.offset(from: cm.documentRange.location, to: range.location)
            let end = cm.offset(from: cm.documentRange.location, to: range.endLocation)
            let text = (sample as NSString)
                .substring(with: NSRange(location: start, length: max(0, end - start)))
                .replacingOccurrences(of: "\n", with: "\\n")
            let style = start < (textView.textStorage?.length ?? 0)
                ? textView.textStorage?.attribute(.paragraphStyle, at: start,
                                                  effectiveRange: nil) as? NSParagraphStyle
                : nil
            let font = start < (textView.textStorage?.length ?? 0)
                ? textView.textStorage?.attribute(.font, at: start, effectiveRange: nil) as? NSFont
                : nil
            let lines = fragment.textLineFragments.map {
                String(format: "%.1f", $0.typographicBounds.height)
            }.joined(separator: "/")
            print(String(format: "y=%8.2f h=%7.2f min=%6.2f max=%6.2f sp=%6.2f spb=%6.2f f=%5.1f L=%@  %@",
                         fragment.layoutFragmentFrame.minY,
                         fragment.layoutFragmentFrame.height,
                         style?.minimumLineHeight ?? -1, style?.maximumLineHeight ?? -1,
                         style?.paragraphSpacing ?? -1, style?.paragraphSpacingBefore ?? -1,
                         font?.pointSize ?? -1, lines as NSString,
                         String(text.prefix(30)) as NSString))
            return true
        }
    }
    return out
}

// MARK: - Preview side (WebKit)

/// The page **Preview** builds for a note, which is not the page
/// `GFMRenderer.page` builds for a string.
///
/// A note goes through `NoteMarkdown.prepare` first — front matter off, wiki
/// links and `![[embeds]]` rewritten into Markdown cmark can render — and only
/// then to `GFMRenderer`. `NoteEditorPane` has always done that; this harness
/// never did, so for every `![[…]]` it laid a drawn embed against the literal
/// characters `![[foo]]` and reported a divergence that existed nowhere but
/// here. Edit and Preview agree on a wikilink in the app and always did. Build
/// the preview side through this, never through `GFMRenderer.page` directly,
/// or the sweep goes back to grading a page nobody is shown.
@MainActor
func previewPage(_ markdown: String, base: CGFloat) -> String {
    GFMRenderer.page(
        NoteMarkdown.prepare(markdown), fontScale: Double(base / 16),
        box: .pane(inset: EditorMetrics.textContainerInset,
                   leading: EditorMetrics.textLeadingInset))
}

@MainActor
final class Loader: NSObject, WKNavigationDelegate {
    var done: ((WKWebView) -> Void)?
    func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) { done?(web) }
}

@MainActor
func previewTops(_ finished: @escaping ([(String, CGFloat)]) -> Void) {
    let html = previewPage(sample, base: base)
    let config = WKWebViewConfiguration()
    config.defaultWebpagePreferences.allowsContentJavaScript = true
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 4000), configuration: config)
    let window = NSWindow(contentRect: web.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView?.addSubview(web)
    let loader = Loader()
    loaderBox = loader
    web.navigationDelegate = loader
    loader.done = { web in
        // One extra turn so layout has settled after the load event.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let js = """
            Array.from(document.querySelectorAll('.markdown-body > *')).map(function (el) {
              var r = el.getBoundingClientRect();
              var cs = getComputedStyle(el);
              return [el.tagName + ' lh=' + cs.lineHeight + ' fs=' + cs.fontSize
                      + ' h=' + r.height.toFixed(2), r.top + window.scrollY];
            })
            """
            // The Preview side does render correctly out here — WebKit draws
            // into its own surface — so its picture is worth having.
            if let pngDir {
                let config = WKSnapshotConfiguration()
                config.rect = CGRect(x: 0, y: 0, width: width, height: pngHeight)
                web.takeSnapshot(with: config) { image, _ in
                    guard let image, let tiff = image.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:]) else { return }
                    try? png.write(to: URL(fileURLWithPath: pngDir)
                        .appendingPathComponent("preview.png"))
                }
            }
            web.evaluateJavaScript(js) { value, error in
                guard let rows = value as? [[Any]] else {
                    FileHandle.standardError.write("preview failed: \(error as Any)\n".data(using: .utf8)!)
                    finished([]); return
                }
                web.evaluateJavaScript(probeJS) { lefts, _ in
                    previewLefts = (lefts as? [Double])?.map { CGFloat($0) } ?? []
                    web.evaluateJavaScript(baselineJS) { tops, _ in
                        previewGlyphTops = (tops as? [Double])?.map { CGFloat($0) } ?? []
                        web.evaluateJavaScript(fontJS) { fonts, _ in
                            previewFonts = (fonts as? [String]) ?? []
                            finished(rows.map { ($0[0] as? String ?? "?", CGFloat(($0[1] as? Double) ?? .nan)) })
                        }
                    }
                }
            }
        }
    }
    web.loadHTMLString(html, baseURL: nil)
}

nonisolated(unsafe) var loaderBox: AnyObject?
nonisolated(unsafe) var previewLefts: [CGFloat] = []
nonisolated(unsafe) var previewGlyphTops: [CGFloat] = []
nonisolated(unsafe) var previewFonts: [String] = []
nonisolated(unsafe) var editorTextView: MarkdownTextView?
nonisolated(unsafe) var editorWindow: NSWindow?

/// Words whose *glyph* position is compared, to check the horizontal axis —
/// list indents, blockquote gutters, code-block padding. Vertical agreement
/// says nothing about these: a list can sit at exactly the right height and
/// still be indented by a different amount.
//
//  Most sit at the start of a line, where the two engines agree to a tenth of a
//  point. `Xi` deliberately does not: it follows an inline `code` span forty
//  characters into a line, which is where the padding CSS reserves around such
//  a span shows up — and where it did not, that word sat nine and a half points
//  left of the Preview's.
let probes = ["Alpha", "Bravo", "Hotel", "Kilo", "Mike", "Papa", "Romeo",
              "Tango", "Victor", "xray", "Zulu", "Final", "Yoke", "Xi",
              "Quill", "Ember", "Fjord", "Gable",
              "Lambda", "Nu ", "Omicron", "Iota", "Sigma"]

/// Where the glyphs start, measured down from the top of the line box.
///
/// Every measurement so far has compared *box* positions, and they agree to a
/// hundredth of a point. Neither engine is obliged to put the baseline in the
/// same place inside a box of the same height, though: CSS splits the leading
/// evenly above and below the text, and TextKit distributes it its own way
/// under a pinned `minimumLineHeight`. A point or two there is invisible in
/// open prose and obvious on a line sitting under a heading's rule.
@MainActor
func editorGlyphTops(_ textView: MarkdownTextView) -> [CGFloat] {
    guard let tlm = textView.textLayoutManager, let cm = tlm.textContentManager else { return [] }
    let ns = sample as NSString
    return probes.map { probe in
        let range = ns.range(of: probe)
        guard range.location != NSNotFound,
              let start = cm.location(cm.documentRange.location, offsetBy: range.location),
              let fragment = tlm.textLayoutFragment(for: start) else { return CGFloat.nan }
        let offset = cm.offset(from: fragment.rangeInElement.location, to: start)
        guard let line = fragment.textLineFragments.first(where: {
            NSLocationInRange(offset, $0.characterRange)
        }) ?? fragment.textLineFragments.first else { return CGFloat.nan }
        let font = textView.textStorage?
            .attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        // `glyphOrigin.y` is the baseline inside the line fragment, so the top
        // of the text's content box is one ascent above it — and both are
        // relative to the line box, which is what the other engine reports too.
        //
        // The ascent is **rounded**, because that is the one TextKit laid the
        // line out with: an unpinned 16pt line puts its baseline at exactly
        // 15.00, not at the font's nominal 15.47. Subtracting the nominal
        // ascent measured from a place neither engine uses, and put a constant
        // 0.47pt of phantom drift on every body line at 16pt — which is what
        // the web side, reporting a range rect against its content box, does
        // not do. Same reference on both sides or the number means nothing.
        // `typographicBounds.origin.y` places the line inside its fragment and
        // `glyphOrigin.y` places the baseline inside the line. Both are needed:
        // a fragment is a whole paragraph, so on a narrow pane the probe word
        // is often on the second or third line of it, and the web side measures
        // from the top of the same paragraph. Dropping the first term compared
        // line 3 against line 1 and reported a whole line height of drift —
        // which is why this only ever showed up at width 420.
        return line.typographicBounds.origin.y + line.glyphOrigin.y
            - (font?.ascender.rounded() ?? 0)
    }
}

@MainActor
func editorLefts(_ textView: MarkdownTextView) -> [CGFloat] {
    guard let tlm = textView.textLayoutManager, let cm = tlm.textContentManager else { return [] }
    let ns = sample as NSString
    return probes.map { probe in
        let range = ns.range(of: probe)
        guard range.location != NSNotFound,
              let start = cm.location(cm.documentRange.location, offsetBy: range.location),
              let end = cm.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return CGFloat.nan }
        var x = CGFloat.nan
        tlm.enumerateTextSegments(in: textRange, type: .standard) { _, frame, _, _ in
            x = frame.minX
            return false
        }
        return x
    }
}

/// The same words on the page: how far the glyphs start below the top of the
/// block that holds them.
/// The font each side actually resolved for the same word — the question
/// "does this look slightly larger" is about, and one no geometry measurement
/// can answer.
let fontJS = """
(function () {
  var words = [\(probes.map { "'\($0)'" }.joined(separator: ", "))];
  return words.map(function (word) {
    var walker = document.createTreeWalker(document.querySelector('.markdown-body'),
                                           NodeFilter.SHOW_TEXT, null);
    var node;
    while ((node = walker.nextNode())) {
      if (node.nodeValue.indexOf(word) < 0) continue;
      var cs = getComputedStyle(node.parentElement);
      return cs.fontSize + ' w' + cs.fontWeight + ' ' + cs.fontFamily.split(',')[0];
    }
    return '?';
  });
})()
"""

let baselineJS = """
(function () {
  var words = [\(probes.map { "'\($0)'" }.joined(separator: ", "))];
  return words.map(function (word) {
    var walker = document.createTreeWalker(document.querySelector('.markdown-body'),
                                           NodeFilter.SHOW_TEXT, null);
    var node;
    while ((node = walker.nextNode())) {
      var i = node.nodeValue.indexOf(word);
      if (i < 0) continue;
      var range = document.createRange();
      range.setStart(node, i);
      range.setEnd(node, i + word.length);
      var el = node.parentElement;
      while (el && getComputedStyle(el).display === 'inline') el = el.parentElement;
      if (!el) return NaN;
      return range.getBoundingClientRect().top - el.getBoundingClientRect().top;
    }
    return NaN;
  });
})()
"""

let probeJS = """
(function () {
  var words = [\(probes.map { "'\($0)'" }.joined(separator: ", "))];
  return words.map(function (word) {
    var walker = document.createTreeWalker(document.querySelector('.markdown-body'),
                                           NodeFilter.SHOW_TEXT, null);
    var node;
    while ((node = walker.nextNode())) {
      var i = node.nodeValue.indexOf(word);
      if (i < 0) continue;
      var range = document.createRange();
      range.setStart(node, i);
      range.setEnd(node, i + word.length);
      return range.getBoundingClientRect().left + window.scrollX;
    }
    return NaN;
  });
})()
"""

// MARK: - Report

/// The page's last **painted** content bottom — the quantity the editor side
/// reports, and the quantity the editor's own HTML embeds are measured by.
///
/// The rule itself lives in `GFMRender.PaintedContent`, next to the function
/// that emits the page, so the gate and the thing it grades cannot drift apart:
/// this used to be the harness's private idea of where a page stops, while
/// `HTMLBlockImageRenderer` had a different one, and spec #160 was the gap
/// between the two dressed up as a rendering difference.
let paintedContentBottomJS = PaintedContent.bottomJS

// MARK: - The whole GFM corpus

/// Every example in `spec.txt`, in order.
///
/// **All** of them. The opening fence is ````… example` for the 648 core
/// examples and ````… example table` / `autolink` / `strikethrough` /
/// `tagfilter` / `disabled` for the 24 that belong to GFM's extensions, and
/// matching only the bare word skipped every one of the extensions — the whole
/// Tables section included, which is the construct with the most geometry in
/// it. Nothing said so: the sweep reported "648 examples" and 648 is what
/// `spec.txt` appears to hold if you only count what you already match.
///
/// Numbering is the file's own, 1…672, which is what the published spec
/// numbers these by. It is *not* what this function used to return: skipping
/// the extensions renumbered every example after the first table one, so the
/// old #568 is #580 here.
func specExamples(_ path: String) -> [(number: Int, markdown: String, section: String)] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    let lines = text.components(separatedBy: "\n")
    func isFence(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy { $0 == "`" } && s.count >= 20 }
    func isStart(_ s: String) -> Bool {
        let words = s.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count == 2 || words.count == 3 else { return false }
        return words[0].allSatisfy { $0 == "`" } && words[0].count >= 20 && words[1] == "example"
    }
    var out: [(Int, String, String)] = []
    var i = 0, n = 0
    // The section each example belongs to, so failures can be read by
    // construct rather than as 600 undifferentiated numbers.
    var section = "?"
    while i < lines.count {
        if lines[i].hasPrefix("## ") {
            section = String(lines[i].dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
        if isStart(lines[i]) {
            var md: [String] = []
            i += 1
            while i < lines.count, lines[i] != "." { md.append(lines[i]); i += 1 }
            i += 1
            while i < lines.count, !isFence(lines[i]) { i += 1 }
            n += 1
            out.append((n, (md.joined(separator: "\n") + "\n")
                .replacingOccurrences(of: "→", with: "\t"), section))
        }
        i += 1
    }
    return out
}

/// `parity:` — an origin of the harness's own, rooted at the fixture folder,
/// so the corpus's image targets resolve on *both* sides of the comparison.
///
/// The sweep used to load every page with `baseURL: nil` and hand the editor
/// no image base at all. Nothing resolved: WebKit drew its broken-image box
/// and the editor's renderer, with no folder to open, returned nil and left
/// the `![foo](/url)` source on screen. The harness scored the two, found a
/// tidy 4pt, and reported it as a rendering difference on eighteen examples —
/// it was measuring one fallback against another, and neither side had drawn
/// an image at all.
///
/// A `file:` base cannot stand in for this. Half the corpus's targets are
/// *root*-absolute (`/url`, `/path/to/train.jpg`), and a browser resolves
/// those against the origin's root — `file:///url`, which no harness can
/// create. Under a private scheme the fixture folder *is* the root, so `/url`
/// and `train.jpg` both land in it, and `resolve(_:under:)` gives the editor
/// exactly the same rule.
@MainActor
final class ParityScheme: NSObject, WKURLSchemeHandler {
    static let name = "parity"
    static let pageURL = URL(string: "parity://corpus/__parity.html")!

    /// The page currently under measurement. The sweep loads all 672 of them
    /// through one origin, so the handler serves whatever the sweep last set
    /// rather than a file on disk — nothing is written, and no stale page can
    /// be served out of WebKit's cache under a name that never changes.
    static var page = ""
    let root: URL

    init(root: URL) { self.root = root; super.init() }

    /// A corpus target as a file in the fixture folder. A leading slash is
    /// *dropped*, not honoured: `URL(string:relativeTo:)` would send `/url` to
    /// the filesystem root, and `appendingPathComponent` would keep the slash
    /// and build `…/Fixtures//url`. Both miss the file; only one of them looks
    /// like it worked.
    static func resolve(_ target: String, under root: URL) -> URL {
        var path = target.removingPercentEncoding ?? target
        while path.hasPrefix("/") { path.removeFirst() }
        return path.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        let data: Data, mime: String
        if url.path == ParityScheme.pageURL.path {
            data = Data(ParityScheme.page.utf8); mime = "text/html"
        } else if let file = try? Data(contentsOf: ParityScheme.resolve(url.path, under: root)) {
            data = file
            // By content, not by name. Half the fixtures have no extension,
            // because half the corpus's targets do not.
            mime = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png"
                 : data.starts(with: [0xFF, 0xD8]) ? "image/jpeg" : "application/octet-stream"
        } else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        task.didReceive(URLResponse(url: url, mimeType: mime,
                                    expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// The height the editor lays `markdown` out in, in container coordinates.
@MainActor
/// Renders asked for, renders returned.
///
/// The settle wait used to stop when the laid-out height had *moved and then
/// held still*, counted in runloop turns. With one embed in the document that
/// is the same thing as "the picture arrived". With two it is not, and the
/// difference is not subtle: an image embed comes back in a millisecond and a
/// raw HTML block has to load a `WKWebView`, so the image landed, the height
/// held still for ten turns of a runloop with nothing to do — which is a
/// fraction of a millisecond — and the wait ended while WebKit was still
/// starting. The document was then measured with the HTML block's *source* on
/// screen: three lines of markup where the page draws a picture, scored as a
/// 294pt rendering difference, on every note that has both a `<div>` and a
/// `![…]` in it. Nothing in the corpus does.
///
/// So the wait asks the renderer instead of guessing from the geometry. `@unchecked
/// Sendable` with a lock because `render` is `nonisolated`: the counters are
/// touched from whatever executor the embed's `Task` lands on, and the reader
/// is the main thread.
final class RenderTally: @unchecked Sendable {
    private let lock = NSLock()
    private var started = 0
    private var ended = 0
    /// Renders asked for and not yet returned.
    var outstanding: Int { lock.lock(); defer { lock.unlock() }; return started - ended }
    func begin() { lock.lock(); started += 1; lock.unlock() }
    func end() { lock.lock(); ended += 1; lock.unlock() }
}

/// The block renderer the sweep gives its editor, so raw HTML is measured the
/// way the app measures it — as the rendered fragment — rather than as the
/// source the app no longer shows.
///
/// Without this the "HTML blocks" section reported 35 of 37 examples differing
/// by up to 304pt, which was the harness describing a feature that is not the
/// one under test: it measured tag soup against rendered HTML.
struct SweepHTMLRenderer: BlockRenderer {
    let base: CGFloat
    var imageBase: URL? = nil
    /// How many renders have been asked for and how many have come back. The
    /// settle wait below reads it, because "the height moved and then stopped"
    /// is not the same statement as "every picture has arrived" — see
    /// `RenderTally`.
    let tally = RenderTally()

    func render(_ kind: BlockEmbedKind, maxWidth: CGFloat, darkMode: Bool) async -> PlatformImage? {
        tally.begin()
        defer { tally.end() }
        if case .image(let target) = kind {
            // The app's rule: scale down to the pane, never up.
            guard let imageBase else { return nil }
            let url = ParityScheme.resolve(target, under: imageBase)
            guard let image = NSImage(contentsOf: url), image.size.width > 0 else { return nil }
            guard image.size.width > maxWidth else { return image }
            let scale = maxWidth / image.size.width
            let size = CGSize(width: maxWidth, height: (image.size.height * scale).rounded())
            // Drawn, not just sized. This used to return a bare
            // `NSImage(size:)` on the grounds that a height sweep needs the
            // size and nothing else — true of `--spec`, and false of the one
            // flag whose whole purpose is to be looked at: `--png` then showed
            // a blank rectangle on the editor side against the real picture on
            // the page's, which is precisely the comparison a reader of those
            // dumps is trying to make. An empty box is also what a *failed*
            // load looks like, so the instrument could not tell "scaled" from
            // "not there".
            return await MainActor.run {
                let scaled = NSImage(size: size)
                scaled.lockFocus()
                image.draw(in: NSRect(origin: .zero, size: size))
                scaled.unlockFocus()
                return scaled
            }
        }
        // A table is drawn by the app (`TableImageRenderer`), which this tool
        // cannot link — but a height sweep does not need the picture, only its
        // size, and the size is `GFMTableGeometry`'s to give. Without this the
        // sweep laid out the *source*: four lines of pipes measured against a
        // three-row grid, scored as a spacing bug, for the whole life of the
        // two table sections of the specification.
        if case .table(let source) = kind {
            let size = await MainActor.run {
                GFMTableGeometry.fittedSize(source: source, theme: EditorTheme(fontSize: base),
                                            maxWidth: maxWidth)
            }
            guard let size, size.height >= 1 else { return nil }
            return NSImage(size: size)
        }
        guard case .html(let source, let keepsTrailingMargin) = kind else { return nil }
        // The same folder the page's own `<img>` resolves against — the app
        // gives this renderer the note's directory, so the sweep gives it the
        // fixtures. As a *file* base rather than through `parity:`: the scheme
        // handler belongs to the sweep's web view, and this render happens in
        // one of its own. A root-absolute `/url` therefore does not resolve
        // here, and the corpus has none inside an HTML block; a relative
        // `diagram.png`, which is what a note actually contains, does.
        let image = await HTMLBlockImageRenderer.image(
            source: source, maxWidth: maxWidth, fontScale: Double(base / 16),
            palette: EditorTheme(fontSize: base).pagePalette(isDark: darkMode),
            isDark: darkMode, keepsTrailingMargin: keepsTrailingMargin,
            baseURL: imageBase)
        return image
    }
}

/// Does this document contain a raw HTML block, or a standalone image? Only
/// those pay for the render wait below; the other 600 examples must stay fast.
///
/// The image half has to ask the same question `EditorDocument` asks — a
/// paragraph that is *entirely* one image — and not merely "is there a `![`
/// anywhere". Handing the sweep an image base made every example look
/// renderable, and the settle loop's exit condition needs the height to move
/// before it will stop: 648 examples × the full 3s deadline is a sweep that
/// no longer finishes.
func needsBlockRender(_ text: String, imageBase: URL?) -> Bool {
    let ns = text as NSString
    let parse = BlockParser.fullParse(ns)
    // The same map `EditorDocument` resolves with. Asking without it, the
    // harness decided `![foo]` needed no renderer, attached none, and skipped
    // the settle wait — so the editor was measured with its source still on
    // screen and the sweep reported the shortfall it had itself arranged.
    let references = LinkReferenceMap(scanning: ns, document: parse)
    for block in parse.blocks {
        if case .htmlBlock = block.kind { return true }
        // A table too: the editor shows a grid where the source is, so a sweep
        // that skipped the render wait measured the pipes it had chosen to
        // leave on screen.
        if case .table = block.kind { return true }
        guard imageBase != nil else { continue }
        // An image *inside* a line of prose is a render too. It used to be
        // missed because the question asked here was the block-embed one — is
        // this paragraph nothing but a picture — so `My ![foo](train.jpg)` got
        // no renderer and no settle wait, and the sweep measured the source
        // line the harness had itself arranged to leave on screen.
        if block.hasInlineContent {
            for span in StyleSpec.contentSpans(for: block, text: ns, lines: parse.lines) {
                // …and one level inside a link, exactly as `EditorDocument`
                // now looks. `[![badge](b.png)](https://ci)` is a picture whose
                // top-level node is the *link*, so asking only the top level
                // answered "no renderer needed" for the three badges under
                // every README title — and the sweep then measured a document
                // the editor had been given no way to draw.
                var nodes = InlineParser.parse(ns, in: span, references: references)
                for node in nodes where node.contentRange.length > 1 {
                    if case .link(_, false) = node.kind {
                        nodes.append(contentsOf: InlineParser.parse(ns, in: node.contentRange,
                                                                    references: references))
                    }
                }
                for node in nodes {
                    switch node.kind {
                    case .rawImage: return true
                    case .link(let url, true): if !url.contains("://") { return true }
                    default: continue
                    }
                }
            }
        }
        guard case .paragraph = block.kind else { continue }
        var content = block.range
        guard content.length > 0, content.location + content.length <= ns.length else { continue }
        if ns.character(at: content.location + content.length - 1) == 0x0A { content.length -= 1 }
        let nodes = InlineParser.parse(ns, in: content, references: references)
        guard nodes.count == 1, nodes[0].range == content else { continue }
        // Through a wrapping link, as `EditorDocument.blockEmbedKind` does —
        // `[![moon](moon.jpg)](/uri)` is still a paragraph that is one image.
        var node = nodes[0]
        if case .link(_, false) = node.kind {
            let inner = InlineParser.parse(ns, in: node.contentRange, references: references)
            guard inner.count == 1, inner[0].range == node.contentRange else { continue }
            node = inner[0]
        }
        switch node.kind {
        case .wikiLink(_, true): return true
        case .link(let url, true): if !url.contains("://") { return true }
        default: continue
        }
    }
    return false
}

/// The editor's side of `--measure --dump`: every layout fragment with the
/// paragraph metrics that produced it. Paired with WebKit's box list above,
/// a disagreement reads off the two tables instead of being reasoned about.
@MainActor
func editorBoxDump(_ markdown: String, base: CGFloat, width: CGFloat, imageBase: URL? = nil) {
    let text = trimmedForLayout(markdown)
    // The same services the *measurement* uses. Built with a bare
    // `EditorServices()` this dumped the un-rendered fallback for every HTML
    // block — source lines where the measured document holds a rendered
    // fragment — so the instrument disagreed with the number it was meant to
    // explain, on exactly the section with the most failures.
    let needsRender = needsBlockRender(text, imageBase: imageBase)
    let renderer = SweepHTMLRenderer(base: base, imageBase: imageBase)
    let document = EditorDocument(
        text: text, theme: EditorTheme(fontSize: base),
        services: needsRender ? EditorServices(blockRenderer: renderer) : EditorServices())
    document.renderMaxWidth = min(max(1, width - 2 * EditorMetrics.textLeadingInset), 900)
    let (scrollView, textView) = MarkdownTextView.scrollableEditor(document: document)
    scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 4000)
    let window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView?.addSubview(scrollView)
    window.layoutIfNeeded()
    document.styleEverythingNow()
    defer { window.contentView = nil }
    guard let tlm = textView.textLayoutManager,
          let storage = textView.textContentStorage?.textStorage else { return }
    tlm.ensureLayout(for: tlm.documentRange)
    // Block renders are asynchronous, so the dump has to wait for them exactly
    // as the measurement does — otherwise it prints the layout as it stood
    // before the fragment arrived.
    if needsRender {
        // The same wait the measurement makes, for the same reason: a dump
        // taken while a render is still in flight prints the layout as it
        // stood before the picture arrived, and then disagrees with the number
        // it was opened to explain.
        withExtendedLifetime(document) {
            var height = laidOutHeight(tlm)
            let start = height
            var lastChange = Date()
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
                tlm.ensureLayout(for: tlm.documentRange)
                let now = laidOutHeight(tlm)
                if now != height { height = now; lastChange = Date() }
                if height != start, renderer.tally.outstanding == 0,
                   Date().timeIntervalSince(lastChange) > 0.3 { break }
            }
        }
        tlm.ensureLayout(for: tlm.documentRange)
    }
    print("  editor fragments — top, height, line-height, spacing before/after, text")
    tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location) { fragment in
        let frame = fragment.layoutFragmentFrame
        var label = "", before: CGFloat = 0, after: CGFloat = 0, lineHeight: CGFloat = 0
        if let range = fragment.rangeInElement as NSTextRange?,
           let start = storage.nsRange(from: range, in: tlm)?.location, start < storage.length {
            let para = storage.attribute(.paragraphStyle, at: start,
                                         effectiveRange: nil) as? NSParagraphStyle
            before = para?.paragraphSpacingBefore ?? 0
            after = para?.paragraphSpacing ?? 0
            lineHeight = para?.minimumLineHeight ?? 0
            let r = storage.nsRange(from: range, in: tlm) ?? NSRange(location: 0, length: 0)
            label = String((storage.string as NSString).substring(with: r)
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(18))
        }
        print(String(format: "    %7.2f  %6.2f  lh %5.1f  before %5.1f  after %5.1f  %@",
                     frame.minY, frame.height, lineHeight, before, after, label))
        return true
    }
}

extension NSAttributedString {
    /// `NSRange` for a `NSTextRange`, which the dump needs to read attributes.
    func nsRange(from range: NSTextRange, in tlm: NSTextLayoutManager) -> NSRange? {
        guard let content = tlm.textContentManager else { return nil }
        let start = content.offset(from: content.documentRange.location, to: range.location)
        let end = content.offset(from: content.documentRange.location, to: range.endLocation)
        guard start >= 0, end >= start, end <= length else { return nil }
        return NSRange(location: start, length: end - start)
    }
}

/// The document the editor is asked to lay out: the example, without the
/// trailing newlines TextKit turns into a caret line. See `editorHeight`.
func trimmedForLayout(_ markdown: String) -> String {
    var text = markdown
    while text.hasSuffix("\n") { text.removeLast() }
    return text
}

/// How far down the editor's **last painted box** reaches: the bottom of the
/// lowest layout fragment, `bottomMargin` included (that space is inside the
/// frame — an h1 ending the note measures 50.60 from a 40pt line box and a
/// 10.60pt rule inset).
///
/// Deliberately not `usageBoundsForTextContainer`, which is what this read for
/// its whole life. That is a *scroll extent*, and it kept a height from
/// part-way through a block's collapse: 88pt for a document whose fragments
/// end at 64.02 and whose PNG has nothing at all below 64. `invalidateLayout`,
/// `ensureLayout` and `layoutViewport` all left it at 88. Spec #154 (`Foo` /
/// `<div>` / `bar` / `</div>`) was scored +24pt out on the strength of that one
/// number, against an editor drawing precisely what the page drew — the
/// instrument's own failure reported as the editor's.
///
/// It is also the only measurement symmetrical with the preview's: the page is
/// asked for the bottom of its last *painted* box (`paintedContentBottom`), not
/// for how tall a scroller would have to be to hold it.
@MainActor
func laidOutHeight(_ tlm: NSTextLayoutManager) -> CGFloat {
    var bottom: CGFloat = 0
    tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location) { fragment in
        bottom = max(bottom, fragment.layoutFragmentFrame.maxY)
        return true
    }
    return bottom
}

@MainActor
func editorHeight(_ markdown: String, base: CGFloat, width: CGFloat,
                  imageBase: URL? = nil) -> CGFloat {
    // Without the document's trailing newlines. TextKit lays out an empty line
    // after the last one — a real caret position, and a full line of height
    // that the rendered page has no equivalent of. Left in, it put a constant
    // 24pt on every single example and drowned the signal.
    //
    // **All** of them, not the one every example happens to end with. An
    // example ending in a blank line kept one newline, kept the caret line
    // with it, and was charged 24pt for a line no reader can see — the very
    // constant this is here to remove, leaking through on the handful of
    // examples where it was hardest to recognise. (The blank line itself is
    // not what is being dropped: it lays out as nothing either way, because
    // nothing below the last painted box is painted.)
    let text = trimmedForLayout(markdown)
    let needsRender = needsBlockRender(text, imageBase: imageBase)
    let renderer = SweepHTMLRenderer(base: base, imageBase: imageBase)
    let document = EditorDocument(
        text: text, theme: EditorTheme(fontSize: base),
        services: needsRender ? EditorServices(blockRenderer: renderer) : EditorServices())
    // The width a block embed is rendered at, as `MarkdownEditorView` sets it —
    // the page's own content width, and nothing else. This used to carry the
    // view's `min(…, 900)` cap, faithfully, which is how the harness came to
    // model the defect instead of catching it: both sides shrank a wide picture
    // to 900pt and agreed with each other about a page that does no such thing.
    document.renderMaxWidth = max(1, width - 2 * EditorMetrics.textLeadingInset)
    let (scrollView, textView) = MarkdownTextView.scrollableEditor(document: document)
    scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 4000)
    let window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView?.addSubview(scrollView)
    window.layoutIfNeeded()
    // **No selection.** Preview is a reader with no caret, so the editor has to
    // be measured with nothing revealed — every construct concealed, exactly as
    // someone reading the note sees it.
    //
    // This used to put the caret at the very end of the document, which reveals
    // the last block: the sweep was comparing a *source-showing* final block
    // against a rendered one, on all 648 examples. Reference definitions live
    // at the end of a link example, so the one construct that collapses hardest
    // was the one guaranteed to be measured open.
    document.styleEverythingNow()
    defer { window.contentView = nil }
    guard let tlm = textView.textLayoutManager else { return .nan }
    tlm.ensureLayout(for: tlm.documentRange)
    // `--measure --png <dir>`: dump this snippet too, so a construct can be
    // *looked at* and not only weighed. Heights agreeing says nothing about
    // whether a bullet was drawn at all.
    //
    // **After the settle wait, not before it.** This used to run here, on the
    // way past, and a rendered embed arrives asynchronously — so the one flag
    // whose entire purpose is to show what the editor draws photographed the
    // moment before it drew anything. An inline picture came out as the alt
    // text it replaces, in a document whose measured height already counted
    // the picture: the instrument disagreed with the number printed beside it.
    func dumpPNG() {
        guard let pngDir, measureSource != nil else { return }
        scrollView.drawsBackground = true
        scrollView.backgroundColor = EditorTheme.canvas(isDark: false)
        textView.drawsBackground = true
        textView.backgroundColor = EditorTheme.canvas(isDark: false)
        textView.layoutSubtreeIfNeeded()
        let view = scrollView.documentView ?? textView
        // The used height plus the pane's own top and bottom inset. Without
        // the inset the crop was short by exactly the space the text is pushed
        // down by, so anything drawn in the *last* block's bottom padding — an
        // h1/h2's rule, a code box's floor — fell off the bottom of the
        // picture. The number beside it said the space was reserved and the
        // picture said nothing was drawn there, which reads as a clipping bug
        // and is a crop.
        let h = min(measurePNGHeight, max(40, laidOutHeight(tlm)
                                 + 2 * EditorMetrics.textContainerInset.height + 10))
        let bounds = CGRect(x: 0, y: 0, width: width, height: h)
        if let rep = view.bitmapImageRepForCachingDisplay(in: bounds) {
            view.cacheDisplay(in: bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: pngDir).appendingPathComponent("measure.png"))
            }
        }
    }
    guard needsRender else {
        dumpPNG()
        return laidOutHeight(tlm)
    }

    // Block renders are asynchronous — WebKit has to lay the fragment out and
    // hand back an image before the block collapses to it. Pump the runloop
    // until the render lands and the height settles.
    //
    // The exit condition has to wait for the layout to *move* first. Settling
    // alone is met immediately: for the first tenth of a second nothing has
    // happened yet, so the height is trivially stable and the wait ends long
    // before WebKit has drawn anything.
    var height = laidOutHeight(tlm)
    let startHeight = height
    var lastChange = Date()
    // `withExtendedLifetime`, because nothing else here holds the document:
    // ARC is free to release a local after its last use, and it did — the
    // document was deallocated while its own render was still in flight, so
    // every completion took the `guard let self else { return }` and no block
    // ever collapsed. The renders all ran and all of their results were thrown
    // away, which is a very quiet way for a harness to be wrong.
    withExtendedLifetime(document) {
        // A *deadline*, not an iteration count: `run(mode:before:)` returns the
        // moment any input source fires, so 75 turns of a busy runloop went by
        // in a fraction of the 1.5s they were meant to allow, and the wait ended
        // while WebKit was still working.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            tlm.ensureLayout(for: tlm.documentRange)
            let now = laidOutHeight(tlm)
            if now != height { height = now; lastChange = Date() }
            // Three conditions, and the middle one is the whole repair. The
            // height has to have moved (nothing has happened in the first
            // millisecond, so stability alone is met immediately); **no render
            // may still be outstanding**, because with two embeds the fast one
            // landing looks exactly like the document having settled; and the
            // quiet period is wall-clock, not a count of turns, because
            // `run(mode:before:)` returns the instant any input source fires
            // and ten turns of an idle runloop take no time at all.
            if height != startHeight, renderer.tally.outstanding == 0,
               Date().timeIntervalSince(lastChange) > 0.3 { break }
        }
    }
    dumpPNG()
    if ProcessInfo.processInfo.environment["PARITY_HTMLTRACE"] == "1" {
        FileHandle.standardError.write(
            "htmltrace \(startHeight) -> \(height)  \(text.prefix(30).debugDescription)\n"
                .data(using: .utf8)!)
    }
    return height
}

/// Divergences the editor is not going to close, each with the reason it is
/// not going to, and a predicate that says which examples it covers.
///
/// **The list is empty.** All 672 examples agree, bare and under
/// `PARITY_CONTEXT=1`, so there is nothing here to consult — the type stays
/// because the discipline does, and because the next difference will want
/// somewhere honest to go.
///
/// The rule it exists to enforce: **whatever is not closed is named**. An
/// example quietly dropped from the corpus makes the agreement rate rise for
/// the wrong reason, and a difference left in the failure list with no
/// explanation is indistinguishable from one nobody has looked at yet. Named
/// divergences stay in the denominator and are printed with their reason, so
/// the headline can only ever read "N/672 + K named".
///
/// The rule that is *not* obvious, learned three times over from the three
/// entries this list used to hold: a reason has to name something about the
/// **comparison**, and every one of them named something about one side alone.
///
/// - `![[foo]]` was "a feature cmark has no equivalent for" — true of cmark,
///   and false of Preview, which rewrites the embed to `![](foo)` before cmark
///   sees it. The harness was building a page the app never shows.
/// - #142 was "modelling it would mean the editor's block-gap arithmetic
///   knowing whether the next block produces an element at all, which no other
///   rule in `GFMBoxMetrics` depends on". The editor already knew:
///   `GFMLiveStyle.unrenderedRanges` asks cmark what it kept, and
///   `BlockBoxes.producesElement` is four lines on top of that.
/// - #160 was "the editor reserves the fragment's border box and this harness
///   measures the last painted bottom" — two measurements, stated as though
///   the disagreement were the harness's taste rather than a question with an
///   answer. It had one: a box that paints nothing is a box of no height and
///   no margin, a rule the editor already applied to its own trailing blocks
///   and had never applied inside a rendered embed.
///
/// A reason that cannot be falsified from inside the harness is not a reason.
/// Each of these read as settled for as long as nobody asked what the *other*
/// engine had been handed.
///
/// Any predicate written here is asked of the *page* (or of the source), never
/// of an example number. A hardcoded number list goes stale the moment the
/// corpus gains an example — and silently, which is the worst way for a gate to
/// be wrong. (The twenty-four GFM extension examples that were invisible to
/// this sweep for its whole life shifted every number after #568 by twelve.)
enum NamedDivergence {
    static func reason() -> String? { nil }
}

@MainActor
final class SpecSweep: NSObject, WKNavigationDelegate {
    let examples: [(number: Int, markdown: String, section: String)]
    let base: CGFloat, width: CGFloat
    let web: WKWebView
    let window: NSWindow
    var index = 0
    var failures: [(number: Int, delta: CGFloat, markdown: String, section: String,
                    mine: CGFloat, theirs: CGFloat)] = []
    var total: [String: Int] = [:]
    var compared = 0
    /// Examples the harness could not put a number on, kept by name rather
    /// than deleted from the denominator.
    var unmeasured: [(number: Int, reason: String, mine: CGFloat)] = []
    /// Examples that *were* measured, do differ, and differ for a reason
    /// already understood and written down. See `NamedDivergence`.
    var named: [(number: Int, delta: CGFloat, reason: String)] = []

    init(examples: [(number: Int, markdown: String, section: String)], base: CGFloat, width: CGFloat) {
        self.examples = examples; self.base = base; self.width = width
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.setURLSchemeHandler(ParityScheme(root: fixtureRoot), forURLScheme: ParityScheme.name)
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 4000), configuration: config)
        window = NSWindow(contentRect: web.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(web)
        web.navigationDelegate = self
    }

    func run() { next() }

    /// `PARITY_CONTEXT=1` measures each example with a paragraph above and
    /// below it, on **both** sides.
    ///
    /// A spec example is a one-construct document, so every one of them is
    /// measured against the document's own edges — and the two engines define
    /// those edges differently. TextKit drops the paragraph spacing of the
    /// first and last paragraph outright; CSS keeps it, because GitHub zeroes
    /// margins only on `.markdown-body`'s *direct* children, and the `<p>`
    /// inside a loose `<li>` is not one. So a construct the editor lays out
    /// perfectly in a real note is scored as failing here, over trailing space
    /// no reader can see. Wrapping asks the question that matters: does this
    /// construct render correctly *in a document*?
    static let inContext = ProcessInfo.processInfo.environment["PARITY_CONTEXT"] == "1"

    private func wrapped(_ markdown: String) -> String {
        Self.inContext ? "Above.\n\n" + markdown + "\nBelow.\n" : markdown
    }

    private func next() {
        guard index < examples.count else { return finish() }
        let example = examples[index]
        ParityScheme.page = previewPage(wrapped(example.markdown), base: base)
        // Through the scheme rather than as a string, so `![foo](train.jpg)`
        // has somewhere to resolve to. The example number is on the URL only
        // to keep WebKit from serving example 3 out of its cache when example
        // 4 asks for the same page name.
        var request = URLRequest(url: URL(string: "?\(example.number)",
                                          relativeTo: ParityScheme.pageURL)!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        web.load(request)
    }

    func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) { measure() }
    func webView(_ web: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        index += 1; next()
    }

    private func measure() {
        let js = """
        (function () {
          \(paintedContentBottomJS)
          var b = document.querySelector('.markdown-body');
          // The only page there is nothing to measure on. Two other cases used
          // to bail out here — the page's own <script> blocks re-parented into
          // an unclosed tag, and an inline element left as the article's last
          // child — and both were symptoms of the *old* measurement rather
          // than of the page: a `<script>` is `display: none`, so it moves no
          // painted edge, and the re-parented trailing paragraph only inflated
          // the page because its margin was being counted. Measuring the last
          // painted bottom, both are ordinary pages, and 15 examples came back
          // into the denominator with real numbers.
          if (!b) return -1;
          // The page's height, and nothing else. This used to return two shape
          // flags beside it — "ends in a bare text node", "last box paints
          // nothing" — for `NamedDivergence` to excuse #142 and #160 by. Both
          // are closed, and the flags had to go with them: left in, they would
          // quietly *name* a regression on exactly those shapes instead of
          // failing on it, which is the one thing this sweep must never do.
          return paintedContentBottom(b);
        })()
        """
        web.evaluateJavaScript(js) { [self] value, _ in
            let previewHeight = CGFloat((value as? Double) ?? .nan)
            let example = examples[index]
            // Same fixtures the page just resolved its `<img>` against — the
            // editor has to be given the folder too, or the sweep compares a
            // drawn image against a line of Markdown source.
            let mine = editorHeight(wrapped(example.markdown), base: base, width: width,
                                    imageBase: fixtureRoot)
            // A construct that renders to *nothing* — an empty `<div>`, a
            // `<!DOCTYPE>`, a bare reference definition, an empty `>` — is a
            // real comparison, not an absent one: the editor has to render
            // nothing too. Requiring `previewHeight > 0` dropped 13 examples
            // out of the corpus and, with them, four genuine failures where
            // the editor stood 24–48pt tall against an empty page. An example
            // that leaves the denominator makes the agreement rate go up for
            // the wrong reason.
            if previewHeight >= 0, previewHeight.isFinite, mine.isFinite {
                compared += 1
                total[example.section, default: 0] += 1
                let delta = mine - previewHeight
                if abs(delta) >= 1 {
                    if let reason = NamedDivergence.reason() {
                        named.append((example.number, delta, reason))
                    } else {
                        failures.append((example.number, delta, example.markdown, example.section,
                                         mine, previewHeight))
                    }
                }
            } else {
                // Named, not dropped. An example that leaves the denominator
                // is an example the harness has stopped asking about, and the
                // agreement rate then rises for the wrong reason — so say what
                // could not be measured and why, and report the rate against
                // the corpus, never against what survived it.
                unmeasured.append((example.number,
                              previewHeight < 0 ? "the page has no .markdown-body"
                                  : !previewHeight.isFinite ? "the preview returned no number"
                                  : "the editor laid out no finite height",
                              mine))
            }
            index += 1
            if index % 50 == 0 {
                FileHandle.standardError.write("…\(index)/\(examples.count)\n".data(using: .utf8)!)
            }
            next()
        }
    }

    private func finish() {
        for (number, reason, mine) in unmeasured {
            print(String(format: "UNMEASURED #%d — %@ (edit %.1f)", number, reason as NSString, mine))
        }
        for (number, delta, reason) in named.sorted(by: { $0.number < $1.number }) {
            print(String(format: "named divergence #%d (%+.2fpt) — %@",
                         number, delta, reason as NSString))
        }
        // The rate is against the **corpus**, never against what survived it,
        // and the named ones are spelled out beside it rather than folded into
        // "agree". A headline that reads `668 agree, 3 named, 2 differ` cannot
        // be improved by moving an example from the third number to the second
        // without saying, in the line above, exactly what was accepted.
        print("GFM corpus: \(compared)/\(examples.count) compared"
              + (unmeasured.isEmpty ? "" : " + \(unmeasured.count) unmeasured")
              + ", \(compared - failures.count - named.count) agree"
              + (named.isEmpty ? "" : ", \(named.count) named")
              + ", \(failures.count) differ by ≥1pt")
        print("")
        print(String(format: "%-42@ %6@ %6@ %9@",
                     "section" as NSString, "differ" as NSString,
                     "of" as NSString, "worst" as NSString))
        var bySection: [String: [CGFloat]] = [:]
        for failure in failures { bySection[failure.section, default: []].append(failure.delta) }
        for section in total.keys.sorted() {
            let deltas = bySection[section] ?? []
            let worst = deltas.map { abs($0) }.max() ?? 0
            print(String(format: "%-42@ %6d %6d %8.2f",
                         section as NSString, deltas.count, total[section] ?? 0, worst))
        }
        if let only = ProcessInfo.processInfo.environment["PARITY_SECTION"] {
            print("")
            print("— \(only) —")
            // An empty filter lists every failure. Swift's `contains("")` is
            // false, so `PARITY_SECTION=` used to print a header and nothing —
            // and the whole listing needs one sweep, not one per section.
            for failure in failures where only.isEmpty || failure.section.contains(only) {
                let source = failure.markdown
                    .replacingOccurrences(of: "\n", with: "⏎")
                    .replacingOccurrences(of: "\t", with: "→")
                print(String(format: "  #%-4d edit %7.1f  preview %7.1f  %+8.2fpt  %@",
                             failure.number, failure.mine, failure.theirs, failure.delta,
                             String(source.prefix(52)) as NSString))
            }
        }
        // An **unmeasured** example is a failure: the harness could not answer
        // for it, and a gate that passes on those is a gate that can be quieted
        // by breaking the measurement. A **named** one is not — it is measured,
        // it differs, and the reason is written down above; failing on it would
        // only teach people to ignore the exit code.
        exit(failures.isEmpty && unmeasured.isEmpty ? 0 : 1)
    }
}

nonisolated(unsafe) var sweep: SpecSweep?

// MARK: - Whole documents

/// The documents in `Tools/RenderParity/Documents`, in name order.
///
/// The corpus next door tests **one construct at a time**, and a document is a
/// *combination*. That difference is not theoretical: with all 672 spec
/// examples agreeing to a hundredth of a point, a single README-shaped note
/// still measured 7pt out, and the two causes were both invisible to every one
/// of the 672 — a `li code` rule that only misfires when no list marker shares
/// the code's first line box, and a fence whose delimiters were never
/// concealed inside a list item, so the info string was drawn *inside* the
/// code box. Neither construct is wrong on its own. They are wrong together.
///
/// So these are notes, not specimens: a README with badges and numbered steps
/// carrying fences, meeting notes with nested quotes and task lists, a
/// document that ends in each awkward thing and one that starts with it, a
/// fence inside a list inside a quote, paragraphs long enough to wrap, CJK and
/// emoji and combining marks, front matter. What they have in common is that
/// somebody could plausibly have written them.
///
/// Add one. A document that passes the moment it is written was too easy: of
/// the defects this folder found on its first runs, *six* needed a narrow pane
/// as well as a combination — a code box inside a list item laid out 32pt too
/// wide, an opening margin paid once per wrapped line, a quote's lazy
/// continuation handed the full pane, a listing inside a quoted item carrying
/// its own `>` at full size. None of them changes a height until something
/// wraps, and nothing in 672 one-construct examples wraps at any width the
/// sweep uses.
///
/// **What is deliberately not here, and why.** Three shapes are measured,
/// written down and left, because none of them is a box-model difference and a
/// gate that fails on them every run is a gate people learn to ignore:
///
///  * **Display maths.** `$$ … $$` measures edit 132.00 / preview 152.00,
///    −20.00pt, and the two surfaces are showing *different content*: the
///    editor draws the formula (SwiftMath, via the app's `MathImageRenderer`)
///    and `GFMRenderer` attaches no maths extension, so Preview prints the
///    literal `$$`. What would close it is one maths engine for both — the
///    move `HTMLBlockImageRenderer` already makes for raw HTML, where Edit
///    renders the block through `GFMRenderer.page` so the picture it draws *is*
///    the fragment Preview would have drawn. That needs a LaTeX renderer inside
///    the page, which is a dependency decision rather than a parity fix.
///  * **A table wider than the pane.** Below about 520pt the wider fixtures stop
///    fitting, and Preview wraps the cell text while the editor scales the whole
///    grid down (`GFMTableGeometry.fit`; `TableImageRenderer`'s own comment
///    explains that scaling the columns without the font would clip the text).
///    Closing it means a wrapping table layout on both sides.
///  * **A line break after `/`.** TextKit takes a break opportunity after a
///    solidus and WebKit does not, so a URL longer than the column wraps one
///    line earlier in Edit. Discriminating case: a code line `AB ` + 82 `a`s +
///    `/` + `bbbbb` measures −20.00pt, and the same line with the `/` replaced
///    by `-` measures +0.00 (both engines break after a hyphen). There is no
///    CSS that adds the opportunity and no attribute that removes it —
///    `lineBreakStrategy = []` was tried and changes nothing.
func documentFiles(_ path: String) -> [(name: String, markdown: String)] {
    let root = URL(fileURLWithPath: path, isDirectory: true)
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
        .filter { $0.hasSuffix(".md") }
        .sorted()
    return names.compactMap { name in
        guard let text = try? String(contentsOf: root.appendingPathComponent(name),
                                     encoding: .utf8) else { return nil }
        return (name, text)
    }
}

/// `--docs`: lay every document out in both engines and compare the totals.
///
/// Structurally the same as `SpecSweep` and deliberately so — same page
/// builder, same painted-bottom measurement, same editor call with the same
/// fixture root — because a second gate that measured a slightly different
/// quantity would disagree with the first for reasons nobody could attribute.
/// What differs is only what is being fed in, and that nothing is wrapped:
/// `PARITY_CONTEXT` exists to give a one-construct example the document edges
/// it lacks, and a document has its own.
@MainActor
final class DocSweep: NSObject, WKNavigationDelegate {
    let documents: [(name: String, markdown: String)]
    let base: CGFloat, width: CGFloat
    let web: WKWebView
    let window: NSWindow
    var index = 0
    var rows: [(name: String, mine: CGFloat, theirs: CGFloat)] = []
    var unmeasured: [(name: String, reason: String)] = []

    init(documents: [(name: String, markdown: String)], base: CGFloat, width: CGFloat) {
        self.documents = documents; self.base = base; self.width = width
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.setURLSchemeHandler(ParityScheme(root: fixtureRoot), forURLScheme: ParityScheme.name)
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 20000), configuration: config)
        window = NSWindow(contentRect: web.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(web)
        web.navigationDelegate = self
    }

    func run() { next() }

    private func next() {
        guard index < documents.count else { return finish() }
        ParityScheme.page = previewPage(documents[index].markdown, base: base)
        var request = URLRequest(url: URL(string: "?doc\(index)", relativeTo: ParityScheme.pageURL)!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        web.load(request)
    }

    func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) { measure() }
    func webView(_ web: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        unmeasured.append((documents[index].name, "the page failed to load"))
        index += 1; next()
    }

    private func measure() {
        let js = """
        (function () {
          \(paintedContentBottomJS)
          var b = document.querySelector('.markdown-body');
          if (!b) return -1;
          return paintedContentBottom(b);
        })()
        """
        web.evaluateJavaScript(js) { [self] value, _ in
            let theirs = CGFloat((value as? Double) ?? .nan)
            let document = documents[index]
            let mine = editorHeight(document.markdown, base: base, width: width,
                                    imageBase: fixtureRoot)
            if theirs >= 0, theirs.isFinite, mine.isFinite {
                rows.append((document.name, mine, theirs))
            } else {
                unmeasured.append((document.name,
                                   theirs < 0 ? "the page has no .markdown-body"
                                       : !theirs.isFinite ? "the preview returned no number"
                                       : "the editor laid out no finite height"))
            }
            index += 1
            next()
        }
    }

    private func finish() {
        var worst: CGFloat = 0
        var failures = 0
        print(String(format: "%-38@ %10@ %10@ %9@",
                     "document" as NSString, "edit" as NSString,
                     "preview" as NSString, "delta" as NSString))
        for row in rows {
            let delta = row.mine - row.theirs
            worst = max(worst, abs(delta))
            if abs(delta) >= 1 { failures += 1 }
            print(String(format: "%@ %-36@ %10.2f %10.2f %+9.2f",
                         abs(delta) >= 1 ? "!" : " ", row.name as NSString,
                         row.mine, row.theirs, delta))
        }
        for (name, reason) in unmeasured {
            print("UNMEASURED \(name) — \(reason)")
        }
        // The same accounting rule the corpus sweep uses: the rate is against
        // what was *asked*, never against what survived being asked, and an
        // unmeasured document is a failure rather than an absence — a gate
        // that passes when its own measurement breaks can be quieted by
        // breaking it.
        print("documents: \(rows.count)/\(documents.count) compared"
              + (unmeasured.isEmpty ? "" : " + \(unmeasured.count) unmeasured")
              + ", \(rows.count - failures) agree, \(failures) differ by ≥1pt")
        print(String(format: "worst document delta: %.2fpt", worst))
        if failures > 0 {
            print("")
            print("Localise one with:  swift run --package-path Tools/RenderParity RenderParity \\")
            print("                      --locate Tools/RenderParity/Documents/<name>.md")
        }
        exit(failures == 0 && unmeasured.isEmpty ? 0 : 1)
    }
}

nonisolated(unsafe) var docSweep: DocSweep?

/// `--locate <file>`: where in a document the two engines part company.
///
/// A whole-document total says a note is 7pt out and nothing else, and 7pt is
/// as easily one block wrong by seven as seven blocks wrong by one — or, worse,
/// two blocks wrong by +9 and −2, which a total reports as a small problem.
/// This lays out every **prefix** of the document, one top-level block at a
/// time, and prints the running delta beside the block that produced it. The
/// first row where the delta moves is the block that is wrong; a row where it
/// moves back is the one paying for it.
///
/// Prefixes are cut on `BlockParser`'s own top-level tiling, which is flat and
/// non-overlapping, so every prefix is a document in its own right. Cutting on
/// blank lines was tried first and cuts fences and list items in half, which
/// reparses into something else entirely and reports a divergence in a
/// document that does not exist.
@MainActor
final class Locator: NSObject, WKNavigationDelegate {
    let prefixes: [(label: String, markdown: String)]
    let base: CGFloat, width: CGFloat
    let web: WKWebView, window: NSWindow
    var index = 0
    var previous: CGFloat = 0

    init(markdown: String, base: CGFloat, width: CGFloat) {
        self.base = base; self.width = width
        let ns = markdown as NSString
        let parse = BlockParser.fullParse(ns)
        var built: [(String, String)] = []
        for block in parse.blocks {
            let end = block.range.location + block.range.length
            guard end > 0, end <= ns.length else { continue }
            let label = ns.substring(with: block.range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: "⏎")
            built.append((String(label.prefix(46)), ns.substring(to: end)))
        }
        prefixes = built
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.setURLSchemeHandler(ParityScheme(root: fixtureRoot), forURLScheme: ParityScheme.name)
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 20000), configuration: config)
        window = NSWindow(contentRect: web.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(web)
        web.navigationDelegate = self
    }

    func run() {
        print(String(format: "%-4@ %9@ %9@ %9@ %9@  %@",
                     "#" as NSString, "edit" as NSString, "preview" as NSString,
                     "delta" as NSString, "moved" as NSString, "block" as NSString))
        next()
    }

    private func next() {
        guard index < prefixes.count else { exit(0) }
        ParityScheme.page = previewPage(prefixes[index].markdown, base: base)
        var request = URLRequest(url: URL(string: "?p\(index)", relativeTo: ParityScheme.pageURL)!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        web.load(request)
    }

    func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
        let js = """
        (function () {
          \(paintedContentBottomJS)
          var b = document.querySelector('.markdown-body');
          if (!b) return -1;
          return paintedContentBottom(b);
        })()
        """
        web.evaluateJavaScript(js) { [self] value, _ in
            let theirs = CGFloat((value as? Double) ?? .nan)
            let mine = editorHeight(prefixes[index].markdown, base: base, width: width,
                                    imageBase: fixtureRoot)
            let delta = mine - theirs
            let moved = delta - previous
            previous = delta
            print(String(format: "%-4d %9.2f %9.2f %+9.2f %+9.2f  %@%@",
                         index + 1, mine, theirs, delta, moved,
                         abs(moved) >= 0.5 ? "<<< " : "", prefixes[index].label as NSString))
            index += 1
            next()
        }
    }
}
nonisolated(unsafe) var locator: Locator?

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

/// Preview height for one snippet, via the same page the sweep builds.
@MainActor
final class OneShot: NSObject, WKNavigationDelegate {
    let web: WKWebView, window: NSWindow, markdown: String, base: CGFloat, width: CGFloat
    init(markdown: String, base: CGFloat, width: CGFloat) {
        self.markdown = markdown; self.base = base; self.width = width
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.setURLSchemeHandler(ParityScheme(root: fixtureRoot), forURLScheme: ParityScheme.name)
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 4000), configuration: config)
        window = NSWindow(contentRect: web.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(web)
        web.navigationDelegate = self
    }
    /// WebKit's picture of the snippet, beside TextKit's.
    ///
    /// `--measure --png` used to write `measure.png` and nothing else — the one
    /// flag whose entire purpose is "look at it" showed you one of the two
    /// things being compared. A height is not an appearance: the list bullets
    /// sitting a half-leading high, and the quote bars seaming at every line
    /// break, were both found in pictures while every number was green, and
    /// neither could have been seen from the editor's side alone.
    ///
    /// Cropped by the rule `dumpPNG` crops the editor by, so the two files can
    /// be laid side by side without either being rescaled first.
    private func snapshotPreview(height: CGFloat, _ then: @escaping @MainActor () -> Void) {
        guard let pngDir else { return then() }
        let config = WKSnapshotConfiguration()
        let h = height.isFinite
            ? min(measurePNGHeight, max(40, height + 2 * EditorMetrics.textContainerInset.height + 10))
            : pngHeight
        config.rect = CGRect(x: 0, y: 0, width: width, height: h)
        web.takeSnapshot(with: config) { image, _ in
            if let image, let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: pngDir)
                    .appendingPathComponent("preview.png"))
            }
            then()
        }
    }

    func run() {
        let page = previewPage(markdown, base: base)
        // Through `parity:`, exactly as the sweep loads it. This used to write
        // the page into the base folder and `loadFileURL` it, which resolves a
        // *relative* `train.jpg` and silently fails a root-absolute `/url` —
        // WebKit substitutes its 22pt broken-image box for the 20pt picture,
        // and `--measure` then explained a sweep failure with a number the
        // sweep had not measured.
        ParityScheme.page = page
        var request = URLRequest(url: ParityScheme.pageURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        web.load(request)
    }
    func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
        // The same quantity the sweep measures, from the same source — a
        // `--measure` that answered a different question from `--spec` is an
        // instrument that cannot explain its own failures.
        let js = """
        (function () {
          \(paintedContentBottomJS)
          var b = document.querySelector('.markdown-body');
          if (!b) return -1;
          return paintedContentBottom(b);
        })()
        """
        // `--dump` alongside `--measure` prints WebKit's own boxes for the
        // snippet — tag, top, height and the *used* margins. Working a
        // disagreement back from a single total means re-deriving CSS margin
        // collapsing by hand, and guessing wrong there is what turned one
        // missing margin into three wrong ones.
        // `PARITY_CSS=line-height,font-size` appends those *computed* values to
        // every row. A box that is the wrong height is a declaration that did
        // not apply or one that applied where it should not have, and the only
        // way to tell those apart is to ask the engine what it resolved — two
        // rounds of plausible reasoning about specificity produced two wrong
        // answers before this existed.
        let extra = ProcessInfo.processInfo.environment["PARITY_CSS"] ?? ""
        let extraProps = extra.split(separator: ",").map(String.init)
        let extraJS = extraProps.isEmpty ? "[]"
            : "[" + extraProps.map { "cs['\($0)']" }.joined(separator: ", ") + "]"
        let boxes = """
        (function () {
          var b = document.querySelector('.markdown-body'), out = [];
          var top = b.getBoundingClientRect().top;
          // Text nodes get a row too. A bare text node makes an *anonymous*
          // block box with no element to hang a row on, so a walk over
          // `children` alone printed a page whose rows stopped 40pt above the
          // height it was being asked to explain — the dump silently disagreed
          // with the measurement on exactly the examples that needed it.
          (function walk(el, depth) {
            for (var i = 0; i < el.childNodes.length; i++) {
              var c = el.childNodes[i];
              if (c.nodeType === 3) {
                if (!c.nodeValue.trim()) continue;
                var rg = document.createRange(); rg.selectNodeContents(c);
                var tr = rg.getBoundingClientRect(), pcs = getComputedStyle(el);
                out.push([new Array(depth + 1).join('  ') + '#text',
                          (tr.top - top).toFixed(2), tr.height.toFixed(2), '-', '-']
                         .concat(\(extraJS.replacingOccurrences(of: "cs[", with: "pcs[")))
                         .concat([c.nodeValue.trim().slice(0, 18)]).join('  '));
                continue;
              }
              if (c.nodeType !== 1) continue;
              var r = c.getBoundingClientRect(), cs = getComputedStyle(c);
              out.push([new Array(depth + 1).join('  ') + c.tagName,
                        (r.top - top).toFixed(2), r.height.toFixed(2),
                        cs.marginTop, cs.marginBottom]
                       .concat(\(extraJS))
                       .concat([(c.textContent || '').trim().slice(0, 18)]).join('  '));
              walk(c, depth + 1);
            }
          })(b, 0);
          return out;
        })()
        """
        web.evaluateJavaScript(js) { [self] value, _ in
            let preview = CGFloat((value as? Double) ?? .nan)
            let mine = editorHeight(markdown, base: base, width: width, imageBase: fixtureRoot)
            print(markdown.replacingOccurrences(of: "\n", with: "⏎").debugDescription)
            print(String(format: "  edit %.2f   preview %.2f   delta %+.2f", mine, preview, mine - preview))
            snapshotPreview(height: preview) { [self] in
                guard dump else { exit(0) }
                web.evaluateJavaScript(boxes) { rows, error in
                    if let error { print("  preview boxes: \(error)") }
                    print("  preview boxes — tag, top, height, margin-top, margin-bottom")
                    for row in (rows as? [String]) ?? [] { print("    " + row) }
                    editorBoxDump(self.markdown, base: self.base, width: self.width, imageBase: fixtureRoot)
                    exit(0)
                }
            }
        }
    }
}
nonisolated(unsafe) var oneShot: OneShot?

MainActor.assumeIsolated {
    if chromeCheck {
        // The gate finds its constructs by shape, wherever they fall — and the
        // sample's two code blocks fall about 1500pt down. The dump's default
        // height is a *viewing* choice (the top of the note at full
        // resolution); cropped there, the gate simply cannot see the end of
        // the document it is grading.
        if ProcessInfo.processInfo.environment["PARITY_PNG_HEIGHT"] == nil { pngHeight = 4000 }
        let dir = NSTemporaryDirectory() + "parity-chrome"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        pngDir = dir
        _ = editorTops()                       // writes editor.png
        previewTops { _ in
            exit(Int32(checkChrome(dir: dir, scale: 2)))
        }
    } else if let source = measureSource {
        let markdown = source
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
        let s = OneShot(markdown: markdown, base: base, width: width)
        oneShot = s
        s.run()
    } else if htmlCheck {
        Task { @MainActor in
            let failures = await checkHTMLRendering()
            exit(failures == 0 ? 0 : 1)
        }
    } else if let locatePath {
        guard let text = try? String(contentsOfFile: locatePath, encoding: .utf8) else {
            FileHandle.standardError.write("no document at \(locatePath)\n".data(using: .utf8)!)
            exit(2)
        }
        let l = Locator(markdown: text, base: base, width: width)
        locator = l
        l.run()
    } else if let docsPath {
        let documents = documentFiles(docsPath)
        guard !documents.isEmpty else {
            FileHandle.standardError.write("no documents at \(docsPath)\n".data(using: .utf8)!)
            exit(2)
        }
        print("sweeping \(documents.count) documents at base=\(base) width=\(width)")
        let d = DocSweep(documents: documents, base: base, width: width)
        docSweep = d
        d.run()
    } else if let specPath {
        let examples = specExamples(specPath)
        guard !examples.isEmpty else {
            FileHandle.standardError.write("no examples at \(specPath)\n".data(using: .utf8)!)
            exit(2)
        }
        print("sweeping \(examples.count) GFM examples at base=\(base) width=\(width)")
        let s = SpecSweep(examples: examples, base: base, width: width)
        sweep = s
        s.run()
    } else {
    let editor = editorTops()
    previewTops { preview in
        let m = GFMBoxMetrics(base: base)
        print("base=\(base)  width=\(width)  bodyLineHeight=\(m.bodyLineHeight)  blockGap=\(m.blockGap)")
        print(String(format: "%-18@ %10@ %10@ %10@ %10@",
                     "block" as NSString, "edit" as NSString, "preview" as NSString,
                     "Δtop" as NSString, "Δgap" as NSString))
        let count = min(editor.count, preview.count)
        if editor.count != preview.count {
            print("!! \(editor.count) editor blocks vs \(preview.count) preview elements")
        }
        var worst: CGFloat = 0
        var previousDelta: CGFloat = 0
        for i in 0..<count {
            let e = editor[i].1, p = preview[i].1
            let delta = e - p
            let drift = i == 0 ? 0 : delta - previousDelta
            previousDelta = delta
            if i > 0 { worst = max(worst, abs(drift)) }
            print(String(format: "%-16@ %9.2f %9.2f %8.2f %8.2f  %@",
                         editor[i].0 as NSString, e, p, delta, drift,
                         preview[i].0 as NSString))
        }
        print(String(format: "worst per-block drift: %.2fpt", worst))

        // Horizontal: the same words, in both engines. The two coordinate
        // systems differ by the text container's own inset, which the editor
        // applies when it draws rather than when it lays out — so compare each
        // probe's offset from the first, which sits at the margin.
        var worstX: CGFloat = 0
        let lefts = editorTextView.map { editorLefts($0) } ?? []
        if !lefts.isEmpty, previewLefts.count == lefts.count {
            print("")
            print(String(format: "%-16@ %9@ %9@ %9@",
                         "probe" as NSString, "edit" as NSString,
                         "preview" as NSString, "Dindent" as NSString))
            for i in probes.indices {
                let e = lefts[i] - lefts[0], p = previewLefts[i] - previewLefts[0]
                worstX = max(worstX, abs(e - p))
                print(String(format: "%-16@ %9.2f %9.2f %9.2f",
                             probes[i] as NSString, lefts[i], previewLefts[i], e - p))
            }
            print(String(format: "worst indent drift: %.2fpt", worstX))

            // Where the glyphs sit *inside* the line box — the one thing box
            // positions cannot show.
            let mineTops = editorTextView.map { editorGlyphTops($0) } ?? []
            if mineTops.count == previewGlyphTops.count, !mineTops.isEmpty {
                print("")
                print(String(format: "%-16@ %9@ %9@ %9@",
                             "probe" as NSString, "edit" as NSString,
                             "preview" as NSString, "Dbaseline" as NSString))
                var worstBaseline: CGFloat = 0
                for i in probes.indices where mineTops[i].isFinite && previewGlyphTops[i].isFinite {
                    let delta = mineTops[i] - previewGlyphTops[i]
                    worstBaseline = max(worstBaseline, abs(delta))
                    print(String(format: "%-16@ %9.2f %9.2f %9.2f",
                                 probes[i] as NSString, mineTops[i], previewGlyphTops[i], delta))
                }
                print(String(format: "worst baseline drift: %.2fpt", worstBaseline))
            }
            let ns = sample as NSString
            if previewFonts.count == probes.count, let tv = editorTextView {
                print("")
                print(String(format: "%-16@ %-34@ %@",
                             "probe" as NSString, "edit font" as NSString,
                             "preview font" as NSString))
                for i in probes.indices {
                    let r = ns.range(of: probes[i])
                    guard r.location != NSNotFound,
                          let f = tv.textStorage?.attribute(.font, at: r.location,
                                                            effectiveRange: nil) as? NSFont
                    else { continue }
                    let weight = (f.fontDescriptor.object(forKey: .init("NSFontWeightTrait")) as? Double)
                        ?? (f.fontDescriptor.symbolicTraits.contains(.bold) ? 1 : 0)
                    let mine = String(format: "%@ %.1fpt w%.2f", f.fontName, f.pointSize, weight)
                    print(String(format: "%-16@ %-34@ %@",
                                 probes[i] as NSString, mine as NSString,
                                 previewFonts[i] as NSString))
                }
            }
        } else {
            print("!! horizontal probe failed (\(lefts.count) vs \(previewLefts.count))")
            worstX = 999
        }
        editorWindow?.contentView = nil
        // Vertical drift is what accumulates down a note, so it is held to a
        // point.
        //
        // Horizontal is looser, and has to be. A glyph's position is the sum of
        // every advance before it on its line, and two text engines do not
        // shape a line to the same fractions of a point — so a word at the
        // *start* of a line lands within a tenth of a point, and a word forty
        // characters in lands within two. That is not drift in the sense that
        // matters: it resets at every line rather than building up, and it is
        // the one thing here neither side can be made to fix, short of both
        // engines shaping identically.
        exit(worst < 1 && worstX < 2 ? 0 : 1)
    }
    }
}
app.run()
