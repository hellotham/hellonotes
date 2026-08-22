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

- Xylo mixed one
- Yoke mixed two

- Zebra mixed three

Whisky separating paragraph.

- [ ] Tango unchecked task
- [x] Uniform checked task

> Victor quoted line
> Whiskey second quoted line

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
    "```swift",         // <pre>, fenced
    "    Zulu",         // <pre>, indented
    "Alfa setext",      // <h1>, setext
    "***",              // <hr>
    "Final closing",
]

// A GFM table is deliberately absent: the editor replaces its source with a
// rendered image, and the renderer that produces it lives in the app, not in
// this package. Measuring it here would compare a table against four lines of
// pipes. Table geometry is checked where the renderer exists — in
// `EditorPreviewGeometryTests`.

var base: CGFloat = 16
var width: CGFloat = 800
var dump = false
var pngDir: String? = nil
/// How much of the document each PNG shows. The pictures are for looking at,
/// so they show the top of the note at full resolution rather than the whole
/// thing shrunk to nothing.
let pngHeight: CGFloat = 1400
var args = Array(CommandLine.arguments.dropFirst())
while let flag = args.first {
    args.removeFirst()
    switch flag {
    case "--base": base = CGFloat(Double(args.removeFirst()) ?? 16)
    case "--width": width = CGFloat(Double(args.removeFirst()) ?? 800)
    case "--dump": dump = true
    case "--png": pngDir = args.removeFirst()
    default: break
    }
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
    // Caret at the end: every construct is caret-away, which is the state
    // Preview is being compared against.
    textView.setSelectedRange(NSRange(location: (sample as NSString).length, length: 0))
    document.styleEverythingNow()
    guard let tlm = textView.textLayoutManager, let cm = tlm.textContentManager else { return [] }
    tlm.ensureLayout(for: tlm.documentRange)
    textView.layoutSubtreeIfNeeded()

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

@MainActor
final class Loader: NSObject, WKNavigationDelegate {
    var done: ((WKWebView) -> Void)?
    func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) { done?(web) }
}

@MainActor
func previewTops(_ finished: @escaping ([(String, CGFloat)]) -> Void) {
    let html = GFMRenderer.page(
        sample, fontScale: Double(base / 16),
        box: .pane(inset: EditorMetrics.textContainerInset,
                   leading: EditorMetrics.textLeadingInset))
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
                    finished(rows.map { ($0[0] as? String ?? "?", CGFloat(($0[1] as? Double) ?? .nan)) })
                }
            }
        }
    }
    web.loadHTMLString(html, baseURL: nil)
}

nonisolated(unsafe) var loaderBox: AnyObject?
nonisolated(unsafe) var previewLefts: [CGFloat] = []
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
              "Tango", "Victor", "xray", "Zulu", "Final", "Yoke", "Xi"]

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

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

MainActor.assumeIsolated {
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
app.run()
