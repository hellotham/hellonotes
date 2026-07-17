//
//  NoteTranscluder.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(macOS)
import AppKit
import BeautifulMermaid

/// Renders a note's Markdown to an image for inline transclusion (`![[Note]]`).
/// A lightweight preview renderer — headings, lists, blockquotes, emphasis,
/// code, plus rendered LaTeX (`$…$` / `$$…$$`) and Mermaid diagrams — drawn as
/// a titled "card" with a left accent bar so a transclusion reads as embedded
/// content.
@MainActor
enum NoteTranscluder {
    private static let contentWidth: CGFloat = 560
    private static let padding: CGFloat = 14
    private static let barWidth: CGFloat = 3
    private static var textContentWidth: CGFloat { contentWidth - padding * 2 - barWidth }

    /// Render a `$$ … $$` display-math block to an image for the new editor.
    static func blockLatexImage(source: String, isDark: Bool) -> NSImage? {
        latexImage(source, fontSize: 20, isDark: isDark)
    }

    static func image(markdown: String, title: String, isDark: Bool) -> NSImage? {
        let body = attributedBody(from: markdown, isDark: isDark)
        guard body.length > 0 else { return nil }

        let textColor: NSColor = isDark ? .white : .black
        let header = NSMutableAttributedString(
            string: title + "\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        let composed = NSMutableAttributedString()
        composed.append(header)
        composed.append(body)

        let textWidth = contentWidth - padding * 2 - barWidth
        let bounds = composed.boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let height = ceil(bounds.height) + padding * 2
        let size = NSSize(width: contentWidth, height: height)

        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        // Card background + left accent bar.
        let cardColor: NSColor = isDark
            ? NSColor.white.withAlphaComponent(0.05)
            : NSColor.black.withAlphaComponent(0.03)
        cardColor.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 6, yRadius: 6).fill()
        NSColor.systemBlue.withAlphaComponent(0.7).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: barWidth, height: height)).fill()

        _ = textColor
        composed.draw(
            with: NSRect(x: padding + barWidth, y: padding, width: textWidth, height: ceil(bounds.height)),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return image
    }

    /// Extract the section under `heading` (down to the next heading of the same
    /// or higher level). Returns the whole text if `heading` is nil/not found.
    static func section(_ heading: String?, from markdown: String) -> String {
        guard let heading, !heading.isEmpty else { return markdown }
        let lines = markdown.components(separatedBy: "\n")
        var startIndex: Int?
        var startLevel = 0
        for (i, line) in lines.enumerated() {
            if let (level, title) = headingParts(line),
               title.compare(heading, options: .caseInsensitive) == .orderedSame {
                startIndex = i
                startLevel = level
                break
            }
        }
        guard let start = startIndex else { return markdown }
        var end = lines.count
        for i in (start + 1)..<lines.count {
            if let (level, _) = headingParts(lines[i]), level <= startLevel {
                end = i
                break
            }
        }
        return lines[start..<end].joined(separator: "\n")
    }

    // MARK: - Lightweight Markdown → attributed string

    private static func attributedBody(from markdown: String, isDark: Bool) -> NSAttributedString {
        let text = FrontMatter.body(of: markdown)   // skip the note's own front matter
        let base = NSFont.systemFont(ofSize: 13)
        let textColor: NSColor = isDark ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.1, alpha: 1)
        let muted = NSColor.secondaryLabelColor
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        let out = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced block: ```mermaid renders a diagram, others stay as code.
            if trimmed.hasPrefix("```") {
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[i]); i += 1
                }
                i += 1   // skip closing fence
                let source = body.joined(separator: "\n")
                if lang == "mermaid", let img = mermaidImage(source, isDark: isDark) {
                    out.append(imageAttachment(img, maxWidth: textContentWidth))
                    out.append(NSAttributedString(string: "\n"))
                } else {
                    out.append(inline(source + "\n", font: mono, color: muted, isDark: isDark, plain: true))
                }
                continue
            }

            // Block LaTeX `$$ … $$`.
            if trimmed == "$$" {
                var body: [String] = []
                i += 1
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "$$" {
                    body.append(lines[i]); i += 1
                }
                i += 1
                if let img = latexImage(body.joined(separator: "\n"), fontSize: 16, isDark: isDark) {
                    out.append(imageAttachment(img, maxWidth: textContentWidth))
                    out.append(NSAttributedString(string: "\n"))
                }
                continue
            }

            if let (level, title) = headingParts(line) {
                let sizes: [CGFloat] = [20, 18, 16, 15, 14, 13]
                let font = NSFont.systemFont(ofSize: sizes[min(level - 1, 5)], weight: .bold)
                out.append(inline(title + "\n", font: font, color: textColor, isDark: isDark))
            } else if let m = line.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) {
                out.append(inline("•  " + String(line[m.upperBound...]) + "\n", font: base, color: textColor, isDark: isDark))
            } else if let m = line.range(of: #"^\s*>\s?"#, options: .regularExpression) {
                out.append(inline(String(line[m.upperBound...]) + "\n", font: base, color: muted, isDark: isDark))
            } else {
                out.append(inline(line + "\n", font: base, color: textColor, isDark: isDark))
            }
            i += 1
        }
        return out
    }

    /// Apply `**bold**`, `*italic*` traits and render inline `$latex$`.
    private static func inline(_ s: String, font: NSFont, color: NSColor, isDark: Bool, plain: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        guard !plain else { return result }
        // Inline LaTeX first (before emphasis, so `$…$` content isn't mangled).
        applyInlineLatex(to: result, fontSize: font.pointSize, isDark: isDark)
        applyTrait(#"\*\*(.+?)\*\*"#, to: result, base: font) { boldFont($0) }
        applyTrait(#"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#, to: result, base: font) { italicFont($0) }
        return result
    }

    private static func applyInlineLatex(to str: NSMutableAttributedString, fontSize: CGFloat, isDark: Bool) {
        guard let regex = try? NSRegularExpression(pattern: #"(?<!\$)\$(?!\$)(.+?)(?<!\$)\$(?!\$)"#) else { return }
        let full = str.string
        let matches = regex.matches(in: full, range: NSRange(full.startIndex..., in: full)).reversed()
        for m in matches where m.numberOfRanges >= 2 {
            let latexSrc = (str.string as NSString).substring(with: m.range(at: 1))
            guard let img = latexImage(latexSrc, fontSize: fontSize, isDark: isDark) else { continue }
            str.replaceCharacters(in: m.range, with: attachmentString(img, maxWidth: textContentWidth))
        }
    }

    private static func applyTrait(_ pattern: String, to str: NSMutableAttributedString, base: NSFont, transform: (NSFont) -> NSFont) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let full = str.string
        let matches = regex.matches(in: full, range: NSRange(full.startIndex..., in: full)).reversed()
        for m in matches where m.numberOfRanges >= 2 {
            let inner = (str.string as NSString).substring(with: m.range(at: 1))
            str.replaceCharacters(in: m.range, with: inner)
            str.addAttribute(.font, value: transform(base), range: NSRange(location: m.range.location, length: (inner as NSString).length))
        }
    }

    // MARK: - Embedded images (LaTeX / Mermaid)

    @MainActor
    private static func latexImage(_ source: String, fontSize: CGFloat, isDark: Bool) -> NSImage? {
        let color: NSColor = isDark ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.1, alpha: 1)
        return MathImageRenderer.image(latex: source, fontSize: fontSize, color: color)
    }

    private static func mermaidImage(_ source: String, isDark: Bool) -> NSImage? {
        let diagramTheme = (isDark ? DiagramTheme.zincDark : DiagramTheme.zincLight).withTransparent()
        guard let rendered = (try? MermaidRenderer.renderImage(source: source, theme: diagramTheme)) ?? nil,
              rendered.size.width > 0, rendered.size.height > 0 else { return nil }
        // BeautifulMermaid draws bottom-left origin; flip to display upright.
        let size = rendered.size
        let flipped = NSImage(size: size)
        flipped.lockFocus()
        let t = NSAffineTransform()
        t.translateX(by: 0, yBy: size.height); t.scaleX(by: 1, yBy: -1); t.concat()
        rendered.draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1)
        flipped.unlockFocus()
        return flipped
    }

    /// A standalone (block) image line scaled to fit `maxWidth`.
    private static func imageAttachment(_ image: NSImage, maxWidth: CGFloat) -> NSAttributedString {
        attachmentString(image, maxWidth: maxWidth)
    }

    private static func attachmentString(_ image: NSImage, maxWidth: CGFloat) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image
        var size = image.size
        if size.width > maxWidth {
            let scale = maxWidth / size.width
            size = NSSize(width: maxWidth, height: size.height * scale)
        }
        attachment.bounds = CGRect(origin: .zero, size: size)
        return NSAttributedString(attachment: attachment)
    }

    private static func boldFont(_ f: NSFont) -> NSFont {
        let d = f.fontDescriptor.symbolicTraits.union(.bold)
        return NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(d), size: f.pointSize) ?? f
    }
    private static func italicFont(_ f: NSFont) -> NSFont {
        let d = f.fontDescriptor.symbolicTraits.union(.italic)
        return NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(d), size: f.pointSize) ?? f
    }

    private static func headingParts(_ line: String) -> (level: Int, title: String)? {
        guard let m = line.range(of: #"^(#{1,6})\s+"#, options: .regularExpression) else { return nil }
        let hashes = line[line.startIndex..<m.upperBound].filter { $0 == "#" }.count
        let title = String(line[m.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (hashes, title)
    }
}
#endif
