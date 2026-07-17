//
//  GitHubAPIParityTests.swift
//  GFMRenderTests
//
//  Proves GFMRenderer's output is identical to GitHub's `POST /markdown`
//  (mode: gfm) on a comprehensive document covering the whole GFM surface.
//  The expected HTML is a captured response from api.github.com/markdown
//  (2026-07-17). GitHub layers a few cosmetic/security transforms on top of
//  cmark-gfm's HTML — `rel="nofollow"`, a table a11y wrapper, task-list CSS
//  classes — which are normalised away here; everything else must match
//  byte-for-byte.
//

import Foundation
import Testing
@testable import GFMRender

@Suite struct GitHubAPIParityTests {

    /// Strip GitHub's post-cmark cosmetic/security/display additions so the
    /// remaining HTML is exactly what cmark-gfm (and therefore GFMRenderer)
    /// emits: `rel="nofollow"`, the table a11y wrapper, task-list CSS classes,
    /// `notranslate` hints, and Primer syntax-highlighting of code blocks.
    static func stripGitHubChrome(_ html: String) -> String {
        var s = html
        for token in [
            " rel=\"nofollow\"",
            "<markdown-accessiblity-table>",
            "</markdown-accessiblity-table>",
            " class=\"contains-task-list\"",
            " class=\"task-list-item\"",
            " class=\"task-list-item-checkbox\"",
            " class=\"notranslate\"",
            " id=\"\"",
            " aria-label=\"Incomplete task\"",
            " aria-label=\"Completed task\"",
        ] {
            s = s.replacingOccurrences(of: token, with: "")
        }
        s = s.replacingOccurrences(of: "<table role=\"table\">", with: "<table>")
        s = unhighlight(s)
        s = canonicalCheckboxes(s)
        return s
    }

    /// Convert GitHub's Primer-highlighted code block back to cmark's plain
    /// `<pre><code class="language-X">…</code></pre>` form (strip the wrapper
    /// div and the `<span class="pl-…">` colour spans; keep the escaped text).
    static func unhighlight(_ html: String) -> String {
        var s = html
        let block = /<div class="highlight highlight-source-([\w-]+)"><pre>(.*?)<\/pre><\/div>/
            .dotMatchesNewlines()
        s = s.replacing(block) { m in
            let lang = String(m.1)
            let inner = String(m.2)
                .replacing(/<span class="pl-[^"]*">/, with: "")
                .replacingOccurrences(of: "</span>", with: "")
            return "<pre><code class=\"language-\(lang)\">\(inner)\n</code></pre>"
        }
        return s
    }

    /// Normalise `<input ... type=checkbox ...>` to `checkbox|checkbox-checked`
    /// regardless of attribute order/spacing, on either renderer's output.
    static func canonicalCheckboxes(_ html: String) -> String {
        var s = html
        while let r = s.range(of: "<input", options: []),
              let end = s[r.lowerBound...].range(of: ">") {
            let tag = String(s[r.lowerBound...end.lowerBound])
            let token = tag.contains("checked") ? "‹checkbox-checked›" : "‹checkbox›"
            s.replaceSubrange(r.lowerBound...end.lowerBound, with: token)
        }
        return s
    }

    /// Canonicalise equivalent serialisations so cmark's XHTML-style void tags
    /// and quote-escaping compare equal to GitHub's HTML5 style.
    static func canon(_ s: String) -> String {
        s.replacingOccurrences(of: " />", with: ">")      // <br /> → <br>, <hr /> → <hr>
            .replacingOccurrences(of: "&quot;", with: "\"") // "-in-text needs no escape
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func identicalToGitHubMarkdownAPI() throws {
        let mdURL = try #require(Bundle.module.url(forResource: "github-parity-input", withExtension: "md"))
        let htmlURL = try #require(Bundle.module.url(forResource: "github-parity-expected", withExtension: "html"))
        let markdown = try String(contentsOf: mdURL, encoding: .utf8)
        let githubHTML = try String(contentsOf: htmlURL, encoding: .utf8)

        // GitHub-mode render (hard line breaks), matching the API.
        let ours = Self.canon(Self.canonicalCheckboxes(GFMRenderer.html(markdown, hardBreaks: true)))
        let github = Self.canon(Self.stripGitHubChrome(githubHTML))

        if ours != github {
            let a = ours.components(separatedBy: "\n")
            let b = github.components(separatedBy: "\n")
            print("--- first differing lines (ours | github) ---")
            var shown = 0
            for i in 0..<max(a.count, b.count) where shown < 15 {
                let la = i < a.count ? a[i] : "∅"
                let lb = i < b.count ? b[i] : "∅"
                if la != lb { print("L\(i):\n  ours:   \(la.debugDescription)\n  github: \(lb.debugDescription)"); shown += 1 }
            }
        }
        #expect(ours == github, "GFMRenderer output differs from the GitHub markdown API")
    }
}
