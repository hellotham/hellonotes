//
//  GFMSpecTests.swift
//  GFMRenderTests
//
//  Full conformance to the GitHub Flavored Markdown specification
//  (https://github.github.com/gfm/). Every example in the spec's own
//  machine-readable corpus (spec.txt, 672 cases — the 24 extension-tagged
//  ones included) is rendered through
//  GFMRenderer and compared to the expected HTML — the exact corpus cmark-gfm,
//  and therefore GitHub, is tested against.
//

import Foundation
import Testing
@testable import GFMRender

struct GFMExample: Sendable {
    let number: Int
    let section: String
    let markdown: String
    let html: String
}

enum GFMSpec {
    /// Parse the spec corpus into (markdown, expected-HTML) examples. `→`
    /// stands for a tab in the corpus (matching cmark's spec_tests.py).
    static func examples() throws -> [GFMExample] {
        let url = try #require(Bundle.module.url(forResource: "spec.txt", withExtension: nil))
        let text = try String(contentsOf: url, encoding: .utf8)
        var out: [GFMExample] = []
        var section = ""
        var number = 0

        let lines = text.components(separatedBy: "\n")
        var i = 0
        func isFence(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy { $0 == "`" } && s.count >= 20 }
        /// The corpus tags an example with the extension it needs — ``` example
        /// table, ``` example autolink, and so on. Requiring the line to *end*
        /// in " example" therefore matched only the 648 core cases and dropped
        /// all 24 tagged ones without a word: 8 table, 11 autolink, 2
        /// strikethrough, 2 tasklist (spelled `disabled` in the corpus) and 1
        /// tagfilter. Tables and strikethrough had consequently never been
        /// checked for HTML byte-parity at all.
        func isExampleStart(_ s: String) -> Bool {
            let parts = s.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 2 || parts.count == 3, parts[1] == "example" else { return false }
            guard !parts[0].isEmpty, parts[0].allSatisfy({ $0 == "`" }) else { return false }
            return parts.count == 2 || !parts[2].isEmpty
        }
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("#") {
                section = line.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            }
            if isExampleStart(line) {
                var md: [String] = []
                var html: [String] = []
                i += 1
                while i < lines.count, lines[i] != "." { md.append(lines[i]); i += 1 }
                i += 1 // skip "."
                while i < lines.count, !isFence(lines[i]) { html.append(lines[i]); i += 1 }
                number += 1
                out.append(GFMExample(
                    number: number,
                    section: section,
                    markdown: (md.joined(separator: "\n") + "\n").replacingOccurrences(of: "→", with: "\t"),
                    html: (html.isEmpty ? "" : html.joined(separator: "\n") + "\n").replacingOccurrences(of: "→", with: "\t")
                ))
            }
            i += 1
        }
        return out
    }


    /// True when two HTML strings are the same *document* — identical text, and
    /// identical tags carrying identical attribute sets — differing only in
    /// things no parser can observe: the order attributes are written in, and
    /// whether a void element closes with `>` or ` />`.
    ///
    /// This exists for one measured case, and is why the widened parser did not
    /// simply grow the allow-list. The linked cmark-gfm's tasklist extension
    /// serialises `<input type="checkbox" disabled="" />`; the corpus, cut from
    /// an older release, wrote `<input disabled="" type="checkbox">`. Same
    /// element, same attributes, same values — the rendered page is identical,
    /// and Preview hands the HTML to WebKit, which parses it rather than reading
    /// its bytes. Byte-parity was the wrong question for those two.
    ///
    /// Deliberately strict everywhere else: any difference in a tag name, an
    /// attribute, a value, or a single character of text returns false, and so
    /// does anything it cannot parse. `sameHTMLDocumentIsStrict` holds it to
    /// that.
    static func sameHTMLDocument(_ a: String, _ b: String) -> Bool {
        guard let ta = tokens(a), let tb = tokens(b) else { return false }
        return ta == tb
    }

    enum HTMLToken: Equatable {
        case text(String)
        case tag(name: String, attributes: [String: String], closing: Bool)
    }

    /// Split HTML into text and tags. Comments and doctypes are kept verbatim as
    /// text, so they still have to match exactly.
    static func tokens(_ s: String) -> [HTMLToken]? {
        var out: [HTMLToken] = []
        var text = ""
        var i = s.startIndex
        while i < s.endIndex {
            guard s[i] == "<" else { text.append(s[i]); i = s.index(after: i); continue }
            if s[i...].hasPrefix("<!") {
                guard let end = s.range(of: ">", range: i..<s.endIndex) else { return nil }
                text.append(contentsOf: s[i..<end.upperBound])
                i = end.upperBound
                continue
            }
            if !text.isEmpty { out.append(.text(text)); text = "" }
            var j = s.index(after: i)
            var quote: Character?
            while j < s.endIndex {
                let c = s[j]
                if let q = quote { if c == q { quote = nil } }
                else if c == "\"" || c == "'" { quote = c }
                else if c == ">" { break }
                j = s.index(after: j)
            }
            guard j < s.endIndex, let tag = parseTag(String(s[s.index(after: i)..<j])) else { return nil }
            out.append(tag)
            i = s.index(after: j)
        }
        if !text.isEmpty { out.append(.text(text)) }
        return out
    }

    private static func parseTag(_ raw: String) -> HTMLToken? {
        var body = Substring(raw)
        var closing = false
        if body.hasPrefix("/") { closing = true; body = body.dropFirst() }
        if body.hasSuffix("/") { body = body.dropLast() }   // `<br />` is `<br>`
        let chars = Array(body)
        var k = 0
        func skipSpace() { while k < chars.count, chars[k].isWhitespace { k += 1 } }

        skipSpace()
        var name = ""
        while k < chars.count, !chars[k].isWhitespace { name.append(chars[k]); k += 1 }
        guard !name.isEmpty else { return nil }

        var attributes: [String: String] = [:]
        while true {
            skipSpace()
            guard k < chars.count else { break }
            var key = ""
            while k < chars.count, !chars[k].isWhitespace, chars[k] != "=" { key.append(chars[k]); k += 1 }
            guard !key.isEmpty else { return nil }
            skipSpace()
            var value = ""
            if k < chars.count, chars[k] == "=" {
                k += 1
                skipSpace()
                if k < chars.count, chars[k] == "\"" || chars[k] == "'" {
                    let q = chars[k]
                    k += 1
                    while k < chars.count, chars[k] != q { value.append(chars[k]); k += 1 }
                    guard k < chars.count else { return nil }
                    k += 1
                } else {
                    while k < chars.count, !chars[k].isWhitespace { value.append(chars[k]); k += 1 }
                }
            }
            // A repeated attribute is malformed; refuse rather than pick one.
            guard attributes.updateValue(value, forKey: key.lowercased()) == nil else { return nil }
        }
        return .tag(name: name.lowercased(), attributes: attributes, closing: closing)
    }

    /// The only examples whose output differs from the corpus in serialisation
    /// alone. Held as an exact set, like `extensionOverrides`, so a third one
    /// has to be looked at rather than quietly absorbed.
    static let serialisationOnly: Set<String> = [
        "- [ ] foo\n- [x] bar\n",
        "- [x] foo\n  - [ ] bar\n  - [x] baz\n- [ ] bim\n",
    ]

    /// The exact CommonMark-core examples whose *expected* output the GFM
    /// `tagfilter` and extended-`autolink` extensions deliberately override.
    /// GitHub renders these the extension way (verified live against
    /// api.github.com/markdown, 2026-07-17) — not the pre-extension core text.
    /// Every divergence from the corpus must be one of these; a new one is a
    /// real regression.
    static let extensionOverrides: Set<String> = [
        // tagfilter — `<script>` / `<style>` escaped for safety
        "<script type=\"text/javascript\">\n// JavaScript example\n\ndocument.getElementById(\"demo\").innerHTML = \"Hello JavaScript!\";\n</script>\nokay\n",
        "<style\n  type=\"text/css\">\nh1 {color:red;}\n\np {color:blue;}\n</style>\nokay\n",
        "<style\n  type=\"text/css\">\n\nfoo\n",
        "<style>p{color:red;}</style>\n*foo*\n",
        "<script>\nfoo\n</script>1. *bar*\n",
        // extended autolink — bare / spaced URLs & emails become links
        "<http://foo.bar/baz bim>\n",
        "<foo\\+@bar.example.com>\n",
        "< http://foo.bar >\n",
        "http://example.com\n",
        "foo@bar.example.com\n",
    ]
}

@Suite struct GFMSpecTests {

    @Test func fullSpecConformance() throws {
        let examples = try GFMSpec.examples()
        // The corpus's own size, not a floor: `> 600` was true of the 648 the
        // old parser could see, so it could never have reported the 24 it
        // could not. If spec.txt is updated, this should fail and be re-read.
        #expect(examples.count == 672, "expected all 672 spec examples, got \(examples.count)")

        var unexpected: [(GFMExample, String)] = []
        var overridesHit = Set<String>()
        var serialisationHit = Set<String>()
        for ex in examples {
            let got = GFMRenderer.html(ex.markdown)
            guard got != ex.html else { continue }
            if GFMSpec.extensionOverrides.contains(ex.markdown) {
                overridesHit.insert(ex.markdown)   // expected divergence
            } else if GFMSpec.sameHTMLDocument(got, ex.html) {
                serialisationHit.insert(ex.markdown)   // same document, different bytes
            } else {
                unexpected.append((ex, got))
            }
        }

        let exact = examples.count - overridesHit.count - serialisationHit.count - unexpected.count
        print("GFM spec conformance: \(exact) exact + \(overridesHit.count) GitHub-extension overrides"
            + " + \(serialisationHit.count) serialisation-only = \(exact + overridesHit.count + serialisationHit.count)/\(examples.count)")

        if !unexpected.isEmpty {
            print("--- UNEXPECTED divergences (\(unexpected.count)) ---")
            for (ex, got) in unexpected.prefix(20) {
                print("EXAMPLE \(ex.number) [\(ex.section)]")
                print("  markdown:  \(ex.markdown.debugDescription)")
                print("  expected:  \(ex.html.debugDescription)")
                print("  got:       \(got.debugDescription)")
            }
        }
        // No divergence beyond the documented GitHub-extension overrides.
        #expect(unexpected.isEmpty, "\(unexpected.count) unexpected GFM divergences")
        // Every documented override is still actually exercised (keeps the
        // allow-list honest — no stale entries silently masking regressions).
        #expect(overridesHit == GFMSpec.extensionOverrides,
                "stale override entries: \(GFMSpec.extensionOverrides.subtracting(overridesHit))")
        // Same for the serialisation-only set: exactly the two task lists, so a
        // third has to be read rather than absorbed by the equivalence check.
        #expect(serialisationHit == GFMSpec.serialisationOnly,
                "serialisation-only set drifted — unexpected \(serialisationHit.subtracting(GFMSpec.serialisationOnly)), stale \(GFMSpec.serialisationOnly.subtracting(serialisationHit))")
    }

    /// The equivalence above is an escape hatch, so it is held to being narrow:
    /// it may forgive attribute order and a void element's slash, and nothing
    /// else. Without this, `sameHTMLDocument` is exactly the kind of unchecked
    /// excuse the corpus spent years carrying.
    @Test func sameHTMLDocumentIsStrict() {
        // Forgiven — the same document either way.
        #expect(GFMSpec.sameHTMLDocument(
            "<input type=\"checkbox\" disabled=\"\" /> x\n",
            "<input disabled=\"\" type=\"checkbox\"> x\n"))
        #expect(GFMSpec.sameHTMLDocument("<br />", "<br>"))
        #expect(GFMSpec.sameHTMLDocument("<a href=\"/x\" title=\"t\">q</a>",
                                         "<a title=\"t\" href=\"/x\">q</a>"))

        // Refused — every one of these is a real difference.
        #expect(!GFMSpec.sameHTMLDocument("<input type=\"checkbox\">", "<input type=\"radio\">"))
        #expect(!GFMSpec.sameHTMLDocument("<input type=\"checkbox\" checked=\"\">",
                                          "<input type=\"checkbox\">"))
        #expect(!GFMSpec.sameHTMLDocument("<em>x</em>", "<strong>x</strong>"))
        #expect(!GFMSpec.sameHTMLDocument("<p>x</p>", "<p>y</p>"))
        #expect(!GFMSpec.sameHTMLDocument("<p>x</p>", "<p> x</p>"))
        #expect(!GFMSpec.sameHTMLDocument("<p>x</p>", "</p>x<p>"))
        #expect(!GFMSpec.sameHTMLDocument("<del>x</del>", "<del>x</del><del>x</del>"))
        // Order of *elements* is not attribute order.
        #expect(!GFMSpec.sameHTMLDocument("<em>a</em><b>c</b>", "<b>c</b><em>a</em>"))
        // Comments must still match exactly.
        #expect(!GFMSpec.sameHTMLDocument("<!-- a -->x", "<!-- b -->x"))
        // Unparseable input is never called equivalent.
        #expect(!GFMSpec.sameHTMLDocument("<p", "<p"))
    }
}
