//
//  CodeHighlighterAdapter.swift
//  HelloNotes
//
//  Created by Chris Tham on 17/7/2026.
//
//  The new editor's CodeHighlighting service, backed by HighlighterSwift
//  (highlight.js via JavaScriptCore — ~190 languages, no WebView; chosen
//  after a survey of Apple APIs and the package ecosystem, see
//  docs/implemented.md). An actor confines the non-Sendable JS engine;
//  results are cached by (language, code) since JSCore calls are the
//  expensive part. The editor extracts only foreground colors from the
//  result, so theme/font/metrics stay the editor's own.
//

import Foundation
import Highlighter
import MarkdownEditor

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

actor CodeHighlighterAdapter: CodeHighlighting {
    private let highlighter: Highlighter?
    /// Cached *colour runs*, not the styled string: the runs are all the editor
    /// wants, they are `Sendable` (so they leave this actor without a fight),
    /// and caching them means the `enumerateAttribute` walk is paid once per
    /// snippet rather than on every cache hit. A plain dictionary rather than
    /// `NSCache` because the actor already serializes access and `NSCache`
    /// cannot hold a struct.
    private var cache: [String: [CodeColorRun]] = [:]
    private var cacheOrder: [String] = []
    private var unsupportedLanguages: Set<String> = []

    private let cacheLimit = 256

    /// - Parameter darkMode: picked at creation; the host rebuilds the
    ///   document (and this adapter) when the appearance flips.
    init(darkMode: Bool) {
        let h = Highlighter()
        // Match the Preview, which highlights with highlight.js's GitHub theme
        // (hljs-github.css / hljs-github-dark.css) — so a code block's colours
        // are identical whether you're editing or previewing.
        h?.setTheme(darkMode ? "github-dark" : "github")
        highlighter = h
    }

    func highlight(_ code: String, language: String) async -> [CodeColorRun] {
        guard let highlighter, !language.isEmpty, !unsupportedLanguages.contains(language) else { return [] }
        // Key on language + length + hash rather than the full snippet: including
        // the length makes a collision require same-length AND same-hash (≈never),
        // without duplicating a large code block into the cache key.
        let key = "\(language)\u{1}\(code.count)\u{1}\(code.hashValue)"
        if let cached = cache[key] { return cached }
        guard let styled = highlighter.highlight(code, as: language) else {
            // Unknown language: remember, so repeated fences don't re-enter
            // the JS engine just to fail again.
            unsupportedLanguages.insert(language)
            return []
        }
        var runs: [CodeColorRun] = []
        styled.enumerateAttribute(.foregroundColor,
                                  in: NSRange(location: 0, length: styled.length)) { value, range, _ in
            if let color = value as? PlatformColor {
                runs.append(CodeColorRun(range: range, color: color))
            }
        }
        store(runs, for: key)
        return runs
    }

    private func store(_ runs: [CodeColorRun], for key: String) {
        if cache[key] == nil {
            cacheOrder.append(key)
            if cacheOrder.count > cacheLimit {
                cache.removeValue(forKey: cacheOrder.removeFirst())
            }
        }
        cache[key] = runs
    }
}
