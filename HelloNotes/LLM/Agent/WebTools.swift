//
//  WebTools.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Web access for research: a keyword search (DuckDuckGo HTML endpoint) and a
//  page fetcher that strips HTML to readable text. Both are plain HTTPS GETs
//  covered by the network.client entitlement.
//

import Foundation

struct WebSearchTool: AgentTool {
    let name = "web_search"
    let description = "Search the web and return the top results (title, URL, snippet). Use before web_fetch to find sources."
    var parameters: JSONValue {
        .objectSchema(
            properties: [
                "query": .stringSchema("The search query."),
                "limit": .intSchema("Max results (default 6)."),
            ],
            required: ["query"]
        )
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        guard let query = arguments.string("query") else { throw ToolError.badArguments("`query` is required.") }
        let limit = arguments.int("limit") ?? 6
        var comps = URLComponents(string: "https://html.duckduckgo.com/html/")!
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps.url else { throw ToolError.failed("Bad search URL.") }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh) HelloNotes", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ToolError.failed("Search failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let html = String(data: data, encoding: .utf8) ?? ""
        let results = Self.parseResults(html, limit: limit)
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
            let title = link.count > 2 ? stripTags(link[2]) : ""
            let snippet = i < snippets.count && snippets[i].count > 1 ? stripTags(snippets[i][1]) : ""
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

    private static func stripTags(_ s: String) -> String {
        HTMLText.plain(s)
    }
}

struct WebFetchTool: AgentTool {
    let name = "web_fetch"
    let description = "Fetch a web page and return its readable text (HTML stripped). Use after web_search to read a source."
    var parameters: JSONValue {
        .objectSchema(
            properties: [
                "url": .stringSchema("The absolute URL to fetch (https://…)."),
                "max_chars": .intSchema("Truncate the text to this many characters (default 6000)."),
            ],
            required: ["url"]
        )
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        guard let urlString = arguments.string("url"), let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else {
            throw ToolError.badArguments("A valid http(s) `url` is required.")
        }
        let maxChars = arguments.int("max_chars") ?? 6000
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh) HelloNotes", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 25
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ToolError.failed("Fetch failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let text = HTMLText.plain(html)
        return text.count > maxChars ? String(text.prefix(maxChars)) + "\n… (truncated)" : text
    }
}

/// Very small HTML→text: drop script/style, strip tags, decode a few entities.
enum HTMLText {
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
