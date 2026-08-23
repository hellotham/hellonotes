//
//  GitHubMarkdown.swift
//  HelloNotes
//
//  Bridges a HelloNotes note to plain GitHub-Flavored Markdown for the
//  GitHub-fidelity preview: strips YAML front matter and rewrites the
//  Obsidian-only constructs (wiki links, embeds) into standard Markdown that
//  cmark-gfm understands.
//
//  The rewrite itself now lives in the package, as `GFMRender.NoteMarkdown` —
//  it is part of the answer to "what does Preview show", and `RenderParity`
//  has to be able to ask the same question the app does. While it lived here
//  the parity sweep could not reach it: it rendered its preview from the raw
//  note, drew the literal characters `![[foo]]` where the editor drew the
//  embed, and named the difference a divergence the editor would never close.
//  Nothing was wrong with either surface — the harness was measuring a page
//  the app never builds.
//

import Foundation
import GFMRender

enum GitHubMarkdown {

    /// Prepare `text` (a full note) for GitHub-identical rendering.
    static func prepare(_ text: String) -> String { NoteMarkdown.prepare(text) }
}
