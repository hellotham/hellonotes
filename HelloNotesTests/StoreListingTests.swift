//
//  StoreListingTests.swift
//  HelloNotesTests
//
//  The App Store listing text, checked where it is written down.
//
//  `docs/production.md` holds the exact strings that get pasted into App Store
//  Connect. Nothing validated them, and two defects sat in there unnoticed:
//
//    * the **promotional text was 173 characters** against a 170 limit, so the
//      paste would simply have been rejected — found by counting, not reading;
//    * the **Description carried no link to Apple's standard EULA**, which is
//      the metadata half of Guideline 3.1.2(c) and is exactly what rejected
//      build 14. The app can be perfect and still be rejected for the
//      description.
//
//  Both are invisible to every other check in this repo, because they are prose
//  in a document rather than code — and both are the kind of thing that is
//  noticed by a reviewer at Apple rather than by anyone here.
//

import Foundation
import Testing
@testable import HelloNotes

struct StoreListingTests {

    private static var doc: String {
        get throws {
            let url = URL(filePath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "docs/production.md")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    /// The fenced block following a bold label, which is how production.md
    /// presents every paste-able field.
    private static func field(_ label: String, in doc: String) throws -> String {
        let pattern = "\\*\\*\(NSRegularExpression.escapedPattern(for: label))\\*\\*[^\n]*\n```\n(.*?)\n```"
        let re = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let ns = doc as NSString
        guard let m = re.firstMatch(in: doc, range: NSRange(location: 0, length: ns.length)) else {
            Issue.record("no field named \(label) in production.md")
            return ""
        }
        return ns.substring(with: m.range(at: 1))
    }

    /// Every field fits the limit App Store Connect enforces.
    ///
    /// Counted in **characters**, which is what ASC counts — not bytes, and not
    /// words. The em dash in the promotional text is one character here and
    /// three bytes, so a byte count would have called a passing string failing.
    @Test func everyFieldFitsItsLimit() throws {
        let doc = try Self.doc
        for (label, limit) in [("Subtitle", 30), ("Promotional text", 170),
                               ("Keywords", 100), ("Description", 4000)] {
            let text = try Self.field(label, in: doc)
            #expect(!text.isEmpty, "\(label) is empty")
            #expect(text.count <= limit,
                    "\(label) is \(text.count) characters, over the \(limit) App Store Connect allows")
        }
    }

    /// Guideline 3.1.2(c), the half that lives in metadata rather than in the
    /// binary: an app using Apple's standard EULA must link to it from the App
    /// Description. Build 14 was rejected for its absence.
    @Test func theDescriptionLinksTheStandardEULA() throws {
        let description = try Self.field("Description", in: try Self.doc)
        #expect(description.contains("apple.com/legal/internet-services/itunes/dev/stdeula"),
                "the Description must link Apple's standard EULA — 3.1.2(c)")
        #expect(description.contains("hellotham.com/hellonotes/privacy"),
                "the Description must link the privacy policy")
    }

    /// The privacy URL takes **no trailing slash**: the site is an Astro page,
    /// `…/privacy` is 200 and `…/privacy/` is 404. A dead policy link on the one
    /// page a reviewer must open is a rejection, and the difference is one
    /// character that reads as a typo either way.
    @Test func noPolicyURLHasATrailingSlash() throws {
        let doc = try Self.doc
        #expect(!doc.contains("hellotham.com/hellonotes/privacy/"),
                "the privacy URL must not end in a slash — that spelling 404s")
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
        let doc = try Self.doc
        let description = try Self.field("Description", in: doc)
        #expect(!description.lowercased().contains("priority"),
                "the listing must not promise priority support — no such queue exists")
    }
}
