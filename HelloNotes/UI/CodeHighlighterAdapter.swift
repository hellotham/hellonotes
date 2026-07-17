//
//  CodeHighlighterAdapter.swift
//  HelloNotes
//
//  Created by Chris Tham on 17/7/2026.
//
//  The new editor's CodeHighlighting service, backed by HighlighterSwift
//  (highlight.js via JavaScriptCore — ~190 languages, no WebView; chosen
//  after a survey of Apple APIs and the package ecosystem, see
//  docs/editor-rewrite.md). An actor confines the non-Sendable JS engine;
//  results are cached by (language, code) since JSCore calls are the
//  expensive part. The editor extracts only foreground colors from the
//  result, so theme/font/metrics stay the editor's own.
//

#if os(macOS)
import AppKit
import Highlighter
import MarkdownEditor

actor CodeHighlighterAdapter: CodeHighlighting {
    private let highlighter: Highlighter?
    private let cache = NSCache<NSString, NSAttributedString>()
    private var unsupportedLanguages: Set<String> = []

    /// - Parameter darkMode: picked at creation; the host rebuilds the
    ///   document (and this adapter) when the appearance flips.
    init(darkMode: Bool) {
        let h = Highlighter()
        // Match the Preview, which highlights with highlight.js's GitHub theme
        // (hljs-github.css / hljs-github-dark.css) — so a code block's colours
        // are identical whether you're editing or previewing.
        h?.setTheme(darkMode ? "github-dark" : "github")
        highlighter = h
        cache.countLimit = 256
    }

    func highlight(_ code: String, language: String) async -> NSAttributedString? {
        guard let highlighter, !language.isEmpty, !unsupportedLanguages.contains(language) else { return nil }
        let key = "\(language)|\(code.hashValue)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let styled = highlighter.highlight(code, as: language) else {
            // Unknown language: remember, so repeated fences don't re-enter
            // the JS engine just to fail again.
            unsupportedLanguages.insert(language)
            return nil
        }
        cache.setObject(styled, forKey: key)
        return styled
    }
}
#endif
