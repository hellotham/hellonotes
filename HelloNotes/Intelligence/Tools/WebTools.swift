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
    let name = "web_search"
    let description = "Search the web. Returns result titles, links and snippets."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The search query.")
        var query: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        try await ToolOutcome.run { try await Self.search(arguments.query, limit: 6) }
    }

    @concurrent static func search(_ query: String, limit: Int) async throws -> String {
        var comps = URLComponents(string: "https://html.duckduckgo.com/html/")!
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps.url else { throw ToolError.failed("Couldn't build a search for that.") }

        try WebGuard.validate(url)
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh) HelloNotes", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        // Stream with a byte cap so a hostile or huge response can't balloon memory.
        let session = WebGuard.session(timeout: 20)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ToolError.failed("The search failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        var data = Data()
        let cap = 4 * 1024 * 1024
        for try await byte in bytes { data.append(byte); if data.count >= cap { break } }
        let html = String(data: data, encoding: .utf8) ?? ""
        let results = parseResults(html, limit: limit)
        guard !results.isEmpty else { return "No results for “\(query)”." }
        return results.enumerated().map { i, r in
            "\(i + 1). \(r.title)\n   \(r.url)\n   \(r.snippet)"
        }.joined(separator: "\n")
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
    let name = "web_fetch"
    let description = "Read a web page as plain text. Use it on a link from web_search."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The page's full http or https address.")
        var url: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        let limit = limits.fetchCharacters
        return try await ToolOutcome.run { try await Self.fetch(arguments.url, maxCharacters: limit) }
    }

    @concurrent static func fetch(_ address: String, maxCharacters: Int) async throws -> String {
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
        let byteCap = 4 * 1024 * 1024
        let session = WebGuard.session(timeout: 25)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ToolError.failed("Couldn't load that page (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        var data = Data()
        data.reserveCapacity(min(byteCap, max(0, Int(exactly: http.expectedContentLength) ?? 0)))
        for try await byte in bytes {
            data.append(byte)
            if data.count >= byteCap { break }
        }
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let text = HTMLText.plain(html)
        return text.count > maxCharacters
            ? String(text.prefix(maxCharacters)) + "\n… (truncated)"
            : text
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
