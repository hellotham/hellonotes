//
//  MarkdownExport.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import Foundation
import Markdown

/// Converts a note's Markdown to other formats for export. `nonisolated` —
/// pure string transformation, callable from any actor.
nonisolated enum MarkdownExport {

    /// Render `markdown` to a self-contained, styled HTML document. `fontScale`
    /// multiplies the root font size to honour the app's Text Size setting.
    static func html(from markdown: String, title: String, fontScale: Double = 1) -> String {
        let body = HTMLFormatter.format(markdown)
        let rootFontPercent = Int((fontScale * 100).rounded())
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escaped(title))</title>
        <style>
        :root { color-scheme: light dark; font-size: \(rootFontPercent)%; }
        body {
          font: -apple-system-body, system-ui, sans-serif;
          max-width: 44rem; margin: 2rem auto; padding: 0 1.25rem;
          line-height: 1.6;
        }
        h1, h2, h3, h4 { line-height: 1.25; }
        pre { background: rgba(127,127,127,0.12); padding: 0.75rem 1rem; border-radius: 8px; overflow-x: auto; }
        code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.9em; }
        pre code { font-size: 0.85em; }
        blockquote { border-left: 3px solid rgba(127,127,127,0.4); margin: 0; padding-left: 1rem; color: #666; }
        table { border-collapse: collapse; }
        th, td { border: 1px solid rgba(127,127,127,0.4); padding: 0.35rem 0.6rem; }
        img { max-width: 100%; }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    private static func escaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
