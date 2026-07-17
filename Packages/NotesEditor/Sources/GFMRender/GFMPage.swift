//
//  GFMPage.swift
//  GFMRender
//
//  Wraps GitHub-Flavored HTML in a self-contained page styled with GitHub's
//  own stylesheet (github-markdown-css), so a rendered note is visually
//  identical to how GitHub displays the same Markdown — light and dark.
//

import Foundation

public extension GFMRenderer {

    /// GitHub's markdown stylesheet (auto light/dark via prefers-color-scheme).
    static let githubCSS: String = {
        guard let url = Bundle.module.url(forResource: "github-markdown", withExtension: "css"),
              let css = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return css
    }()

    /// A complete HTML page rendering `markdown` exactly as GitHub would.
    /// `baseURL` (the note's folder) lets relative image `src`s resolve.
    static func page(_ markdown: String) -> String {
        let body = html(markdown)
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <style>
        \(githubCSS)
        </style>
        <style>
        html { -webkit-text-size-adjust: 100%; }
        body { margin: 0; background: var(--bgColor-default, var(--color-canvas-default, transparent)); }
        .markdown-body {
          box-sizing: border-box;
          min-width: 200px;
          max-width: 980px;
          margin: 0 auto;
          padding: 24px 32px 48px;
        }
        img { background: transparent; }
        </style>
        </head>
        <body>
        <article class="markdown-body">
        \(body)
        </article>
        </body>
        </html>
        """
    }
}
