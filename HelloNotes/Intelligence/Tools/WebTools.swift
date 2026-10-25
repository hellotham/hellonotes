//
//  WebTools.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Web access for the Assistant and for research: a keyword search (DuckDuckGo's
//  HTML endpoint) and a page fetcher that strips HTML to readable text. Both are
//  plain HTTPS GETs covered by the network.client entitlement, both go through
//  `WebGuard`, and both run entirely off the main actor — the parsing below is
//  a chain of regular expressions over up to four megabytes.
//

import Foundation
import FoundationModels

nonisolated struct WebSearchTool: Tool {
    /// The turn's room, which this shares with the turn's other results
    /// (`TurnRoom`); `nil` outside one.
    var room: TurnRoom? = nil
    let name = "web_search"
    let description = "Search the web. Returns result titles, links and snippets."

    /// What six results take at most: a title, an address and a snippet each.
    static let resultTokens = 800

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The search query.")
        var query: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        // Taken before the search, as a note's read is: a sibling shaped
        // while this one waits on the network sees what is left without it.
        guard let tokens = await TurnRoom.reserve(Self.resultTokens, from: room) else { return ToolContext.noRoom }
        return try await ToolOutcome.run { try await Self.search(arguments.query, limit: 6, tokens: tokens) }
    }

    @concurrent static func search(_ query: String, limit: Int,
                                   tokens: Int = WebSearchTool.resultTokens) async throws -> String {
        var comps = URLComponents(string: "https://html.duckduckgo.com/html/")!
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps.url else { throw ToolError.failed("Couldn't build a search for that.") }

        try WebGuard.validate(url)
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh) HelloNotes", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        // Streamed with a byte cap so a hostile or huge response can't balloon
        // memory, and refused if a private address served it (`WebGuard.load`).
        let (data, response) = try await WebGuard.load(request, timeout: 20, byteCap: 4 * 1024 * 1024)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ToolError.failed("The search failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let html = String(data: data, encoding: .utf8) ?? ""
        let results = parseResults(html, limit: limit)
        guard !results.isEmpty else { return "No results for “\(query)”." }
        let lines = results.enumerated().map { i, r in
            "\(i + 1). \(r.title)\n   \(r.url)\n   \(r.snippet)"
        }
        return shaped(lines, tokens: tokens)
    }

    /// The results that fit in `tokens`, whole — at least one — and the count
    /// of the rest.
    static func shaped(_ lines: [String], tokens: Int) -> String {
        let shown = ToolContext.fitting(lines, tokens: tokens)
        let text = lines.prefix(shown).joined(separator: "\n")
        return shown < lines.count
            ? text + "\n… and \(lines.count - shown) more results that don't fit here."
            : text
    }

    private struct Result { let title: String; let url: String; let snippet: String }

    /// Scrape DuckDuckGo's HTML results. Best-effort regex over the result anchors.
    private static func parseResults(_ html: String, limit: Int) -> [Result] {
        var results: [Result] = []
        let linkPattern = #"<a[^>]*class=\"result__a\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>"#
        let snippetPattern = #"<a[^>]*class=\"result__snippet\"[^>]*>(.*?)</a>"#
        let links = matches(linkPattern, in: html)
        let snippets = matches(snippetPattern, in: html)
        for (i, link) in links.enumerated() where results.count < limit {
            let rawURL = link.count > 1 ? decodeDDG(link[1]) : ""
            let title = link.count > 2 ? HTMLText.plain(link[2]) : ""
            let snippet = i < snippets.count && snippets[i].count > 1 ? HTMLText.plain(snippets[i][1]) : ""
            guard !rawURL.isEmpty, !title.isEmpty else { continue }
            results.append(Result(title: title, url: rawURL, snippet: snippet))
        }
        return results
    }

    /// DuckDuckGo wraps target URLs as //duckduckgo.com/l/?uddg=<encoded>.
    private static func decodeDDG(_ href: String) -> String {
        guard let comps = URLComponents(string: href.hasPrefix("//") ? "https:" + href : href),
              let uddg = comps.queryItems?.first(where: { $0.name == "uddg" })?.value else {
            return href.hasPrefix("//") ? "https:" + href : href
        }
        return uddg
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }
}

nonisolated struct WebFetchTool: Tool {
    let limits: ToolLimits
    /// The turn's room, which this shares with the turn's other results
    /// (`TurnRoom`); `nil` outside one. A page takes at most its own cap,
    /// `limits.fetchTokens`, and less when the turn has less left: Research
    /// gave each page a fixed share whatever its questions had read already,
    /// and on the on-device model's 8,192 tokens a third page ran the
    /// question's session past its window.
    var room: TurnRoom? = nil
    let name = "web_fetch"
    let description = "Read a web page as plain text. Use it on a link from web_search."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The page's full http or https address.")
        var url: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        // Taken before the page is fetched, as a note's read is.
        guard let tokens = await TurnRoom.reserve(limits.fetchTokens, from: room) else { return ToolContext.noRoom }
        return try await ToolOutcome.run { try await Self.fetch(arguments.url, maxTokens: tokens) }
    }

    @concurrent static func fetch(_ address: String, maxTokens: Int) async throws -> String {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)),
              url.scheme?.hasPrefix("http") == true else {
            throw ToolError.badArguments("That isn't an http or https address.")
        }
        // SSRF guard: block loopback/private/link-local hosts (and redirects to
        // them) so injected content can't reach internal services or metadata.
        try WebGuard.validate(url)
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh) HelloNotes", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 25
        // Refused if a private address served it, whatever the host resolved
        // to when it was validated (`WebGuard.load`).
        let (data, response) = try await WebGuard.load(request, timeout: 25, byteCap: 4 * 1024 * 1024)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ToolError.failed("Couldn't load that page (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return shaped(HTMLText.plain(html), tokens: maxTokens)
    }

    /// `text` within `tokens`, cut as a model counts — by tokens, never by
    /// characters, which sent a Chinese page several times over its share.
    static func shaped(_ text: String, tokens: Int) -> String {
        let (kept, cut) = TokenBudget.prefix(text, tokens: max(50, tokens - 20))
        return cut ? kept + "\n… (truncated)" : kept
    }
}

/// Very small HTML→text: drop script/style, strip tags, decode a few entities.
nonisolated enum HTMLText {
    static func plain(_ html: String) -> String {
        var s = html
        for tag in ["script", "style", "head", "noscript"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>.*?</\(tag)>", with: " ",
                                       options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</p>|</div>|</li>|</h[1-6]>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        // Collapse whitespace runs and blank lines.
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n[ \\t]*\n[ \\t\n]*", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
