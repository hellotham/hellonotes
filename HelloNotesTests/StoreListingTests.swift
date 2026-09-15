//
//  StoreListingTests.swift
//  HelloNotesTests
//
//  The App Store listing text, checked where it is written down.
//
//  `docs/app-store-listing.md` holds the exact strings for the version being
//  prepared, before they are pasted into App Store Connect. Nothing validated
//  them once, and two defects sat there unnoticed:
//
//    * the **promotional text was 173 characters** against a 170 limit, so the
//      paste would simply have been rejected — found by counting, not reading;
//    * the **Description carried no link to Apple's standard EULA**, which is
//      the metadata half of Guideline 3.1.2(c) and is exactly what rejected
//      build 14. The app can be perfect and still be rejected for the
//      description.
//
//  These tests read `docs/production.md` until that file stopped carrying the
//  copy (App Store Connect is the source of truth for what is *live*). They
//  then failed for every field — and went on failing, unread, until the
//  1.3.3 work ran the suite. The copy moved to its own file so there is always
//  something here to check before a submission.
//

import Foundation
import Testing
@testable import HelloNotes

struct StoreListingTests {

    private static func read(_ path: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static var doc: String {
        get throws { try read("docs/app-store-listing.md") }
    }

    /// Every fenced block following a bold label, which is how the listing file
    /// presents each paste-able field. A label can appear once per platform
    /// (the Description does), so all of them are returned.
    private static func fields(_ label: String, in doc: String) throws -> [String] {
        let pattern = "\\*\\*\(NSRegularExpression.escapedPattern(for: label))\\*\\*[^\n]*\n```\n(.*?)\n```"
        let re = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let ns = doc as NSString
        let found = re.matches(in: doc, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
        if found.isEmpty { Issue.record("no field named \(label) in app-store-listing.md") }
        return found
    }

    private static func field(_ label: String, in doc: String) throws -> String {
        try fields(label, in: doc).first ?? ""
    }

    /// Every field fits the limit App Store Connect enforces.
    ///
    /// Counted in **characters**, which is what ASC counts — not bytes, and not
    /// words. The em dash in the promotional text is one character here and
    /// three bytes, so a byte count would have called a passing string failing.
    @Test func everyFieldFitsItsLimit() throws {
        let doc = try Self.doc
        for (label, limit) in [("Subtitle", 30), ("Promotional text", 170),
                               ("Keywords", 100), ("Description", 4000), ("Version", 4000)] {
            for text in try Self.fields(label, in: doc) {
                #expect(!text.isEmpty, "\(label) is empty")
                #expect(text.count <= limit,
                        "\(label) is \(text.count) characters, over the \(limit) App Store Connect allows")
            }
        }
        #expect(try Self.fields("Description", in: doc).count == 2,
                "one Description per platform — iPhone and iPad, and Mac")
    }

    /// Guideline 3.1.2(c), the half that lives in metadata rather than in the
    /// binary: an app using Apple's standard EULA must link to it from the App
    /// Description. Build 14 was rejected for its absence.
    @Test func theDescriptionLinksTheStandardEULA() throws {
        for description in try Self.fields("Description", in: try Self.doc) {
            #expect(description.contains("apple.com/legal/internet-services/itunes/dev/stdeula"),
                    "the Description must link Apple's standard EULA — 3.1.2(c)")
            #expect(description.contains("hellotham.com/hellonotes/privacy"),
                    "the Description must link the privacy policy")
        }
    }

    /// The privacy URL takes **no trailing slash**: the site is an Astro page,
    /// `…/privacy` is 200 and `…/privacy/` is 404. A dead policy link on the one
    /// page a reviewer must open is a rejection, and the difference is one
    /// character that reads as a typo either way.
    @Test func noPolicyURLHasATrailingSlash() throws {
        for doc in [try Self.doc, try Self.read("docs/production.md")] {
            #expect(!doc.contains("hellotham.com/hellonotes/privacy/"),
                    "the privacy URL must not end in a slash — that spelling 404s")
        }
    }

    /// "Initial release." is the 1.0 text. The field keeps its previous contents
    /// between submissions, so a stale one ships silently.
    @Test func whatsNewIsNotStillTheOnePointOhText() throws {
        let doc = try Self.doc
        let whatsNew = try Self.field("Version", in: doc)
        #expect(whatsNew != "Initial release.",
                "What's New still carries the 1.0 text")
        #expect(whatsNew.count <= 4000)
    }

    /// The listing must not promise a queue that does not exist. Exactly one
    /// thing consults a purchase — an in-app support request — and it is a
    /// channel, not a priority.
    @Test func theListingPromisesNoPriorityQueue() throws {
        for description in try Self.fields("Description", in: try Self.doc) {
            #expect(!description.lowercased().contains("priority"),
                    "the listing must not promise priority support — no such queue exists")
            // Something is gated: backing adds an in-app support request.
            #expect(!description.contains("neither unlocks anything"),
                    "the listing must not claim nothing is gated — backing adds a support request")
        }
    }

    /// Guideline 5, the China storefront: no reference to OpenAI or ChatGPT in
    /// any field, and — since 1.3.3 removed them — no retired AI provider either.
    /// The 1.3.2 description still named Anthropic, Mistral and Gemini.
    @Test func noThirdPartyAIServiceIsNamed() throws {
        let doc = try Self.doc
        var text = ""
        for label in ["Subtitle", "Promotional text", "Keywords", "Description", "Version"] {
            text += try Self.fields(label, in: doc).joined(separator: "\n")
        }
        for name in ["OpenAI", "ChatGPT", "GPT-", "Anthropic", "Claude", "Gemini", "Mistral", "OpenRouter",
                     "Groq", "xAI", "Grok", "DeepSeek", "Perplexity", "Ollama", "LM Studio", "API key"] {
            // "no API keys" is the point being made; naming a key to add is not.
            if name == "API key" {
                #expect(!text.contains("your own API key") && !text.contains("your own cloud API key"),
                        "the listing still invites an API key")
                continue
            }
            #expect(!text.localizedCaseInsensitiveContains(name), "the listing names \(name)")
        }
    }

    /// The listing may only promise Private Cloud Compute in a build that can
    /// offer it — without the entitlement the app does not show the model at all.
    @Test func privateCloudComputeIsOnlyListedWhenTheBuildOffersIt() throws {
        let doc = try Self.doc
        var text = ""
        for label in ["Promotional text", "Description", "Version"] {
            text += try Self.fields(label, in: doc).joined(separator: "\n")
        }
        if !LanguageModels.privateCloudComputeEnabled {
            #expect(!text.contains("Private Cloud Compute"),
                    "the listing offers Private Cloud Compute, which this build cannot")
        }
    }
}
