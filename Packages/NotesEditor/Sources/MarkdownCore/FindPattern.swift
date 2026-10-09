//
//  FindPattern.swift
//  MarkdownCore
//
//  What the find bar looks for — a phrase, or a regular expression — and what
//  replaces a match.
//
//  A phrase matches as it always has: anywhere, ignoring case. A regular
//  expression is ICU's (`NSRegularExpression`): case-insensitive like a phrase
//  unless it says `(?-i)`, and `^` and `$` match at every line, as a reader of
//  a note expects. Its replacement is a template — `$0`…`$99` are the match and
//  its groups, `\n` and `\t` a newline and a tab, `\\` and `\$` a backslash and
//  a dollar sign. A phrase's replacement is only ever its own text.
//
//  **Every regular-expression search has a time limit.** The find bar searches
//  on each keystroke, on the main actor, and a pattern such as `(a*)*b`
//  backtracks exponentially: over 28 `a`s it was still running after five
//  seconds, and nothing could stop it. Matching with `.reportProgress` calls
//  back *during* the backtracking — 1,511 times in 0.2s, probed — so a
//  deadline can end it, and the pattern is reported as too slow instead of
//  freezing the window (implemented.md §51.39).
//

import Foundation

public struct FindPattern: Sendable, Equatable {
    /// What was typed in the find field.
    public var text: String
    /// Whether `text` is a regular expression rather than a phrase.
    public var isRegularExpression: Bool

    public init(_ text: String, isRegularExpression: Bool = false) {
        self.text = text
        self.isRegularExpression = isRegularExpression
    }

    /// Why a search has nothing to show. The raw value travels to the find
    /// bar, which says it in words.
    public enum Problem: String, Error, Sendable, Equatable {
        /// Not a regular expression ICU can read — `(` while it is being typed.
        case invalid
        /// Ran past its time limit.
        case tooSlow
    }

    /// One match and the text that replaces it.
    public struct Replacement: Equatable {
        public let range: NSRange
        public let text: String
    }

    /// How long one search may run, in seconds: far longer than a reasonable
    /// pattern takes over a long note, and short enough that a runaway one
    /// stalls a keystroke rather than the window.
    public static let timeLimit: Double = 0.5

    /// Every match in `string`, in order.
    public func matches(in string: NSString,
                        timeLimit: Double = FindPattern.timeLimit) -> Result<[NSRange], Problem> {
        guard !text.isEmpty else { return .success([]) }
        guard isRegularExpression else { return .success(phraseMatches(in: string)) }
        return regularExpressionMatches(in: string, timeLimit: timeLimit).map { $0.results.map(\.range) }
    }

    /// Each match with the text that replaces it: `replacement` as written for
    /// a phrase, or expanded as a template, against that match's own groups,
    /// for a regular expression.
    public func replacements(in string: NSString, with replacement: String,
                             timeLimit: Double = FindPattern.timeLimit) -> Result<[Replacement], Problem> {
        guard !text.isEmpty else { return .success([]) }
        guard isRegularExpression else {
            return .success(phraseMatches(in: string).map { Replacement(range: $0, text: replacement) })
        }
        let template = Self.template(replacement)
        return regularExpressionMatches(in: string, timeLimit: timeLimit).map { found in
            found.results.map { result in
                Replacement(range: result.range,
                            text: found.regex.replacementString(for: result, in: found.haystack,
                                                                offset: 0, template: template))
            }
        }
    }

    /// A phrase, anywhere, ignoring case — the search the find bar always had.
    private func phraseMatches(in string: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var searchStart = 0
        while searchStart < string.length {
            let range = string.range(of: text, options: [.caseInsensitive],
                                     range: NSRange(location: searchStart, length: string.length - searchStart))
            guard range.location != NSNotFound else { break }
            result.append(range)
            searchStart = range.location + max(1, range.length)
        }
        return result
    }

    private struct Found {
        let regex: NSRegularExpression
        /// The text searched, as it was: a replacement's groups are read from
        /// it, and an editor's storage is a mutable string.
        let haystack: String
        let results: [NSTextCheckingResult]
    }

    private func regularExpressionMatches(in string: NSString, timeLimit: Double) -> Result<Found, Problem> {
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: text, options: [.caseInsensitive, .anchorsMatchLines])
        } catch {
            return .failure(.invalid)
        }
        // One copy, so every match and every group is read from the same text
        // without bridging the storage again.
        let haystack = (string.copy() as? NSString ?? string) as String
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(Int(timeLimit * 1000)))
        var results: [NSTextCheckingResult] = []
        var ranOut = false
        regex.enumerateMatches(in: haystack, options: [.reportProgress],
                               range: NSRange(location: 0, length: string.length)) { result, _, stop in
            if let result { results.append(result) }
            if clock.now > deadline {
                ranOut = true
                stop.pointee = true
            }
        }
        return ranOut ? .failure(.tooSlow) : .success(Found(regex: regex, haystack: haystack, results: results))
    }

    /// `replacement` as an `NSRegularExpression` template: `\n` and `\t` become
    /// a newline and a tab, which the template language has no spelling for.
    /// Its own escapes — `\\` a backslash, `\$` a dollar sign — are left for it
    /// to read, and a lone backslash at the end is kept as a backslash.
    static func template(_ replacement: String) -> String {
        var template = ""
        var characters = replacement.makeIterator()
        while let character = characters.next() {
            guard character == "\\" else {
                template.append(character)
                continue
            }
            switch characters.next() {
            case "n": template.append("\n")
            case "t": template.append("\t")
            case let other?: template.append("\\"); template.append(other)
            case nil: template.append("\\\\")
            }
        }
        return template
    }
}
