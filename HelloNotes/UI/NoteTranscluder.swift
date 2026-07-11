//
//  NoteTranscluder.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(macOS)
import AppKit

/// Renders a note's Markdown to an image for inline transclusion (`![[Note]]`).
/// This is a lightweight preview renderer — headings, lists, blockquotes,
/// emphasis and code — not the full live editor (no LaTeX/Mermaid/callouts).
/// It draws a titled "card" with a left accent bar so a transclusion reads as
/// embedded content.
enum NoteTranscluder {
    private static let contentWidth: CGFloat = 560
    private static let padding: CGFloat = 14
    private static let barWidth: CGFloat = 3

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
        var inFence = false
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence {
                out.append(inline(line + "\n", font: mono, color: muted, plain: true))
                continue
            }
            if let (level, title) = headingParts(line) {
                let sizes: [CGFloat] = [20, 18, 16, 15, 14, 13]
                let font = NSFont.systemFont(ofSize: sizes[min(level - 1, 5)], weight: .bold)
                out.append(inline(title + "\n", font: font, color: textColor))
                continue
            }
            if let m = line.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) {
                out.append(inline("•  " + String(line[m.upperBound...]) + "\n", font: base, color: textColor))
                continue
            }
            if let m = line.range(of: #"^\s*>\s?"#, options: .regularExpression) {
                out.append(inline(String(line[m.upperBound...]) + "\n", font: base, color: muted))
                continue
            }
            out.append(inline(line + "\n", font: base, color: textColor))
        }
        return out
    }

    /// Strip `**bold**`, `*italic*`, `` `code` `` markers, applying traits.
    private static func inline(_ s: String, font: NSFont, color: NSColor, plain: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        guard !plain else { return result }
        applyTrait(#"\*\*(.+?)\*\*"#, to: result, base: font) { boldFont($0) }
        applyTrait(#"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#, to: result, base: font) { italicFont($0) }
        return result
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
