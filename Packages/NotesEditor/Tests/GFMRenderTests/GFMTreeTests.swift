import Foundation
import Testing
@testable import GFMRender

@Suite struct GFMTreeTests {

    @Test func nodeRangesMapToSource() {
        let md = "# Hi\n\nA **bold** word and `code`.\n"
        let ns = md as NSString
        let nodes = GFMRenderer.nodes(md)
        func node(_ kind: String) -> GFMNode? { nodes.first { $0.kind == kind } }

        // Heading range covers "# Hi".
        let h = try! #require(node("heading"))
        #expect(ns.substring(with: h.range) == "# Hi")
        #expect(h.headingLevel == 1)
        // Strong covers "**bold**".
        let strong = try! #require(node("strong"))
        #expect(ns.substring(with: strong.range) == "**bold**")
        // Inline code: cmark reports the *content* span (a known inline
        // sourcepos quirk) — the backticks sit immediately outside it.
        let code = try! #require(node("code"))
        #expect(ns.substring(with: code.range) == "code")
    }

    @Test func parsePerformanceOnHugeNote() {
        let chunk = """
        # Chapter

        A paragraph with **bold**, *italic*, `code`, [a link](https://x.com) and more \
        prose to make the line realistic for a book-length note.

        - item one
        - item two

        > a quote

        ```swift
        let x = 1
        ```

        | a | b |
        |---|---|
        | 1 | 2 |

        """
        // Build ~3.8 MB in one allocation (no O(n²) length checks).
        let reps = 3_800_000 / chunk.utf8.count + 1
        let doc = String(repeating: chunk, count: reps)

        let t0 = DispatchTime.now()
        let nodes = GFMRenderer.nodes(doc)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        print("cmark-gfm parse+walk of \(doc.utf8.count / 1_000_000) MB → \(nodes.count) nodes in \(String(format: "%.1f", ms)) ms")
        #expect(nodes.count > 1000)
    }
}
