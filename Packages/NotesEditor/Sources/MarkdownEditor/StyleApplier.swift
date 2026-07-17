//
//  StyleApplier.swift
//  MarkdownEditor
//
//  Turns MarkdownCore's semantic style runs into attributed-string
//  attributes. Pure and nonisolated: the open path runs it off the main
//  actor over a scratch NSMutableAttributedString; the editing path runs it
//  on the main actor over the live NSTextStorage for damaged blocks only.
//

import Foundation
import MarkdownCore
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Custom attribute carrying a wiki link's target so the view can route
/// clicks without re-parsing.
nonisolated public let wikiTargetAttribute = NSAttributedString.Key("hn.wikiTarget")
/// Marks concealable marker ranges (for potential future use by hit-testing).
nonisolated let markerAttribute = NSAttributedString.Key("hn.marker")

nonisolated enum StyleApplier {

    /// Wiki-link existence resolution, injected by the app.
    typealias WikiResolver = @Sendable (String) -> Bool

    /// Restyle `blocks` of `parse` in `target`. `revealed` holds the block
    /// indices whose syntax should stay visible (caret inside).
    static func apply(
        blockIndices: some Sequence<Int>,
        parse: ParseResult,
        text: NSString,
        to target: NSMutableAttributedString,
        theme: EditorTheme,
        revealed: Set<Int>,
        resolveWiki: WikiResolver?
    ) {
        target.beginEditing()
        for index in blockIndices where index >= 0 && index < parse.blocks.count {
            let block = parse.blocks[index]
            guard block.range.length > 0,
                  block.range.location + block.range.length <= target.length else { continue }
            applyBase(for: block, to: target, theme: theme)
            let runs = StyleSpec.runs(for: block, text: text, lines: parse.lines)
            let isRevealed = revealed.contains(index)
            for run in runs {
                apply(run, to: target, theme: theme, revealed: isRevealed, resolveWiki: resolveWiki)
            }
        }
        target.endEditing()
    }

    /// Reset a block to its base look (clears stale attributes from previous
    /// structure — a heading demoted to a paragraph must lose its font).
    private static func applyBase(for block: Block, to target: NSMutableAttributedString, theme: EditorTheme) {
        var base: [NSAttributedString.Key: Any] = [
            .font: theme.body,
            .foregroundColor: theme.text,
        ]
        if case .fencedCode = block.kind {
            base[.font] = theme.mono
        }
        target.setAttributes(base, range: block.range)
    }

    private static func apply(
        _ run: StyleRun,
        to target: NSMutableAttributedString,
        theme: EditorTheme,
        revealed: Bool,
        resolveWiki: WikiResolver?
    ) {
        let range = run.range
        guard range.length > 0, range.location + range.length <= target.length else { return }

        // Concealment beats everything: markers vanish when inactive.
        if run.concealment == .whenInactive && !revealed {
            target.addAttributes([
                .font: theme.concealed,
                .foregroundColor: PlatformColor.clear,
                markerAttribute: true,
            ], range: range)
            return
        }

        switch run.role {
        case .body:
            break   // base already applied

        case .headingText(let level):
            target.addAttribute(.font, value: theme.headingFont(level: level), range: range)

        case .strong:
            addTrait(bold: true, italic: nil, in: range, target: target, theme: theme)
        case .emphasis:
            addTrait(bold: nil, italic: true, in: range, target: target, theme: theme)

        case .strikethrough:
            target.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: theme.secondary,
            ], range: range)

        case .highlighted:
            target.addAttribute(.backgroundColor, value: theme.highlightBackground, range: range)

        case .inlineCode:
            target.addAttributes([
                .font: theme.mono,
                .backgroundColor: theme.codeBackground,
            ], range: range)

        case .codeBlock:
            target.addAttributes([
                .font: theme.mono,
                .backgroundColor: theme.codeBackground,
            ], range: range)

        case .codeInfo:
            target.addAttributes([.font: theme.monoSmall, .foregroundColor: theme.secondary], range: range)

        case .mathSource:
            target.addAttributes([.font: theme.mono, .foregroundColor: theme.secondary], range: range)

        case .comment:
            target.addAttribute(.foregroundColor, value: theme.markerColor, range: range)

        case .linkText:
            target.addAttribute(.foregroundColor, value: theme.accent, range: range)

        case .url:
            // Real URLs get a live .link so the view gives hover + click.
            let urlString = (target.string as NSString).substring(with: range)
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: theme.accent]
            if let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true {
                attrs[.link] = url
            }
            target.addAttributes(attrs, range: range)

        case .wikiLink(let target_, let isEmbed):
            let exists = resolveWiki?(Self.baseTitle(of: target_)) ?? true
            var attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: exists ? theme.accent : theme.brokenLink,
                wikiTargetAttribute: target_,
            ]
            if !isEmbed, let encoded = target_.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
               let url = URL(string: "hellonotes-wiki://\(encoded)") {
                attrs[.link] = url
                #if canImport(AppKit)
                attrs[.cursor] = NSCursor.pointingHand
                #endif
            }
            target.addAttributes(attrs, range: range)

        case .tag:
            target.addAttributes([
                .foregroundColor: theme.accent,
                .backgroundColor: theme.accent.withAlphaComponent(0.12),
            ], range: range)

        case .footnote:
            target.addAttributes([.foregroundColor: theme.accent, .font: theme.monoSmall], range: range)

        case .quote:
            target.addAttribute(.foregroundColor, value: theme.secondary, range: range)

        case .calloutTitle:
            target.addAttributes([.font: theme.bodyBold, .foregroundColor: theme.accent], range: range)

        case .listMarker:
            target.addAttributes([.foregroundColor: theme.accent], range: range)

        case .taskMarker(let checked):
            // Conceal the `[ ]`/`[x]` characters (keep the mono width so the
            // layout is stable) and mark them so the fragment draws a real
            // checkbox glyph in their place — clickable to toggle.
            target.addAttributes([
                .font: theme.mono,
                .foregroundColor: PlatformColor.clear,
                taskCheckboxAttribute: checked,
            ], range: range)

        case .thematicBreak:
            target.addAttribute(.foregroundColor, value: theme.markerColor, range: range)

        case .frontMatter:
            target.addAttributes([.font: theme.monoSmall, .foregroundColor: theme.secondary], range: range)

        case .marker:
            target.addAttributes([
                .foregroundColor: theme.markerColor,
                markerAttribute: true,
            ], range: range)
        }
    }

    /// Merge a bold/italic trait into whatever font is already present, so
    /// nested emphasis (`**a *b* c**`) composes instead of replacing.
    private static func addTrait(
        bold: Bool?, italic: Bool?,
        in range: NSRange,
        target: NSMutableAttributedString,
        theme: EditorTheme
    ) {
        target.enumerateAttribute(.font, in: range, options: []) { value, sub, _ in
            let current = value as? PlatformFont ?? theme.body
            let isBold = (bold ?? currentIsBold(current)) || currentIsBold(current)
            let isItalic = (italic ?? currentIsItalic(current)) || currentIsItalic(current)
            let font: PlatformFont =
                switch (isBold, isItalic) {
                case (true, true): theme.bodyBoldItalic
                case (true, false): theme.bodyBold
                case (false, true): theme.bodyItalic
                case (false, false): theme.body
                }
            // Headings keep their size; only body-sized text swaps fonts.
            if current.pointSize == theme.body.pointSize {
                target.addAttribute(.font, value: font, range: sub)
            }
        }
    }

    private static func currentIsBold(_ font: PlatformFont) -> Bool {
        #if canImport(AppKit)
        font.fontDescriptor.symbolicTraits.contains(.bold)
        #else
        font.fontDescriptor.symbolicTraits.contains(.traitBold)
        #endif
    }

    private static func currentIsItalic(_ font: PlatformFont) -> Bool {
        #if canImport(AppKit)
        font.fontDescriptor.symbolicTraits.contains(.italic)
        #else
        font.fontDescriptor.symbolicTraits.contains(.traitItalic)
        #endif
    }

    /// `Note#heading` and `Note|alias` resolve on the note title alone.
    static func baseTitle(of target: String) -> String {
        var t = target
        if let pipe = t.firstIndex(of: "|") { t = String(t[..<pipe]) }
        if let hash = t.firstIndex(of: "#") { t = String(t[..<hash]) }
        return t.trimmingCharacters(in: .whitespaces)
    }
}
