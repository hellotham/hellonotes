//
//  SmartPaste.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Smart-paste conversions: rich text (HTML) → Markdown, and a pasted URL →
//  a Markdown link. Title lookup for a pasted URL happens asynchronously (see
//  `fetchTitle`); the caret gets a link immediately and the visible text is
//  upgraded to the page title when it arrives.
//

#if os(macOS)
import AppKit

enum SmartPaste {

    // MARK: - URL

    /// If the pasteboard holds a single bare http(s) URL, the Markdown link to
    /// insert (title = the URL, upgraded later) and the URL itself.
    static func urlLink(from pasteboard: NSPasteboard) -> (markdown: String, url: URL)? {
        guard let raw = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, !raw.contains(where: { $0.isWhitespace }),
              let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return ("[\(raw)](\(raw))", url)
    }

    /// Fetch a web page's `<title>`, cleaned for use as link text.
    static func fetchTitle(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh) HelloNotes", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return title(fromHTML: html)
    }

    /// Extract and clean the `<title>` from an HTML document, ready to use as
    /// Markdown link text.
    static func title(fromHTML html: String) -> String? {
        guard let match = html.range(of: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        var title = String(html[match])
            .replacingOccurrences(of: #"</?title[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        title = decodeEntities(title).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Markdown link text can't contain ] — escape it.
        title = title.replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "[", with: "\\[")
        return title.isEmpty ? nil : title
    }

    // MARK: - Rich text (HTML) → Markdown

    /// Convert pasteboard HTML rich text to Markdown, or `nil` when the HTML has
    /// no meaningful formatting (so the plain-text paste is preserved verbatim).
    static func markdownFromHTML(_ pasteboard: NSPasteboard) -> String? {
        guard let html = pasteboard.string(forType: .html), hasFormatting(html),
              let data = html.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil) else { return nil }
        let markdown = fromAttributed(attributed)
        return markdown.isEmpty ? nil : markdown
    }

    private static func hasFormatting(_ html: String) -> Bool {
        let tags = ["<a ", "<strong", "<b>", "<b ", "<em", "<i>", "<i ", "<h1", "<h2", "<h3",
                    "<h4", "<h5", "<h6", "<ul", "<ol", "<li", "<code", "<pre", "<blockquote"]
        let lower = html.lowercased()
        return tags.contains { lower.contains($0) }
    }

    private static func fromAttributed(_ attr: NSAttributedString) -> String {
        let ns = attr.string as NSString
        var lines: [String] = []

        // Walk paragraph by paragraph (paragraphs are separated by \n).
        var start = 0
        while start < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: start, length: 0))
            let paragraph = attr.attributedSubstring(from: lineRange)
            let text = inlineMarkdown(paragraph).trimmingCharacters(in: .whitespacesAndNewlines)

            if !text.isEmpty {
                let style = attr.attribute(.paragraphStyle, at: lineRange.location, effectiveRange: nil) as? NSParagraphStyle
                let textLists = style?.textLists ?? []
                // AppKit's HTML import embeds the list marker ("\t•\t", "1.\t") in
                // the text; a paragraph is a list item if it has a text list or a
                // leading marker glyph.
                let markerPattern = #"^[ \t]*([•‣◦·\-\*]|\d+[.)])[ \t]+"#
                let hasMarker = text.range(of: markerPattern, options: .regularExpression) != nil

                if !textLists.isEmpty || hasMarker {
                    var content = text
                    if let r = content.range(of: markerPattern, options: .regularExpression) {
                        content.removeSubrange(r)
                    }
                    let ordered = textLists.last.map(isOrdered) ?? false
                        || text.range(of: #"^[ \t]*\d+[.)]"#, options: .regularExpression) != nil
                    let level = max(1, textLists.count)
                    let indent = String(repeating: "  ", count: level - 1)
                    lines.append(indent + (ordered ? "1. " : "- ") + content.trimmingCharacters(in: .whitespaces))
                } else if let level = headingLevel(of: paragraph) {
                    // A heading line is already emphasised by being a heading —
                    // don't also bold/italic-wrap its text.
                    let headingText = inlineMarkdown(paragraph, suppressEmphasis: true)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    lines.append(String(repeating: "#", count: level) + " " + headingText)
                } else {
                    lines.append(text)
                }
            } else {
                lines.append("")
            }
            start = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }

        // Collapse 3+ blank lines and join.
        let joined = lines.joined(separator: "\n")
        return joined
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func isOrdered(_ list: NSTextList) -> Bool {
        let f = list.markerFormat.rawValue.lowercased()
        return f.contains("decimal") || f.contains("%d") || f.contains("roman") || f.contains("alpha")
    }

    /// Heading level from the paragraph's dominant font size relative to a 13pt
    /// body baseline, when the text is also bold. Browsers export h1–h6 that way.
    private static func headingLevel(of paragraph: NSAttributedString) -> Int? {
        guard paragraph.length > 0,
              let font = paragraph.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else { return nil }
        let bold = font.fontDescriptor.symbolicTraits.contains(.bold)
        let ratio = font.pointSize / 13.0
        guard bold || ratio >= 1.3 else { return nil }
        switch ratio {
        case 1.8...: return 1
        case 1.5..<1.8: return 2
        case 1.3..<1.5: return 3
        case 1.15..<1.3 where bold: return 4
        default: return nil
        }
    }

    /// Convert a single paragraph's runs to inline Markdown (bold, italic, code,
    /// links).
    private static func inlineMarkdown(_ paragraph: NSAttributedString, suppressEmphasis: Bool = false) -> String {
        let ns = paragraph.string as NSString
        var out = ""
        paragraph.enumerateAttributes(in: NSRange(location: 0, length: ns.length)) { attrs, range, _ in
            let raw = ns.substring(with: range)
            if raw.isEmpty { return }

            if let link = attrs[.link] {
                let href = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if href.isEmpty || label.isEmpty { out += raw }
                else { out += "[\(label)](\(href))" }
                return
            }

            let font = attrs[.font] as? NSFont
            if font?.isFixedPitch == true {
                out += "`\(raw.trimmingCharacters(in: .whitespaces))`"
                return
            }
            if suppressEmphasis {
                out += raw
                return
            }
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            out += wrap(raw, bold: traits.contains(.bold), italic: traits.contains(.italic))
        }
        return out
    }

    /// Wrap `text` in emphasis markers, keeping leading/trailing spaces outside
    /// the markers (so `**bold** ` not `** bold **`).
    private static func wrap(_ text: String, bold: Bool, italic: Bool) -> String {
        guard bold || italic else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return text }
        let leading = String(text.prefix(while: { $0 == " " }))
        let trailing = String(text.reversed().prefix(while: { $0 == " " }))
        let marker = bold && italic ? "***" : (bold ? "**" : "*")
        return leading + marker + trimmed + marker + trailing
    }

    private static func decodeEntities(_ s: String) -> String {
        var out = s
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
                   "&apos;": "'", "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…"]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }
}
#endif
