//
//  GFMPage.swift
//  GFMRender
//
//  Wraps GitHub-Flavored HTML in a self-contained page styled with GitHub's
//  own stylesheet (github-markdown-css), so a rendered note is visually
//  identical to how GitHub displays the same Markdown — light and dark.
//

import Foundation
import CoreGraphics
import MarkdownCore

public extension GFMRenderer {

    private static func escapedForTitle(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Rebind the stylesheet's colour variables to the host's, and stop it
    /// painting a canvas of its own. Written as variable overrides rather than
    /// as rules, so every place GitHub uses a colour — a heading's rule, a
    /// blockquote's bar, a table's grid — follows without needing to be listed.
    private static func paletteCSS(_ p: Palette) -> String {
        """
        .markdown-body {
          --fgColor-default: \(p.text);
          --color-fg-default: \(p.text);
          --fgColor-muted: \(p.muted);
          --color-fg-muted: \(p.muted);
          --fgColor-accent: \(p.accent);
          --color-accent-fg: \(p.accent);
          --bgColor-muted: \(p.codeBackground);
          --color-canvas-subtle: \(p.codeBackground);
          --bgColor-neutral-muted: \(p.inlineCodeBackground);
          --borderColor-default: \(p.border);
          --borderColor-muted: \(p.border);
          --color-border-default: \(p.border);
          --color-border-muted: \(p.border);
          --bgColor-default: \(p.canvas ?? "transparent");
          --color-canvas-default: \(p.canvas ?? "transparent");
          color: \(p.text);
          background-color: \(p.canvas ?? "transparent");
        }
        .markdown-body table tr { background-color: \(p.canvas ?? "transparent"); }
        """
    }

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

    /// How the page's own container is measured — everything outside the
    /// Markdown box model itself.
    ///
    /// Two shapes, because the page has two jobs. A *document* is saved,
    /// printed or shared: it wants generous margins and a centred measure, the
    /// way a README reads on github.com. A *pane* is the app's Preview mode,
    /// sitting in the same column the editor just occupied: it has to start
    /// where the editor's first glyph started and end where the editor's text
    /// ended, or toggling the mode slides the whole document sideways. That
    /// was the state of things — Preview was a 980px centred column and Edit
    /// was the full pane, so the very first thing a reader noticed on switching
    /// was that the text had moved.
    struct PageBox: Sendable, Equatable {
        public var top: CGFloat
        public var leading: CGFloat
        public var bottom: CGFloat
        public var trailing: CGFloat
        /// `nil` fills the viewport — what a pane does.
        public var maxWidth: CGFloat?

        public init(top: CGFloat, leading: CGFloat, bottom: CGFloat,
                    trailing: CGFloat, maxWidth: CGFloat?) {
            self.top = top; self.leading = leading
            self.bottom = bottom; self.trailing = trailing
            self.maxWidth = maxWidth
        }

        /// Saved / printed / shared HTML.
        public static let document = PageBox(top: 24, leading: 32, bottom: 48,
                                             trailing: 32, maxWidth: 980)

        /// Preview mode: the editor's own text insets, no measure of its own
        /// (the pane is already measured by the shell).
        public static func pane(inset: CGSize, leading: CGFloat) -> PageBox {
            PageBox(top: inset.height, leading: leading, bottom: inset.height,
                    trailing: leading, maxWidth: nil)
        }
    }

    /// The colours a page is painted in.
    ///
    /// Preview and Edit have to agree on more than geometry. GitHub's
    /// stylesheet paints its own canvas (`#0d1117` in dark) and its own text,
    /// link and border colours, none of which are the ones the editor draws
    /// with — so switching to Preview changed the colour of the page as well
    /// as, apparently, its layout. A pane hands its own palette in and paints
    /// nothing behind itself; a document keeps GitHub's, which is what makes an
    /// exported file look like a README.
    struct Palette: Sendable, Equatable {
        public var text: String
        public var muted: String
        public var accent: String
        public var codeBackground: String
        public var inlineCodeBackground: String
        public var border: String
        /// `nil` paints nothing — the host's own background shows through.
        public var canvas: String?

        public init(text: String, muted: String, accent: String,
                    codeBackground: String, inlineCodeBackground: String,
                    border: String, canvas: String?) {
            self.text = text; self.muted = muted; self.accent = accent
            self.codeBackground = codeBackground
            self.inlineCodeBackground = inlineCodeBackground
            self.border = border; self.canvas = canvas
        }

        /// The stylesheet's own colours, left to `prefers-color-scheme`.
        public static let github: Palette? = nil
    }

    /// A complete HTML page rendering `markdown` exactly as GitHub would.
    /// `baseURL` (the note's folder) lets relative image `src`s resolve.
    /// - Parameter fontScale: the app's text-scale setting. It sets the root
    ///   font size *and* every margin, because `GFMBoxMetrics` expresses the
    ///   stylesheet's px constants as multiples of it. Applied as a percentage
    ///   on `html` it did neither: `.markdown-body { font-size: 16px }` is
    ///   absolute and overrode it, so Text Size moved nothing on this surface
    ///   while it moved everything in the editor.
    /// - Parameter title: the document title, for a saved or printed file.
    /// - Parameter box: the container — `.document` to save or print,
    ///   `.pane` to sit flush with the editor it replaces.
    static func page(_ markdown: String, title: String = "", fontScale: Double = 1,
                     box: PageBox = .document, palette: Palette? = nil) -> String {
        let metrics = GFMBoxMetrics(base: 16 * CGFloat(fontScale))
        // GitHub-mode: hard line breaks, matching api.github.com/markdown.
        let body = html(markdown, hardBreaks: true)
        func px(_ v: CGFloat) -> String { String(format: "%.4f", Double(v)) + "px" }
        let measure = box.maxWidth.map { "max-width: \(px($0)); margin: 0 auto;" }
            ?? "max-width: none; margin: 0;"
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        \(title.isEmpty ? "" : "<title>\(escapedForTitle(title))</title>")
        <style>
        \(githubCSS)
        </style>
        <style>@media (prefers-color-scheme: light) { \(highlightCSSLight) }</style>
        <style>@media (prefers-color-scheme: dark) { \(highlightCSSDark) }</style>
        <style>
        html { -webkit-text-size-adjust: 100%; }
        body { margin: 0; background: \(palette?.canvas ?? "var(--bgColor-default, var(--color-canvas-default, transparent))"); }
        .markdown-body {
          box-sizing: border-box;
          min-width: 200px;
          \(measure)
          padding: \(px(box.top)) \(px(box.trailing)) \(px(box.bottom)) \(px(box.leading));
        }
        img { background: transparent; }
        /* highlight.js paints spans; keep GitHub's code-block box from the md css. */
        .markdown-body pre code.hljs { padding: 0; background: transparent; }
        </style>
        <style>
        /* The shared box model — see MarkdownCore/GFMBoxMetrics.swift. Every
           number below is the one the live editor lays out with. */
        \(metrics.css)
        \(palette.map(paletteCSS) ?? "")
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
