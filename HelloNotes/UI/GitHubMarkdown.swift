//
//  GitHubMarkdown.swift
//  HelloNotes
//
//  Bridges a HelloNotes note to plain GitHub-Flavored Markdown for the
//  GitHub-fidelity preview: strips YAML front matter and rewrites the
//  Obsidian-only constructs (wiki links, embeds) into standard Markdown that
//  cmark-gfm understands. Everything else is already GFM and passes through
//  untouched. Code fences/spans are left verbatim.
//

import Foundation

enum GitHubMarkdown {

    /// Prepare `text` (a full note) for GitHub-identical rendering.
    static func prepare(_ text: String) -> String {
        let body = FrontMatter.body(of: text)
        var out: [String] = []
        var fence: String? = nil          // the open ``` / ~~~ run, if any
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let f = fence {
                out.append(line)
                if trimmed.hasPrefix(f) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(while: { $0 == "`" || $0 == "~" }))
                out.append(line)
                continue
            }
            out.append(rewriteWikiConstructs(line))
        }
        return out.joined(separator: "\n")
    }

    /// `![[embed]]` → `![](embed)`, `[[target|alias]]` → `[alias](target)`.
    private static func rewriteWikiConstructs(_ line: String) -> String {
        var s = line
        s = s.replacing(embedRegex) { match in
            "![](" + encode(String(match.1)) + ")"
        }
        s = s.replacing(wikiRegex) { match in
            let target = String(match.1)
            let alias = match.2.map(String.init) ?? target
            return "[\(alias)](" + encode(target) + ")"
        }
        return s
    }

    // ![[ target (| alias)? ]]  — the alias is display-only, drop it for images.
    private static let embedRegex = /!\[\[([^\]|]+)(?:\|[^\]]+)?\]\]/
    // [[ target (| alias)? ]]
    private static let wikiRegex = /\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/

    private static func encode(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces)
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
}
