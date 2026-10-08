//
//  PreviewSuperset.swift
//  HelloNotes
//
//  Preview renders **the note**, not a GitHub approximation of it.
//
//  GFM parity is the floor, not the ceiling. `GFMRenderer` matches GitHub byte
//  for byte on the 672-example spec corpus, and that is worth keeping — but a
//  HelloNotes note is a *superset* of GFM, and the parts that make it one are
//  the reasons to use the app: LaTeX, and `![[transclusion]]`. Preview showed
//  neither. `$$…$$` came through as literal dollar signs, and an embed was
//  rewritten to `![](Some%20Note)` — an `<img>` pointing at a Markdown file,
//  which a web view cannot load, so the page had a silent blank where the
//  embedded note should be.
//
//  ## How
//
//  The same native renderers the editor uses, encoded as `data:` URIs and
//  substituted before the Markdown reaches cmark-gfm. That is deliberate on
//  three counts:
//
//  * **The two surfaces cannot drift.** Edit draws `MathImageRenderer`'s image
//    and so does Preview — literally the same bitmap, not two engines that
//    agree today.
//  * **Nothing is fetched.** No KaTeX, no MathJax, no CDN, no script. The page
//    stays offline and the privacy answer stays "Data Not Collected".
//  * **GFM is untouched.** Everything that is not maths or an embed goes to
//    cmark-gfm exactly as before, so the spec corpus and the parity harness
//    still measure what they measured.
//
//  `CMARK_OPT_UNSAFE` is already set (`GFMRenderer.html`), which is what lets an
//  `<img>` survive to the page — GitHub does the same with raw HTML.
//
//  ## What is left alone
//
//  Code. A note that *documents* the syntax — `` `$x$` `` in a span, or a
//  `$$…$$` inside a fence — must render as text, exactly as it does on GitHub
//  and in the editor. This walks fences and inline code spans for that reason;
//  it is the same rule `NoteMarkdown.rewriteWikiConstructs` follows, for the
//  same reason.
//

import Foundation
import MarkdownCore
import MarkdownEditor
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

nonisolated enum PreviewSuperset {

    /// Diagrams, formulas and transclusion cards already drawn, as the `<img>`
    /// tags they became, by what drew them. A pass runs each time the note
    /// settles, and drawing a diagram is 123ms at 120 nodes before its PNG is
    /// encoded — every one of them, every pass, when nothing about most of them
    /// had changed.
    static let rendered = RenderedTags(limit: 16 << 20)

    /// Where `rendered` keeps a diagram: by its source and appearance.
    static func diagramKey(_ source: String, isDark: Bool) -> String {
        "hn-diagram\u{1}\(isDark)\u{1}\(source)"
    }

    /// Where `rendered` keeps a formula: by its source, its size and class
    /// (inline or block), and appearance.
    static func mathKey(_ source: String, fontSize: CGFloat, isDark: Bool, class cls: String) -> String {
        "\(cls)\u{1}\(Int(fontSize))\u{1}\(isDark)\u{1}\(source)"
    }

    /// Substitute the note-dialect constructs Preview cannot otherwise draw,
    /// returning Markdown that is now plain GFM plus a few `<img>` tags.
    ///
    /// **Off the main actor.** It was `@MainActor` from top to bottom — a walk
    /// of every line, and each formula's PNG encoded — and ran whenever the
    /// note changed, which in Split mode was every keystroke. Only what must
    /// be drawn there goes back: a formula (SwiftMath lays out a view) and an
    /// embed's card (`CollectionEmbedProvider`), each once, then from a cache.
    /// A cancelled pass stops at the next line and draws nothing more.
    ///
    /// - Parameter embeds: resolves `![[target]]` to a rendered card. `nil`
    ///   leaves embeds to `NoteMarkdown`, which turns them into links.
    @concurrent static func apply(to text: String,
                                  isDark: Bool,
                                  embeds: CollectionEmbedProvider?) async -> String {
        let pass = rendered.beginPass()
        var out: [String] = []
        var fence: String?
        var mermaid: [String]?          // body of an open ```mermaid fence
        var mathBlock: [String]?
        var callout: (kind: String, title: String, body: [String])?

        func flushCallout() {
            guard let c = callout else { return }
            out.append(Callout.html(kind: c.kind, title: c.title, body: c.body))
            callout = nil
        }

        for line in text.components(separatedBy: "\n") {
            // Whoever asked has stopped waiting; what comes back is discarded.
            if Task.isCancelled { return text }
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Inside a ```mermaid fence: collect, then draw it.
            if mermaid != nil {
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    let source = (mermaid ?? []).joined(separator: "\n")
                    mermaid = nil
                    out.append(await diagram(source, isDark: isDark, pass: pass)
                               ?? "```mermaid\n\(source)\n```")
                } else {
                    mermaid?.append(line)
                }
                continue
            }
            // Inside any other fenced code block: verbatim, including any `$$`.
            if let f = fence {
                out.append(line)
                if trimmed.hasPrefix(f) { fence = nil }
                continue
            }
            // Collecting a `$$ … $$` block that opened on an earlier line.
            if mathBlock != nil {
                if trimmed.hasSuffix("$$") {
                    let last = String(trimmed.dropLast(2))
                    if !last.isEmpty { mathBlock?.append(last) }
                    let source = (mathBlock ?? []).joined(separator: "\n")
                    mathBlock = nil
                    out.append(await blockMath(source, isDark: isDark, pass: pass) ?? "$$\(source)$$")
                } else {
                    mathBlock?.append(line)
                }
                continue
            }
            // A callout is a blockquote whose first line is `> [!type]`. The
            // `>` lines under it belong to it; the first line that is not `>`
            // ends the run.
            if callout != nil {
                if trimmed.hasPrefix(">") {
                    callout?.body.append(Callout.strip(trimmed))
                    continue
                }
                flushCallout()
            }
            if let opened = Callout.opening(trimmed) {
                callout = (opened.kind, opened.title, [])
                continue
            }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                // A diagram is the one fence whose *contents* are drawn rather
                // than shown. Everything else — including a fence that merely
                // quotes Mermaid source — stays code. Which info strings open
                // one is the editor's rule, asked rather than copied: a copy
                // here wanted the one word, so ```mermaid theme was a picture
                // in Edit and code here.
                let info = trimmed.drop(while: { $0 == "`" || $0 == "~" })
                if MermaidDiagram.isDiagram(info: info) {
                    mermaid = []
                } else {
                    fence = String(trimmed.prefix(while: { $0 == "`" || $0 == "~" }))
                    out.append(line)
                }
                continue
            }

            // A whole-line `$$ … $$`, or the opening of a multi-line one.
            if trimmed.hasPrefix("$$") {
                let body = String(trimmed.dropFirst(2))
                if body.hasSuffix("$$"), body.count >= 2 {
                    let source = String(body.dropLast(2))
                    out.append(await blockMath(source, isDark: isDark, pass: pass) ?? line)
                } else {
                    mathBlock = body.isEmpty ? [] : [body]
                }
                continue
            }

            out.append(await inlineConstructs(line, isDark: isDark, embeds: embeds, pass: pass))
        }

        flushCallout()
        // An unterminated construct is not a construct — give the text back.
        if let pending = mathBlock { out.append("$$" + pending.joined(separator: "\n")) }
        if let pending = mermaid { out.append("```mermaid\n" + pending.joined(separator: "\n")) }
        return out.joined(separator: "\n")
    }

    // MARK: - One line

    /// Walks a line, leaving inline code spans verbatim and substituting the
    /// rest.
    private static func inlineConstructs(_ line: String,
                                         isDark: Bool,
                                         embeds: CollectionEmbedProvider?,
                                         pass: Int) async -> String {
        // Every construct this pass can substitute. A line holding none of
        // them is returned untouched — which is almost every line, and is what
        // keeps this cheap enough to run on the whole note.
        guard line.contains("$") || line.contains("![[")
                || line.contains("==") || line.contains("%%")
        else { return line }
        var out = ""
        var idx = line.startIndex
        while idx < line.endIndex {
            if line[idx] == "`" {
                let open = idx
                var run = 0
                while idx < line.endIndex, line[idx] == "`" { run += 1; idx = line.index(after: idx) }
                let ticks = String(repeating: "`", count: run)
                if let close = line.range(of: ticks, range: idx..<line.endIndex) {
                    out += String(line[open..<close.upperBound])   // code span, verbatim
                    idx = close.upperBound
                } else {
                    out += ticks
                }
            } else {
                let start = idx
                while idx < line.endIndex, line[idx] != "`" { idx = line.index(after: idx) }
                out += await substitute(String(line[start..<idx]), isDark: isDark, embeds: embeds, pass: pass)
            }
        }
        return out
    }

    private static func substitute(_ segment: String,
                                   isDark: Bool,
                                   embeds: CollectionEmbedProvider?,
                                   pass: Int) async -> String {
        var s = segment
        if s.contains("![["), let embeds {
            s = await replaceEmbeds(in: s, isDark: isDark, embeds: embeds, pass: pass)
        }
        if s.contains("$") {
            s = await inlineMath(in: s, isDark: isDark, pass: pass)
        }
        // `==highlight==` and `%%comment%%` are the note dialect's own inline
        // spellings — cmark-gfm has never heard of either, so without this they
        // reach the page as literal `==` and `%%`.
        if s.contains("==") {
            s = s.replacing(/==([^=\n]+)==/) { m in
                "<mark class=\"hn-highlight\">" + String(m.1) + "</mark>"
            }
        }
        if s.contains("%%") {
            // Dimmed, not deleted — the editor dims them, and a Preview that
            // silently removed text would disagree with the document open in
            // the other tab.
            s = s.replacing(/%%([^%\n]+)%%/) { m in
                "<span class=\"hn-comment\">%%" + String(m.1) + "%%</span>"
            }
        }
        return s
    }

    /// `> [!type] Title` — Obsidian's callout, as a styled blockquote.
    ///
    /// HTML rather than an image, unlike maths and diagrams: a callout is
    /// *prose*, and prose in a picture cannot be selected, searched, resized or
    /// read aloud. The body stays Markdown and cmark-gfm still renders it — a
    /// raw HTML block ends at a blank line, which is what lets the content
    /// between the tags go through the normal pipeline.
    nonisolated enum Callout {

        static func opening(_ trimmed: String) -> (kind: String, title: String)? {
            guard trimmed.hasPrefix(">") else { return nil }
            let afterQuote = strip(trimmed)
            guard let match = try? /^\[!([A-Za-z]+)\]-?\s*(.*)$/.firstMatch(in: afterQuote)
            else { return nil }
            return (String(match.1).lowercased(), String(match.2))
        }

        /// One `>` and any single space after it.
        static func strip(_ line: String) -> String {
            var s = Substring(line)
            if s.hasPrefix(">") { s = s.dropFirst() }
            if s.hasPrefix(" ") { s = s.dropFirst() }
            return String(s)
        }

        static func html(kind: String, title: String, body: [String]) -> String {
            let shown = title.isEmpty ? kind.capitalized : title
            let inner = body.joined(separator: "\n")
            let open = "<blockquote class=\"hn-callout hn-callout-\(cssClass(kind))\">"
            let head = "<p class=\"hn-callout-title\"><span class=\"hn-callout-glyph\">"
                + glyph(kind) + "</span>" + escape(shown) + "</p>"
            return open + "\n" + head + "\n\n" + inner + "\n\n</blockquote>"
        }

        /// The editor's own taxonomy (`StyleApplier.calloutStyle`), so the two
        /// surfaces colour the same word the same way.
        static func cssClass(_ kind: String) -> String {
            switch kind {
            case "tip", "hint", "important":                              return "tip"
            case "warning", "caution", "attention":                       return "warning"
            case "danger", "error", "bug", "failure", "fail", "missing":  return "danger"
            case "success", "check", "done":                              return "success"
            case "question", "help", "faq":                               return "question"
            case "example":                                               return "example"
            case "quote", "cite":                                         return "quote"
            case "abstract", "summary", "tldr":                           return "abstract"
            default:                                                      return "note"
            }
        }

        /// A glyph, not an SF Symbol: a web view has no symbol font.
        static func glyph(_ kind: String) -> String {
            switch cssClass(kind) {
            case "tip":       return "◆"
            case "warning":   return "▲"
            case "danger":    return "✕"
            case "success":   return "✓"
            case "question":  return "?"
            case "example":   return "▸"
            case "quote":     return "❝"
            case "abstract":  return "≡"
            default:          return "✎"
            }
        }

        private static func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
    }


    /// `![[target]]` / `![[target#heading]]` → the rendered card.
    ///
    /// The target is read by the rule every reader of a link shares
    /// (`WikiLinkSyntax`): a table's `![[Note\|alias]]` names `Note`. Read
    /// up to the pipe, it looked up `Note\`, and the card was not drawn
    /// (implemented.md §51.36).
    private static func replaceEmbeds(in segment: String,
                                      isDark: Bool,
                                      embeds: CollectionEmbedProvider,
                                      pass: Int) async -> String {
        let pattern = /!\[\[([^\]|]+)(\|[^\]]+)?\]\]/
        var out = ""
        var rest = Substring(segment)
        while let match = try? pattern.firstMatch(in: rest) {
            out += rest[rest.startIndex..<match.range.lowerBound]
            let target = WikiLinkSyntax.target(written: match.1, aliased: match.2 != nil)
                .trimmingCharacters(in: .whitespaces)
            if let tag = await embedTag(target, isDark: isDark, embeds: embeds, pass: pass) {
                out += tag
            } else {
                out += String(rest[match.range])   // unresolved: leave it visible
            }
            rest = rest[match.range.upperBound...]
        }
        return out + rest
    }

    /// The card for `![[target]]`, as a tag. The provider draws the card (on
    /// the main actor, which it hops to) and hands back the same image until
    /// the note it shows changes, so the tag is kept for that image
    /// (`drawnFrom`) and a card drawn again is a miss. Encoded off the main
    /// actor: a card is the whole embedded note, and a standalone probe in the
    /// concurrency review put the encoding at 30–46ms for a card 400pt tall
    /// and 680ms for one 8,000pt tall — on the main actor, until the review
    /// found that a platform image is `Sendable` after all.
    private static func embedTag(_ target: String, isDark: Bool,
                                 embeds: CollectionEmbedProvider, pass: Int) async -> String? {
        guard let image = await embeds.image(forName: target, isDark: isDark) else { return nil }
        let key = "hn-embed\u{1}\(isDark)\u{1}\(target)"
        if let kept = rendered.tag(for: key, drawnFrom: image, pass: pass) { return kept.isEmpty ? nil : kept }
        let tag = await offMain { imageTag(image, class: "hn-embed", alt: target) }
        rendered.store(tag ?? "", for: key, drawnFrom: image, pass: pass)
        return tag
    }

    /// `$…$` → an inline image, sized and baseline-shifted so it sits in the
    /// line rather than on top of it.
    private static func inlineMath(in segment: String, isDark: Bool, pass: Int) async -> String {
        let pattern = /\$([^$\n]+)\$/
        var out = ""
        var rest = Substring(segment)
        while let match = try? pattern.firstMatch(in: rest) {
            out += rest[rest.startIndex..<match.range.lowerBound]
            let source = String(match.1)
            if let tag = await mathTag(source, fontSize: 16, isDark: isDark, class: "hn-math-inline", pass: pass) {
                out += tag
            } else {
                out += String(rest[match.range])
            }
            rest = rest[match.range.upperBound...]
        }
        return out + rest
    }

    private static func blockMath(_ source: String, isDark: Bool, pass: Int) async -> String? {
        guard let tag = await mathTag(source, fontSize: 20, isDark: isDark, class: "hn-math-block", pass: pass)
        else { return nil }
        return "<p class=\"hn-math-wrap\">\(tag)</p>"
    }

    /// A formula as a tag: from `rendered`, or drawn on the main actor —
    /// SwiftMath lays out a view — and encoded off it, once.
    private static func mathTag(_ source: String, fontSize: CGFloat, isDark: Bool,
                                class cls: String, pass: Int) async -> String? {
        let key = mathKey(source, fontSize: fontSize, isDark: isDark, class: cls)
        if let kept = rendered.tag(for: key, pass: pass) { return kept.isEmpty ? nil : kept }
        let image = await MainActor.run {
            MathImageRenderer.image(latex: source, fontSize: fontSize, color: ink(isDark))
        }
        let tag = await offMain { image.flatMap { imageTag($0, class: cls, alt: source) } }
        rendered.store(tag ?? "", for: key, pass: pass)
        return tag
    }

    /// A ```mermaid fence → the rendered diagram, as the editor draws it — with
    /// the enlarge button the editor draws on it. The page styles it
    /// (`GFMPage`'s `.hn-zoom`) and hands its clicks to the app
    /// (`GFMPreview.onDiagramZoom`); the button carries the diagram's source,
    /// which is what it asks to have enlarged.
    ///
    /// Drawn off the main actor, as the editor draws it: parse, layout,
    /// rasterise and the PNG encoding are computation — 123ms at 120 nodes
    /// before the encoding — and none of it needs the main thread.
    /// Drawn once per source and appearance (`rendered`): typing elsewhere in
    /// the note used to draw every diagram in it again, at each change.
    static func diagram(_ source: String, isDark: Bool, pass: Int = 0) async -> String? {
        let key = diagramKey(source, isDark: isDark)
        let tag: String?
        if let kept = rendered.tag(for: key, pass: pass) {
            tag = kept.isEmpty ? nil : kept
        } else {
            tag = await offMain { () -> String? in
                guard let image = MermaidDiagramRenderer.standaloneImage(source: source, isDark: isDark) else { return nil }
                return imageTag(image, class: "hn-diagram", alt: "diagram")
            }
            // A source that draws nothing draws nothing next time too.
            rendered.store(tag ?? "", for: key, pass: pass)
        }
        guard let tag else { return nil }
        return "<p class=\"hn-diagram-wrap\"><span class=\"hn-diagram-box\">\(tag)"
            + "<button class=\"hn-zoom\" type=\"button\" title=\"View diagram\" "
            + "aria-label=\"View diagram\" data-hn-zoom=\"\(attributeValue(source))\"></button>"
            + "</span></p>"
    }

    /// `text` as an HTML attribute value, **on one line**.
    ///
    /// This markup reaches cmark-gfm as a raw HTML block, and a raw HTML block
    /// ends at a blank line. A diagram with an empty line in it — the usual way
    /// to space a long one — would cut its own tag in half and pour the rest of
    /// its source onto the page as text. So line breaks are character
    /// references, which the browser turns back into line breaks.
    static func attributeValue(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\r", with: "&#13;")
            .replacingOccurrences(of: "\n", with: "&#10;")
    }

    @MainActor private static func ink(_ isDark: Bool) -> PlatformColor {
        isDark ? PlatformColor(white: 0.9, alpha: 1) : PlatformColor(white: 0.1, alpha: 1)
    }

    /// A `data:` image tag sized in **CSS pixels**, i.e. the image's point size.
    ///
    /// The bitmap is 2× or 3× on a retina device; writing the point size into
    /// `width`/`height` is what keeps it from drawing at double size — the same
    /// arithmetic `attachmentString` does for the editor's text attachment.
    private nonisolated static func imageTag(_ image: PlatformImage, class cls: String, alt: String) -> String? {
        guard let data = PlatformImageKit.pngData(image) else { return nil }
        let size = PlatformImageKit.size(of: image)
        guard size.width > 0, size.height > 0 else { return nil }
        let base64 = data.base64EncodedString()
        let escaped = alt
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
        return "<img class=\"\(cls)\" alt=\"\(escaped)\" "
            + "width=\"\(Int(size.width.rounded()))\" height=\"\(Int(size.height.rounded()))\" "
            + "src=\"data:image/png;base64,\(base64)\">"
    }
}

/// Rendered constructs, as the tags they became, keyed by what drew them.
///
/// **Bounded by size, and evicted by pass.** A diagram's tag is its PNG in
/// base64, which runs to hundreds of kilobytes, and a card's to megabytes — so
/// the budget counts bytes, keys included (a key carries the whole diagram or
/// formula it names, and one that drew nothing is all key). Each pass takes a
/// number (`beginPass`), and an entry is marked with the last pass that used
/// it; room is made by evicting the entries the oldest passes used, never one
/// the storing pass has. It evicted the oldest *stored* first, and a pass
/// visits a note's constructs in document order — so a note whose images
/// outgrew the budget evicted each one before the next pass reached it, and
/// every pass drew everything again. A pass whose own images outgrow the
/// budget keeps them, until a later pass needs the room.
nonisolated final class RenderedTags: @unchecked Sendable {
    private struct Entry {
        let tag: String
        /// What the tag was drawn from, when a key alone cannot say — a card,
        /// whose note can change under the same name. Held, so its identity
        /// cannot be taken by another object.
        let source: AnyObject?
        let bytes: Int
        var pass: Int
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var bytes = 0
    private var passes = 0
    let limit: Int

    init(limit: Int) { self.limit = limit }

    /// A number for a pass, later than every pass before it.
    func beginPass() -> Int { lock.withLock { passes += 1; return passes } }

    /// The tag kept for `key` — empty when what it names drew nothing — and,
    /// given a `source`, only if it was drawn from that object. A hit is
    /// `pass`'s to keep.
    func tag(for key: String, drawnFrom source: AnyObject? = nil, pass: Int = 0) -> String? {
        lock.withLock {
            guard var entry = entries[key] else { return nil }
            if let source, entry.source !== source { return nil }
            if pass > entry.pass {
                entry.pass = pass
                entries[key] = entry
            }
            return entry.tag
        }
    }

    func store(_ tag: String, for key: String, drawnFrom source: AnyObject? = nil, pass: Int = 0) {
        lock.withLock {
            let size = key.utf8.count + tag.utf8.count + 64
            if let old = entries.updateValue(Entry(tag: tag, source: source, bytes: size, pass: pass),
                                             forKey: key) {
                bytes -= old.bytes
            }
            bytes += size
            guard bytes > limit else { return }
            let evictable = entries.filter { $0.value.pass < pass }.sorted { $0.value.pass < $1.value.pass }
            for (evicted, entry) in evictable {
                guard bytes > limit else { break }
                entries[evicted] = nil
                bytes -= entry.bytes
            }
        }
    }

    var count: Int { lock.withLock { entries.count } }
    /// What the kept tags and their keys come to.
    var size: Int { lock.withLock { bytes } }
}
