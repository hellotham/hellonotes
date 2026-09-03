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
import MarkdownEditor
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@MainActor
enum PreviewSuperset {

    /// Substitute the note-dialect constructs Preview cannot otherwise draw,
    /// returning Markdown that is now plain GFM plus a few `<img>` tags.
    ///
    /// - Parameter embeds: resolves `![[target]]` to a rendered card. `nil`
    ///   leaves embeds to `NoteMarkdown`, which turns them into links.
    static func apply(to text: String,
                      isDark: Bool,
                      embeds: CollectionEmbedProvider?) async -> String {
        var out: [String] = []
        var fence: String?
        var mermaid: [String]?          // body of an open ```mermaid fence
        var mathBlock: [String]?

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Inside a ```mermaid fence: collect, then draw it.
            if mermaid != nil {
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    let source = (mermaid ?? []).joined(separator: "\n")
                    mermaid = nil
                    out.append(diagram(source, isDark: isDark)
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
                    out.append(blockMath(source, isDark: isDark) ?? "$$\(source)$$")
                } else {
                    mathBlock?.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                // A diagram is the one fence whose *contents* are drawn rather
                // than shown. Everything else — including a fence that merely
                // quotes Mermaid source — stays code.
                let info = trimmed.drop(while: { $0 == "`" || $0 == "~" })
                    .trimmingCharacters(in: .whitespaces).lowercased()
                if info == "mermaid" {
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
                    out.append(blockMath(source, isDark: isDark) ?? line)
                } else {
                    mathBlock = body.isEmpty ? [] : [body]
                }
                continue
            }

            out.append(await inlineConstructs(line, isDark: isDark, embeds: embeds))
        }

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
                                         embeds: CollectionEmbedProvider?) async -> String {
        guard line.contains("$") || line.contains("![[") else { return line }
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
                out += await substitute(String(line[start..<idx]), isDark: isDark, embeds: embeds)
            }
        }
        return out
    }

    private static func substitute(_ segment: String,
                                   isDark: Bool,
                                   embeds: CollectionEmbedProvider?) async -> String {
        var s = segment
        if s.contains("![["), let embeds {
            s = await replaceEmbeds(in: s, isDark: isDark, embeds: embeds)
        }
        if s.contains("$") {
            s = inlineMath(in: s, isDark: isDark)
        }
        return s
    }

    /// `![[target]]` / `![[target#heading]]` → the rendered card.
    private static func replaceEmbeds(in segment: String,
                                      isDark: Bool,
                                      embeds: CollectionEmbedProvider) async -> String {
        let pattern = /!\[\[([^\]|]+)(?:\|[^\]]+)?\]\]/
        var out = ""
        var rest = Substring(segment)
        while let match = try? pattern.firstMatch(in: rest) {
            out += rest[rest.startIndex..<match.range.lowerBound]
            let target = String(match.1).trimmingCharacters(in: .whitespaces)
            if let image = await embeds.image(forName: target, isDark: isDark),
               let tag = imageTag(image, class: "hn-embed", alt: target) {
                out += tag
            } else {
                out += String(rest[match.range])   // unresolved: leave it visible
            }
            rest = rest[match.range.upperBound...]
        }
        return out + rest
    }

    /// `$…$` → an inline image, sized and baseline-shifted so it sits in the
    /// line rather than on top of it.
    private static func inlineMath(in segment: String, isDark: Bool) -> String {
        let pattern = /\$([^$\n]+)\$/
        var out = ""
        var rest = Substring(segment)
        while let match = try? pattern.firstMatch(in: rest) {
            out += rest[rest.startIndex..<match.range.lowerBound]
            let source = String(match.1)
            if let image = MathImageRenderer.image(latex: source, fontSize: 16, color: ink(isDark)),
               let tag = imageTag(image, class: "hn-math-inline", alt: source) {
                out += tag
            } else {
                out += String(rest[match.range])
            }
            rest = rest[match.range.upperBound...]
        }
        return out + rest
    }

    private static func blockMath(_ source: String, isDark: Bool) -> String? {
        guard let image = MathImageRenderer.image(latex: source, fontSize: 20, color: ink(isDark)),
              let tag = imageTag(image, class: "hn-math-block", alt: source)
        else { return nil }
        return "<p class=\"hn-math-wrap\">\(tag)</p>"
    }

    /// A ```mermaid fence → the rendered diagram, as the editor draws it.
    private static func diagram(_ source: String, isDark: Bool) -> String? {
        guard let image = MermaidDiagramRenderer.standaloneImage(source: source, isDark: isDark),
              let tag = imageTag(image, class: "hn-diagram", alt: "diagram")
        else { return nil }
        return "<p class=\"hn-diagram-wrap\">\(tag)</p>"
    }

    private static func ink(_ isDark: Bool) -> PlatformColor {
        isDark ? PlatformColor(white: 0.9, alpha: 1) : PlatformColor(white: 0.1, alpha: 1)
    }

    /// A `data:` image tag sized in **CSS pixels**, i.e. the image's point size.
    ///
    /// The bitmap is 2× or 3× on a retina device; writing the point size into
    /// `width`/`height` is what keeps it from drawing at double size — the same
    /// arithmetic `attachmentString` does for the editor's text attachment.
    private static func imageTag(_ image: PlatformImage, class cls: String, alt: String) -> String? {
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
