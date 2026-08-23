//
//  HTMLBlockShape.swift
//  MarkdownCore
//
//  Is a raw HTML block something that can be rendered on its own?
//
//  CommonMark's block boundaries are not element boundaries. `<div class="x">`
//  alone on a line is a *complete* HTML block (start condition 6, ended by the
//  blank line after it), and so is the `</div>` four paragraphs later — the
//  Markdown between them is its own set of blocks. A renderer given the whole
//  document nests them; a renderer given one block at a time cannot, because
//  half a `<div>` is not a thing that has a size.
//
//  Handed `<div class="x">` on its own, WebKit closes the tag for you and
//  returns a box — a plausible, confident, wrong answer, drawn twice (once for
//  the opening fragment and once for the closing one) around content that is
//  no longer inside anything. Measured on the spec corpus that turned a 40pt
//  document into a 104pt one.
//
//  So the editor renders a block only when the block stands alone.
//

import Foundation

public enum HTMLBlockShape {

    /// Elements with no closing tag, which must not be pushed on the stack.
    private static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    ]

    /// Whether `source` is a complete fragment: every element it opens, it
    /// closes, and it closes nothing it did not open.
    ///
    /// Comments, doctypes and processing instructions are self-contained by
    /// definition — they have no children to leave dangling.
    public static func isSelfContained(_ source: String) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("<!--") { return trimmed.hasSuffix("-->") }
        if trimmed.hasPrefix("<!") || trimmed.hasPrefix("<?") { return true }

        var stack: [String] = []
        guard let sawElement = advance(stack: &stack, through: trimmed) else { return false }
        return sawElement && stack.isEmpty
    }

    /// Push every element `source` opens onto `stack` and pop every one it
    /// closes, returning whether it held any content of its own — or nil when
    /// it closes something that is not open, or leaves a tag unterminated.
    ///
    /// Split out of `isSelfContained` because "is this fragment whole" and
    /// "what is still open after it" are the same walk asked at different
    /// scopes. An HTML block that opens more than it closes is not a mistake
    /// to refuse: it is the *first* block of a span, and the blocks after it
    /// carry the rest. Running one stack across them is what lets the editor
    /// render `<table>` / blank / `<tr>` / … / `</table>` as the one table the
    /// page draws instead of five fragments and a guess.
    ///
    /// A nil return is final. Crossed tags (`<b>x</i>`) cannot be rescued by
    /// reading further, so the caller stops rather than swallowing the rest of
    /// the note looking for a balance that will never come.
    public static func advance(stack: inout [String], through source: String) -> Bool? {
        var sawElement = false
        let scalars = Array(source.utf16)
        let n = scalars.count
        var i = 0
        while i < n {
            guard scalars[i] == 0x3C else { i += 1; continue }
            var j = i + 1
            guard j < n else { return nil }
            // Skip comments wholesale; they nest nothing.
            if matches(scalars, at: i, n, "<!--") {
                guard let end = find(scalars, from: i, n, "-->") else { return nil }
                i = end
                continue
            }
            let closing = scalars[j] == 0x2F
            if closing { j += 1 }
            var units: [UInt16] = []
            while j < n, isNameScalar(scalars[j]) {
                units.append(scalars[j]); j += 1
            }
            guard !units.isEmpty else { i += 1; continue }
            let tag = String(decoding: units, as: UTF16.self).lowercased()
            // Walk to the tag's `>`, noticing a self-closing `/>` on the way.
            var selfClosing = false
            while j < n, scalars[j] != 0x3E {
                selfClosing = scalars[j] == 0x2F
                j += 1
            }
            guard j < n else { return nil }                 // unterminated tag
            sawElement = true
            // A tag the GFM tag filter escapes never becomes an element: the
            // page prints `&lt;xmp>` and the reader sees the angle brackets.
            // Pushing it left `<blockquote>` / `<xmp> …` / `</blockquote>`
            // looking unbalanced — half an element, so nothing rendered — when
            // the only element in it opens and closes on the page exactly as
            // written (spec #652). `sawElement` still counts it, because the
            // text it turns into *is* something to draw.
            if filteredTags.contains(tag) { i = j + 1; continue }
            if closing {
                guard let top = stack.last, top == tag else { return nil }
                stack.removeLast()
            } else if !selfClosing, !voidTags.contains(tag) {
                stack.append(tag)
            }
            i = j + 1
        }
        return sawElement
    }

    /// Where the HTML **tokenizer** runs off the end of `source`: the UTF-16
    /// offset of the `<` that opens a tag, comment, declaration or instruction
    /// it never finds an end for. Everything from there on is consumed as part
    /// of that construct and painted nowhere.
    ///
    /// This is a *different question* from `isTagsOnly` and `tagEnd`, and the
    /// three used to be conflated. Those two ask CommonMark's question — is
    /// this a well-formed tag — and answer "no" for `<div *???-&&&-<---`,
    /// because `*` cannot start an attribute name. The tokenizer does not get
    /// to say no: once it has seen `<` and a letter it is in the tag, and it
    /// stays there until an unquoted `>` or the end of the input. So a line
    /// cmark passes through as ordinary text is a line the browser eats, and
    /// the editor drew 48pt of source against a page that painted nothing at
    /// all (spec #126–#128).
    ///
    /// Returns nil when every construct closes, which is the ordinary case.
    public static func unterminatedRunStart(_ source: String) -> Int? {
        let s = Array(source.utf16)
        let n = s.count
        var i = 0
        while i < n {
            guard s[i] == 0x3C else { i += 1; continue }        // `<`
            if matches(s, at: i, n, "<!--") {
                guard let end = find(s, from: i, n, "-->") else { return i }
                i = end
                continue
            }
            // `<!` (declaration) and `<?` (a bogus comment to the HTML parser)
            // both run to the next `>`, quoted or not.
            if i + 1 < n, s[i + 1] == 0x21 || s[i + 1] == 0x3F {
                var j = i + 2
                while j < n, s[j] != 0x3E { j += 1 }
                guard j < n else { return i }
                i = j + 1
                continue
            }
            var j = i + 1
            if j < n, s[j] == 0x2F { j += 1 }                   // `</`
            // Only a letter opens a tag. `a < b`, `<3 things` and a bare `<>`
            // are text, and treating them as tags would hide the line they are
            // written on.
            guard j < n, isLetter(s[j]) else { i += 1; continue }
            var closed = false
            while j < n {
                if s[j] == 0x3E { closed = true; j += 1; break }
                // A quoted attribute value may hold a `>` — `<a title="a>b">`
                // is one tag, not two. The quote counts only where a value can
                // start, i.e. straight after the `=`; anywhere else it is part
                // of an attribute name as far as the tokenizer is concerned.
                if s[j] == 0x3D {
                    var k = j + 1
                    while k < n, isHTMLSpace(s[k]) { k += 1 }
                    if k < n, s[k] == 0x22 || s[k] == 0x27 {
                        let quote = s[k]
                        k += 1
                        while k < n, s[k] != quote { k += 1 }
                        guard k < n else { return i }           // unterminated value
                        j = k + 1
                        continue
                    }
                }
                j += 1
            }
            guard closed else { return i }
            i = j
        }
        return nil
    }

    /// Is the **first** tag in `source` one the GFM tag filter escapes?
    ///
    /// Asked of the first tag rather than of the whole string, because the
    /// answer decides whether the block is an element at all. A `<style` that
    /// opens the block makes every line below it text; a `<title` buried inside
    /// a `<div>` says nothing about the `<div>`.
    public static func opensTagFilteredElement(_ source: String) -> Bool {
        let s = Array(source.utf16)
        let n = s.count
        var i = 0
        while i < n, isHTMLSpace(s[i]) { i += 1 }
        guard i < n, s[i] == 0x3C else { return false }
        var j = i + 1
        if j < n, s[j] == 0x2F { j += 1 }
        var units: [UInt16] = []
        while j < n, isNameScalar(s[j]) { units.append(s[j]); j += 1 }
        guard !units.isEmpty else { return false }
        return filteredTags.contains(String(decoding: units, as: UTF16.self).lowercased())
    }

    /// Elements that lay their own children out, so no amount of concealing
    /// their tags reproduces what the page draws inside them.
    ///
    /// This is the line between the editor's two answers for a raw HTML block
    /// that spans several CommonMark blocks. A `<div>` (or a `<del>`, or a
    /// `<span>`) is *structure*: its children lay out exactly as they would
    /// without it, so hiding the tag lines and styling the Markdown between
    /// them gives the page's own picture, and keeps that Markdown editable as
    /// Markdown. A `<table>` does not: `<tr>` and `<td>` become table rows and
    /// cells, with borders, padding and column widths that no line of prose
    /// has. There the only honest answer is to render the whole span.
    ///
    /// Measured both ways on the corpus: rendering every span cost #122, #137
    /// and #157 (a `<div>` around a paragraph, which the concealing path had
    /// exactly right) to win #118, #159 and #160.
    ///
    /// `details` is the strongest case in the set and the last to be found,
    /// because the corpus has no `<details>` in it and a collapsible section is
    /// something people write in notes constantly. A closed `<details>` does
    /// not merely lay its children out differently — it **does not draw them at
    /// all**, and draws a disclosure triangle and its `<summary>` instead. Take
    /// the tags away and style the Markdown between them, and Edit shows a
    /// paragraph the reader cannot see: not 24pt of spacing drift but a piece
    /// of the note that is on one surface and not on the other. (`summary` is
    /// not listed: it is only ever *inside* a `details`, and the span is
    /// decided by its outermost tag.)
    public static let laysOutItsChildren: Set<String> = [
        "table", "thead", "tbody", "tfoot", "tr", "td", "th", "details",
    ]

    /// Tags that draw something even with no content, so a line holding one is
    /// not a bare wrapper.
    private static let drawingTags: Set<String> = ["img", "br", "hr", "input", "iframe", "video"]

    /// Is this line nothing but *wrapper* tags — structure the reader never
    /// sees, drawing nothing of its own?
    public static func isBareWrapperLine(_ line: String) -> Bool {
        guard isTagsOnly(line) else { return false }
        return !drawsSomething(line.lowercased())
    }

    /// Does this (lowercased) line carry a tag that draws on its own?
    public static func drawsSomething(_ lowered: String) -> Bool {
        drawingTags.contains { lowered.contains("<" + $0) }
    }

    /// Is this line nothing but tags — `</div>`, `<div class="x">`, `<td><b>`?
    ///
    /// A wrapper tag is structure, not content: the reader sees no tag, and the
    /// element contributes no height of its own. A line carrying text as well
    /// (`</div>*foo*`) does show something, and must keep its line.
    public static func isTagsOnly(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("<!--") && trimmed.hasSuffix("-->") { return true }
        let scalars = Array(trimmed.unicodeScalars)
        var i = 0
        var sawTag = false
        while i < scalars.count {
            if scalars[i] == " " || scalars[i] == "\t" { i += 1; continue }
            guard scalars[i] == "<" else { return false }
            var j = i + 1
            while j < scalars.count, scalars[j] != ">" { j += 1 }
            guard j < scalars.count else { return false }   // unterminated
            sawTag = true
            i = j + 1
        }
        return sawTag
    }

    /// Tags GitHub's `tagfilter` extension escapes rather than passes through,
    /// so the page prints the tag itself as text. `<strong> <title> <style>
    /// <em>` is a line of *visible* angle brackets, not a line of wrappers —
    /// collapsing it on the strength of "every run is a well-formed tag" hid
    /// two of the four words the reader can see.
    private static let filteredTags: Set<String> = [
        "title", "textarea", "style", "xmp", "iframe",
        "noembed", "noframes", "script", "plaintext",
    ]

    /// Does this (lowercased) line carry a tag the GFM tag filter turns back
    /// into text?
    public static func isEscapedByTagFilter(_ lowered: String) -> Bool {
        filteredTags.contains { lowered.contains("<" + $0) || lowered.contains("</" + $0) }
    }

    /// Is this line nothing but **well-formed** raw HTML tags?
    ///
    /// `isTagsOnly` asks only whether every run starts with `<` and reaches a
    /// `>`, which is the right question for an HTML *block* — cmark already
    /// decided that block was HTML. Inside a paragraph nothing has decided
    /// anything, and by that loose measure an autolink (`<http://foo.bar>`), a
    /// literal `<>` and every malformed tag in the Raw HTML section
    /// (`<a h*#ref="hi">`, `</a href="foo">`, `<33>`) all read as tags. Those
    /// are *text* to CommonMark — the page prints them — so collapsing on the
    /// loose predicate hides two dozen visible lines to fold three.
    ///
    /// Hence the spec's own grammar, which those all fail on: a tag name is a
    /// letter followed by letters, digits and hyphens; attributes must be
    /// separated by whitespace and their names start `[A-Za-z_:]`; a closing
    /// tag takes no attributes. Anything this cannot parse simply keeps its
    /// source, which is what it did before.
    public static func isWellFormedTagsOnlyLine(_ line: String) -> Bool {
        let s = Array(line.utf16)
        var i = 0
        var sawTag = false
        while i < s.count {
            if isHTMLSpace(s[i]) { i += 1; continue }
            guard s[i] == 0x3C, let next = tagEnd(s, from: i, count: s.count) else { return false }
            sawTag = true
            i = next
        }
        return sawTag
    }

    /// The index just past the raw HTML tag, comment, instruction, declaration
    /// or CDATA section starting at `i`, or nil if what is there is not one.
    ///
    /// **The one place the tag grammar lives.** `InlineParser` asks it too, and
    /// the day it did not — a scan of its own that took anything up to the next
    /// `>` — `<foo bar=baz⏎bim!bop />` came back as a tag, the two lines were
    /// joined into one, and the page (which reads `bim!bop` as an attribute
    /// name and rejects the lot) kept printing two lines of literal text.
    /// Spec #640, and the reason this is `public` rather than convenient.
    ///
    /// A line ending is whitespace here, so a tag may span one: that is
    /// CommonMark's rule and cmark's behaviour, and it is what makes the page
    /// draw one line where the source has two.
    public static func tagEnd(_ s: [UInt16], from i: Int, count: Int) -> Int? {
        var j = i + 1
        guard j < count else { return nil }
        if matches(s, at: i, count, "<!--") { return find(s, from: i, count, "-->") }
        if matches(s, at: i, count, "<![CDATA[") { return find(s, from: i, count, "]]>") }
        if matches(s, at: i, count, "<?") { return find(s, from: i, count, "?>") }
        if s[j] == 0x21 {                                       // declaration
            j += 1
            var letters = 0
            while j < count, isLetter(s[j]) { j += 1; letters += 1 }
            guard letters > 0 else { return nil }
            while j < count, s[j] != 0x3E { j += 1 }
            return j < count ? j + 1 : nil
        }
        let closing = s[j] == 0x2F
        if closing { j += 1 }
        guard j < count, isLetter(s[j]) else { return nil }     // name starts with a letter
        j += 1
        while j < count, isNameScalar(s[j]) { j += 1 }
        if closing {
            while j < count, isHTMLSpace(s[j]) { j += 1 }
            return j < count && s[j] == 0x3E ? j + 1 : nil      // no attributes allowed
        }
        while true {
            var sawSpace = false
            while j < count, isHTMLSpace(s[j]) { j += 1; sawSpace = true }
            guard j < count else { return nil }
            if s[j] == 0x3E { return j + 1 }
            if s[j] == 0x2F {
                j += 1
                return j < count && s[j] == 0x3E ? j + 1 : nil
            }
            // An attribute has to be preceded by whitespace — `<a href='bar'title=x>`
            // is literal text, and the spec has an example asserting exactly that.
            guard sawSpace, isAttributeStart(s[j]) else { return nil }
            j += 1
            while j < count, isAttributeScalar(s[j]) { j += 1 }
            var k = j
            while k < count, isHTMLSpace(s[k]) { k += 1 }
            guard k < count, s[k] == 0x3D else { continue }     // valueless attribute
            k += 1
            while k < count, isHTMLSpace(s[k]) { k += 1 }
            guard k < count else { return nil }
            if s[k] == 0x22 || s[k] == 0x27 {
                let quote = s[k]
                k += 1
                while k < count, s[k] != quote { k += 1 }
                guard k < count else { return nil }             // unterminated value
                j = k + 1
            } else {
                var length = 0
                while k < count, !isHTMLSpace(s[k]), !isForbiddenInBareValue(s[k]) {
                    k += 1; length += 1
                }
                guard length > 0 else { return nil }
                j = k
            }
        }
    }

    private static func isLetter(_ c: UInt16) -> Bool {
        (c | 0x20) >= 0x61 && (c | 0x20) <= 0x7A
    }

    private static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }

    private static func isAttributeStart(_ c: UInt16) -> Bool {
        isLetter(c) || c == 0x5F || c == 0x3A          // _ :
    }

    private static func isAttributeScalar(_ c: UInt16) -> Bool {
        isAttributeStart(c) || isDigit(c) || c == 0x2E || c == 0x2D
    }

    private static func isHTMLSpace(_ c: UInt16) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
    }

    private static func isNameScalar(_ c: UInt16) -> Bool {
        isLetter(c) || isDigit(c) || c == 0x2D
    }

    /// `"`, `'`, `=`, `<`, `>`, `` ` `` — the characters an unquoted attribute
    /// value may not contain.
    private static func isForbiddenInBareValue(_ c: UInt16) -> Bool {
        c == 0x22 || c == 0x27 || c == 0x3D || c == 0x3C || c == 0x3E || c == 0x60
    }

    private static func matches(_ s: [UInt16], at i: Int, _ count: Int, _ text: String) -> Bool {
        let want = Array(text.utf16)
        guard i >= 0, i + want.count <= count else { return false }
        for k in 0..<want.count where s[i + k] != want[k] { return false }
        return true
    }

    private static func find(_ s: [UInt16], from: Int, _ count: Int, _ text: String) -> Int? {
        let want = Array(text.utf16)
        guard want.count <= count else { return nil }
        var i = from
        while i + want.count <= count {
            if matches(s, at: i, count, text) { return i + want.count }
            i += 1
        }
        return nil
    }
}
