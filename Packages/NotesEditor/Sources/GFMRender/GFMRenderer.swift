//
//  GFMRenderer.swift
//  GFMRender
//
//  GitHub-identical Markdown → HTML. Uses cmark-gfm — the exact library
//  GitHub renders Markdown with — so output matches GitHub's `POST /markdown`
//  endpoint and passes the GFM specification's conformance corpus.
//
//  The five GFM extensions (table, strikethrough, autolink, tagfilter,
//  tasklist) are the ones the GFM spec is defined against; enabling them is
//  what makes the output GitHub-Flavored rather than plain CommonMark.
//

import Foundation
import cmark_gfm
import cmark_gfm_extensions

public enum GFMRenderer {

    /// The GFM extensions, in the order GitHub / the spec test registers them.
    private static let extensions = ["table", "strikethrough", "autolink", "tagfilter", "tasklist"]

    /// Render `markdown` to HTML exactly as GitHub-Flavored Markdown does.
    ///
    /// `unsafe` mirrors GitHub's rendering of raw HTML: the GFM spec corpus is
    /// generated with raw HTML passed through (then tag-filtered), so spec
    /// conformance needs it on.
    ///
    /// `hardBreaks` renders every soft line break as `<br>`. The `POST
    /// /markdown` API does this (comment-style breaks), so the *preview* uses
    /// it to match GitHub; the *spec* corpus does not, so conformance leaves
    /// it off.
    public static func html(_ markdown: String, unsafe: Bool = true, hardBreaks: Bool = false) -> String {
        cmark_gfm_core_extensions_ensure_registered()

        var options = CMARK_OPT_DEFAULT
        if unsafe { options |= CMARK_OPT_UNSAFE }
        if hardBreaks { options |= CMARK_OPT_HARDBREAKS }

        guard let parser = cmark_parser_new(options) else { return "" }
        defer { cmark_parser_free(parser) }

        for name in extensions {
            if let ext = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, ext)
            }
        }

        let bytes = Array(markdown.utf8)
        bytes.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                base.withMemoryRebound(to: CChar.self, capacity: buf.count) { cbuf in
                    cmark_parser_feed(parser, cbuf, buf.count)
                }
            }
        }

        guard let doc = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(doc) }

        let exts = cmark_parser_get_syntax_extensions(parser)
        guard let htmlC = cmark_render_html(doc, options, exts) else { return "" }
        defer { free(htmlC) }
        return String(cString: htmlC)
    }
}
