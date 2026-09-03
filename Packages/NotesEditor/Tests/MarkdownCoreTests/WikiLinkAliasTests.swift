import Foundation
import Testing
@testable import MarkdownCore

struct WikiLinkAliasTests {

    /// `[[target|alias]]` reads as the alias; the path is where it goes, not
    /// what it says.
    ///
    /// The whole inner text used to be one content run, so the editor drew
    /// `Examples/Nested Note|example in a subfolder` — plumbing on the page,
    /// and on a store screenshot. Resolution never had this bug
    /// (`StyleApplier.baseTitle` splits on the pipe), which is why it survived:
    /// clicking the link always worked.
    @Test func anAliasedLinkConcealsItsTarget() {
        let text = "See [[Examples/Nested Note|example in a subfolder]]." as NSString
        let nodes = InlineParser.parse(text, in: NSRange(location: 0, length: text.length))
        let link = nodes.first { if case .wikiLink = $0.kind { return true }; return false }
        let node = try! #require(link)
        // Three markers: `[[`, `]]`, and the `target|` prefix.
        #expect(node.markerRanges.count == 3)
        let prefix = try! #require(node.markerRanges.first { $0.length > 2 })
        #expect(text.substring(with: prefix) == "Examples/Nested Note|")
    }

    /// A plain link has no prefix to hide — two markers, not three.
    @Test func aPlainLinkIsUnchanged() {
        let text = "See [[Organising]]." as NSString
        let nodes = InlineParser.parse(text, in: NSRange(location: 0, length: text.length))
        let node = nodes.first { if case .wikiLink = $0.kind { return true }; return false }!
        #expect(node.markerRanges.count == 2)
    }

    /// Embeds carry aliases too: `![[Note|caption]]`.
    @Test func anEmbedHidesItsTargetToo() {
        let text = "![[Examples/Nested Note|a caption]]" as NSString
        let nodes = InlineParser.parse(text, in: NSRange(location: 0, length: text.length))
        let node = nodes.first { if case .wikiLink(_, let isEmbed) = $0.kind { return isEmbed }; return false }!
        #expect(node.markerRanges.count == 3)
        let prefix = node.markerRanges.first { $0.length > 3 }!
        #expect(text.substring(with: prefix) == "Examples/Nested Note|")
    }

    /// A pipe outside the link is not a marker — the scan stops at `]]`.
    @Test func aPipeAfterTheLinkIsNotSwallowed() {
        let text = "[[Organising]] | next" as NSString
        let nodes = InlineParser.parse(text, in: NSRange(location: 0, length: text.length))
        let node = nodes.first { if case .wikiLink = $0.kind { return true }; return false }!
        #expect(node.markerRanges.count == 2)
    }
}
