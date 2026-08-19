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

    private static func resource(_ name: String, _ ext: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return s
    }

    /// GitHub's markdown stylesheet (auto light/dark via prefers-color-scheme).
    static let githubCSS: String = resource("github-markdown", "css")

    /// highlight.js + GitHub's light/dark code themes, giving code blocks the
    /// same colouring GitHub applies.
    static let highlightJS: String = resource("highlight.min", "js")
    static let highlightCSSLight: String = resource("hljs-github", "css")
    static let highlightCSSDark: String = resource("hljs-github-dark", "css")

    /// A complete HTML page rendering `markdown` exactly as GitHub would.
    /// `baseURL` (the note's folder) lets relative image `src`s resolve.
    /// - Parameter fontScale: the app's text-scale setting, applied at the
    ///   root so GitHub's own type scale stays proportional.
    static func page(_ markdown: String, fontScale: Double = 1) -> String {
        // GitHub-mode: hard line breaks, matching api.github.com/markdown.
        let body = html(markdown, hardBreaks: true)
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
        <style>@media (prefers-color-scheme: light) { \(highlightCSSLight) }</style>
        <style>@media (prefers-color-scheme: dark) { \(highlightCSSDark) }</style>
        <style>
        html { -webkit-text-size-adjust: 100%; font-size: \(Int((fontScale * 100).rounded()))%; }
        body { margin: 0; background: var(--bgColor-default, var(--color-canvas-default, transparent)); }
        .markdown-body {
          box-sizing: border-box;
          min-width: 200px;
          max-width: 980px;
          margin: 0 auto;
          padding: 24px 32px 48px;
        }
        img { background: transparent; }
        /* highlight.js paints spans; keep GitHub's code-block box from the md css. */
        .markdown-body pre code.hljs { padding: 0; background: transparent; }
        </style>
        </head>
        <body>
        <article class="markdown-body">
        \(body)
        </article>
        <script>\(highlightJS)</script>
        <script>
        document.querySelectorAll('pre code[class^="language-"]').forEach(function (el) {
          try { hljs.highlightElement(el); } catch (e) {}
        });
        </script>
        </body>
        </html>
        """
    }
}
