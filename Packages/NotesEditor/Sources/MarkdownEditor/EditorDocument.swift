//
//  EditorDocument.swift
//  MarkdownEditor
//
//  The document object the app holds instead of a Binding<String>. It owns
//  the NSTextStorage (raw Markdown — the storage IS the document), the
//  incremental parse state, and the per-document undo manager. Text flows
//  out at save granularity via `text`; edits flow out as range-level
//  events via `onEdit` — no per-keystroke whole-string round-trips.
//
//  Styling is progressive: at open, only the first screens are styled
//  (synchronously — open is effectively instant at any size); the rest is
//  styled in idle-time batches and on demand as it scrolls into view. All
//  styling goes through one path, directly into the storage — measured to
//  matter: importing a pre-styled attributed string via
//  setAttributedString leaves NSTextStorage converting attribute-run
//  regions lazily on first touch, up to ~100 ms per region on multi-MB
//  notes, exactly on the user's first keystroke there.
//
//  Editing pipeline (all O(damage), enforced by MarkdownCore's tests):
//    storage mutates → didProcessEditing → incremental reparse → restyle
//    the damaged blocks (inside the same layout pass, so no flash).
//  Caret pipeline:
//    selection change → reveal-set diff → restyle ≤ a few blocks.
//

import Foundation
import Observation
import MarkdownCore
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Multi-language code highlighting for fenced blocks. Implementations run
/// off the main actor (typically an actor wrapping a highlighting engine);
/// the editor extracts only the *foreground colors* from the result — fonts
/// and backgrounds stay the editor theme's — and caches per content hash,
/// so the engine underneath is swappable (highlight.js today, tree-sitter
/// tomorrow) without touching the editor.
public protocol CodeHighlighting: Sendable {
    /// A styled rendering of `code` for `language`, or nil when the
    /// language is unknown or highlighting fails.
    func highlight(_ code: String, language: String) async -> NSAttributedString?
}

/// Services the host app injects. All closures are Sendable (styling can
/// run from any context that owns the document).
public struct EditorServices: Sendable {
    /// Does a note with this title exist? Drives resolved vs. muted wiki links.
    public var wikiLinkExists: (@Sendable (String) -> Bool)?
    /// Fenced-code-block syntax highlighting (async upgrade; optional).
    public var codeHighlighter: (any CodeHighlighting)?
    /// Inline rendering of block embeds (images, Mermaid, math). Optional.
    public var blockRenderer: (any BlockRenderer)?

    public init(
        wikiLinkExists: (@Sendable (String) -> Bool)? = nil,
        codeHighlighter: (any CodeHighlighting)? = nil,
        blockRenderer: (any BlockRenderer)? = nil
    ) {
        self.wikiLinkExists = wikiLinkExists
        self.codeHighlighter = codeHighlighter
        self.blockRenderer = blockRenderer
    }
}

@Observable
public final class EditorDocument {

    // MARK: - Public surface

    /// The raw Markdown, snapshotted from storage. O(n) — call at save
    /// granularity, never per keystroke.
    public var text: String { storage.string }

    /// Bumps on every character edit (for observers that key async work).
    public private(set) var revision = 0

    /// Range-level edit notification, fired after reparse + restyle.
    @ObservationIgnored public var onEdit: ((TextEdit) -> Void)?

    /// The block structure (read-only; used for outline, caret context…).
    public var blocks: [Block] { parse.blocks }

    /// Per-phase timings of the last keystroke cycle — permanent, cheap
    /// introspection so perf regressions are measurable in place.
    public struct EditMetrics: Sendable {
        public var parseMS: Double = 0
        public var restyleMS: Double = 0
    }
    @ObservationIgnored public private(set) var lastEditMetrics = EditMetrics()

    public let theme: EditorTheme
    public let undoManager = UndoManager()

    /// The editor's current selection, mirrored from the view on every
    /// change — so AI actions and commands can read it without a view
    /// reference.
    public private(set) var selectedRange = NSRange(location: 0, length: 0)

    /// Substring access without snapshotting the whole document.
    public func text(in range: NSRange) -> String {
        guard range.location >= 0, range.location + range.length <= storage.length else { return "" }
        return storage.mutableString.substring(with: range)
    }

    // MARK: - Internals

    let storage = NSTextStorage()
    private(set) var parse: ParseResult
    private let services: EditorServices
    private var revealedBlocks: Set<Int> = []
    private var isApplyingStyles = false
    private let storageDelegate = StorageDelegate()

    /// Progressive styling state: which blocks carry current styling.
    /// (Bitset aligned with `parse.blocks`; rebuilt conservatively on edits
    /// that land before the initial pass finishes.)
    private var styledBlocks: [Bool] = []
    private var stylingTask: Task<Void, Never>?

    /// How many characters get styled synchronously at open — a few screens
    /// of any realistic font size.
    private static let initialStyledPrefix = 30_000

    // MARK: - Init

    public init(text: String, theme: EditorTheme = EditorTheme(), services: EditorServices = EditorServices()) {
        self.theme = theme
        self.services = services

        let ns = text as NSString
        self.parse = BlockParser.fullParse(ns)
        storage.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: theme.body,
            .foregroundColor: theme.text,
        ]))
        styledBlocks = Array(repeating: false, count: parse.blocks.count)

        // First screens styled before the view ever draws.
        ensureStyled(charactersIn: NSRange(location: 0, length: min(Self.initialStyledPrefix, storage.length)))
        scheduleBackgroundStyling()

        storageDelegate.document = self
        storage.delegate = storageDelegate
    }

    /// Async factory retained for API symmetry; open is cheap enough to be
    /// synchronous now (full parse of 3.8 MB ≈ 12 ms; styling is lazy).
    public static func make(
        text: String,
        theme: EditorTheme = EditorTheme(),
        services: EditorServices = EditorServices()
    ) async -> EditorDocument {
        EditorDocument(text: text, theme: theme, services: services)
    }

    // MARK: - Programmatic replacement (load, external reload)

    public func replaceText(_ newText: String) {
        stylingTask?.cancel()
        let ns = newText as NSString
        parse = BlockParser.fullParse(ns)
        isApplyingStyles = true
        storage.setAttributedString(NSAttributedString(string: newText, attributes: [
            .font: theme.body,
            .foregroundColor: theme.text,
        ]))
        isApplyingStyles = false
        styledBlocks = Array(repeating: false, count: parse.blocks.count)
        revealedBlocks = []
        ensureStyled(charactersIn: NSRange(location: 0, length: min(Self.initialStyledPrefix, storage.length)))
        scheduleBackgroundStyling()
        undoManager.removeAllActions()
        revision &+= 1
    }

    // MARK: - Progressive styling

    /// Style every not-yet-styled block intersecting `range`. The view
    /// calls this as content scrolls into view; the background pass calls
    /// it batch by batch. Idempotent and cheap on styled regions.
    public func ensureStyled(charactersIn range: NSRange) {
        guard !parse.blocks.isEmpty else { return }
        guard let lo = parse.blockIndex(at: max(0, min(range.location, storage.length))),
              let hi = parse.blockIndex(at: max(0, min(range.location + range.length, storage.length)))
        else { return }
        var pending: [Int] = []
        for i in lo...hi where !(styledBlocks.indices.contains(i) && styledBlocks[i]) {
            pending.append(i)
        }
        guard !pending.isEmpty else { return }
        restyle(blockIndices: Set(pending), revealed: revealedBlocks)
        for i in pending where styledBlocks.indices.contains(i) { styledBlocks[i] = true }
    }

    /// Walk the document once in idle-time batches until everything is
    /// styled. Restarted (debounced) if an edit lands mid-pass, because a
    /// splice shifts block indices out from under the bitset.
    private func scheduleBackgroundStyling(afterIdle: Bool = false) {
        stylingTask?.cancel()
        guard styledBlocks.contains(false) else { return }
        stylingTask = Task { @MainActor [weak self] in
            if afterIdle {
                try? await Task.sleep(for: .milliseconds(400))
            }
            guard !Task.isCancelled else { return }
            var cursor = 0
            while let self, !Task.isCancelled {
                guard cursor < self.styledBlocks.count else { break }
                guard let next = self.styledBlocks[cursor...].firstIndex(of: false) else { break }
                let batchEnd = min(next + 250, self.styledBlocks.count)
                let indices = Set((next..<batchEnd).filter { !self.styledBlocks[$0] })
                self.restyle(blockIndices: indices, revealed: self.revealedBlocks)
                for i in indices { self.styledBlocks[i] = true }
                cursor = batchEnd
                await Task.yield()
            }
            if let self, !Task.isCancelled { self.absorbFirstEditCost() }
        }
    }

    /// The first *character* edit deep into a large storage pays a one-time
    /// lazy-structure cost inside NSTextStorage (~90 ms at 3.8 MB, measured
    /// regardless of how styling was applied). Absorb it with a net-zero
    /// synthetic edit while idle so the user's first real keystroke doesn't.
    private func absorbFirstEditCost() {
        guard storage.length > 100_000 else { return }
        let mid = storage.length / 2
        isApplyingStyles = true          // net-zero: parse stays valid
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: mid, length: 0), with: " ")
        storage.replaceCharacters(in: NSRange(location: mid, length: 1), with: "")
        storage.endEditing()
        isApplyingStyles = false
    }

    /// Complete all pending styling synchronously (tests; pre-print/export).
    /// Applies in the same batch sizes as the background walker — separate
    /// processEditing passes are what settle NSTextStorage's lazy internal
    /// structures region by region (one mega-batch measurably does not).
    public func styleEverythingNow() {
        stylingTask?.cancel()
        var cursor = 0
        while cursor < styledBlocks.count {
            guard let next = styledBlocks[cursor...].firstIndex(of: false) else { break }
            let batchEnd = min(next + 250, styledBlocks.count)
            let indices = Set((next..<batchEnd).filter { !styledBlocks[$0] })
            restyle(blockIndices: indices, revealed: revealedBlocks)
            for i in indices { styledBlocks[i] = true }
            cursor = batchEnd
        }
        absorbFirstEditCost()
    }

    // MARK: - Editing pipeline

    /// Called by the storage delegate after characters change.
    fileprivate func storageDidEdit(editedRange: NSRange, changeInLength delta: Int) {
        guard !isApplyingStyles else { return }
        let oldRange = NSRange(location: editedRange.location, length: editedRange.length - delta)
        let edit = TextEdit(range: oldRange, replacementLength: editedRange.length)

        var t0 = DispatchTime.now()
        let hadPendingStyling = styledBlocks.contains(false)
        parse = BlockParser.incremental(storage.mutableString, edit: edit, previous: parse)
        lastEditMetrics.parseMS = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        t0 = DispatchTime.now()

        // Restyle the blocks covering the new text (plus one neighbor each
        // side — an edit can change how adjacent blocks read, and restyling
        // a block is cheap).
        var damaged = Set<Int>()
        if let lo = parse.blockIndex(at: edit.newRange.location) {
            let hi = parse.blockIndex(at: max(edit.newRange.location, edit.newRange.location + edit.newRange.length)) ?? lo
            for i in max(0, lo - 1)...min(parse.blocks.count - 1, hi + 1) { damaged.insert(i) }
        }

        // The splice shifted block indices; the styled bitset is only
        // trustworthy when the initial pass has already finished (then
        // everything is styled and stays styled — edits restyle in place).
        if hadPendingStyling {
            styledBlocks = Array(repeating: false, count: parse.blocks.count)
            // Don't leave the visible area unstyled while the pass restarts.
            ensureStyled(charactersIn: NSRange(
                location: max(0, edit.newRange.location - Self.initialStyledPrefix / 2),
                length: Self.initialStyledPrefix))
            scheduleBackgroundStyling(afterIdle: true)
        } else if styledBlocks.count != parse.blocks.count {
            styledBlocks = Array(repeating: true, count: parse.blocks.count)
        }

        if externalSessionDepth > 0 {
            // A Writing Tools / AI session owns the presentation right now;
            // remember the damage and restyle when it ends.
            externalSessionDamage.formUnion(damaged)
        } else {
            let stillRevealed = damaged.union(revealedBlocks)
            restyle(blockIndices: damaged, revealed: stillRevealed)
            if !hadPendingStyling {
                for i in damaged where styledBlocks.indices.contains(i) { styledBlocks[i] = true }
            }
        }
        lastEditMetrics.restyleMS = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6

        revision &+= 1
        onEdit?(edit)
    }

    // MARK: - External text sessions (Writing Tools, AI rewrites)

    /// While an external session rewrites text (Apple Intelligence Writing
    /// Tools, an AI action), the parse stays live per edit — correctness —
    /// but restyling pauses so our attributes never fight the session's own
    /// decorations (proofreading underlines, animations). Damaged blocks
    /// are collected and restyled once when the session ends.
    @ObservationIgnored private var externalSessionDepth = 0
    @ObservationIgnored private var externalSessionDamage = Set<Int>()

    public func beginExternalTextSession() {
        externalSessionDepth += 1
    }

    public func endExternalTextSession() {
        externalSessionDepth = max(0, externalSessionDepth - 1)
        guard externalSessionDepth == 0, !externalSessionDamage.isEmpty else { return }
        // Indices may have shifted across the session's edits; restyle a
        // generous window around what was touched.
        let lo = max(0, (externalSessionDamage.min() ?? 0) - 2)
        let hi = min(parse.blocks.count - 1, (externalSessionDamage.max() ?? 0) + 2)
        externalSessionDamage = []
        if lo <= hi {
            restyle(blockIndices: Set(lo...hi), revealed: revealedBlocks)
        }
    }

    // MARK: - Caret-driven syntax reveal

    /// The view reports every selection change here; blocks whose reveal
    /// state flips get restyled (usually 0–2 blocks — O(paragraph), the
    /// property the old engine never had).
    public func selectionDidChange(_ selection: NSRange) {
        selectedRange = selection
        guard externalSessionDepth == 0 else { return }
        var newRevealed = Set<Int>()
        if let lo = parse.blockIndex(at: selection.location) {
            newRevealed.insert(lo)
            if selection.length > 0,
               let hi = parse.blockIndex(at: selection.location + selection.length) {
                // Reveal at most the boundary blocks of a selection — a
                // select-all must not restyle the world.
                newRevealed.insert(hi)
            }
        }
        guard newRevealed != revealedBlocks else { return }
        let changed = newRevealed.symmetricDifference(revealedBlocks)
        revealedBlocks = newRevealed
        restyle(blockIndices: changed, revealed: newRevealed)
    }

    // MARK: - Queries

    /// What the caret is inside, for the autocomplete popup: an (open or
    /// closed) `[[wiki link]]` or a `#tag` being typed.
    public struct InlineContext: Equatable {
        public enum Kind: Equatable { case wikiLink, tag }
        public var kind: Kind
        /// The whole construct, markers included — what acceptance replaces.
        public var range: NSRange
        /// The text typed so far, markers stripped.
        public var query: String
    }

    /// Inline context at `location`, or nil in plain text. Scans only the
    /// caret's line — O(line) on every caret move.
    public func inlineContext(at location: Int) -> InlineContext? {
        let ns: NSString = storage.mutableString
        guard location >= 0, location <= ns.length else { return nil }
        guard let blockIdx = parse.blockIndex(at: location) else { return nil }
        guard parse.blocks[blockIdx].hasInlineContent else { return nil }
        let line = ns.lineRange(for: NSRange(location: min(location, max(0, ns.length - 1)), length: 0))
        var lineEnd = line.location + line.length
        if lineEnd > line.location, ns.character(at: lineEnd - 1) == 0x0A { lineEnd -= 1 }

        // Walk back for an unmatched "[[" before the caret (no "]]" or
        // newline between it and the caret).
        var i = location - 1
        while i > line.location {
            let c = ns.character(at: i)
            let prev = ns.character(at: i - 1)
            if c == 0x5D && prev == 0x5D { break }               // "]]" — closed before caret
            if c == 0x5B && prev == 0x5B {
                let openStart = i - 1
                // A closing "]]" between the caret and line end, if any.
                var close: Int? = nil
                var j = location
                while j + 1 < lineEnd {
                    if ns.character(at: j) == 0x5D, ns.character(at: j + 1) == 0x5D { close = j; break }
                    j += 1
                }
                let contentEnd = close ?? location
                let end = close.map { $0 + 2 } ?? location
                let query = ns.substring(with: NSRange(location: i + 1, length: max(0, contentEnd - (i + 1))))
                return InlineContext(kind: .wikiLink,
                                     range: NSRange(location: openStart, length: end - openStart),
                                     query: query)
            }
            i -= 1
        }

        // A "#tag" run containing the caret.
        var start = location
        while start > line.location {
            let c = ns.character(at: start - 1)
            let isTagChar = (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
                || c == 0x5F || c == 0x2F || c == 0x2D || c > 0x7F
            if isTagChar { start -= 1; continue }
            if c == 0x23 { // '#'
                let boundaryOK = start - 1 == line.location || {
                    let b = ns.character(at: start - 2)
                    return !((b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b > 0x7F)
                }()
                if boundaryOK, location > start - 1 + 1 {
                    let query = ns.substring(with: NSRange(location: start, length: location - start))
                    return InlineContext(kind: .tag,
                                         range: NSRange(location: start - 1, length: location - (start - 1)),
                                         query: query)
                }
            }
            break
        }
        return nil
    }

    /// Case-insensitive matches of `query` (find bar, scroll-to-heading).
    public func findMatches(of query: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let ns: NSString = storage.mutableString
        var result: [NSRange] = []
        var searchStart = 0
        while searchStart < ns.length {
            let r = ns.range(of: query, options: [.caseInsensitive],
                             range: NSRange(location: searchStart, length: ns.length - searchStart))
            guard r.location != NSNotFound else { break }
            result.append(r)
            searchStart = r.location + max(1, r.length)
        }
        return result
    }

    /// Document headings (outline, scroll targets).
    public func headings() -> [(level: Int, title: String, range: NSRange)] {
        let ns: NSString = storage.mutableString
        return parse.blocks.compactMap { block in
            guard case .heading(let level, let setext) = block.kind else { return nil }
            var r = block.range
            if setext, block.lineCount >= 2 {
                r = parse.lines.contentRange(block.firstLine, in: ns)
            }
            var title = ns.substring(with: r)
                .trimmingCharacters(in: CharacterSet(charactersIn: "# \n"))
            if let newline = title.firstIndex(of: "\n") { title = String(title[..<newline]) }
            return (level, title, block.range)
        }
    }

    // MARK: - Restyle

    private func restyle(blockIndices: Set<Int>, revealed: Set<Int>) {
        guard !blockIndices.isEmpty else { return }
        isApplyingStyles = true
        StyleApplier.apply(
            blockIndices: blockIndices.sorted(),
            parse: parse,
            text: storage.mutableString,
            to: storage,
            theme: theme,
            revealed: revealed,
            resolveWiki: services.wikiLinkExists
        )
        isApplyingStyles = false
        if services.codeHighlighter != nil {
            for index in blockIndices { refreshHighlight(blockIndex: index) }
        }
        #if canImport(AppKit)
        if services.blockRenderer != nil {
            for index in blockIndices { refreshBlockEmbed(blockIndex: index, revealed: revealed.contains(index)) }
        }
        #endif
    }

    // MARK: - Fenced-code syntax highlighting

    /// Color runs per (code, language) hash, in code-relative coordinates.
    /// Cached on the document so a restyle (base styling wipes attributes)
    /// re-applies colors *synchronously* — no flash when the caret enters
    /// or leaves a code block. Misses fetch asynchronously.
    @ObservationIgnored private var highlightColorCache: [Int: [(NSRange, PlatformColor)]] = [:]
    @ObservationIgnored private var highlightsInFlight: Set<Int> = []

    private func refreshHighlight(blockIndex: Int) {
        guard let highlighter = services.codeHighlighter,
              blockIndex >= 0, blockIndex < parse.blocks.count else { return }
        let block = parse.blocks[blockIndex]
        guard case .fencedCode(let info, let closed) = block.kind, !info.isEmpty else { return }

        // The code body: lines between the fences.
        let bodyFirst = block.firstLine + 1
        let bodyLast = block.firstLine + block.lineCount - (closed ? 2 : 1)
        guard bodyFirst <= bodyLast else { return }
        let ns: NSString = storage.mutableString
        let start = parse.lines.lineRange(bodyFirst).location
        let endLine = parse.lines.contentRange(bodyLast, in: ns)
        let bodyRange = NSRange(location: start, length: max(0, endLine.location + endLine.length - start))
        guard bodyRange.length > 0, bodyRange.location + bodyRange.length <= ns.length else { return }

        let code = ns.substring(with: bodyRange)
        // The fence info string may carry extras ("swift {title}"): the
        // language is its first word.
        let language = info.split(separator: " ").first.map(String.init)?.lowercased() ?? info.lowercased()

        var hasher = Hasher()
        hasher.combine(code)
        hasher.combine(language)
        let key = hasher.finalize()

        if let runs = highlightColorCache[key] {
            applyHighlight(runs: runs, at: bodyRange.location)
            return
        }
        guard !highlightsInFlight.contains(key) else { return }
        highlightsInFlight.insert(key)

        Task { [weak self] in
            let styled = await highlighter.highlight(code, language: language)
            guard let self else { return }
            self.highlightsInFlight.remove(key)
            guard let styled else { return }
            var runs: [(NSRange, PlatformColor)] = []
            styled.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: styled.length)) { value, range, _ in
                if let color = value as? PlatformColor { runs.append((range, color)) }
            }
            if self.highlightColorCache.count > 128 { self.highlightColorCache.removeAll() }
            self.highlightColorCache[key] = runs
            // The text may have shifted while the highlight ran; re-derive
            // the block from the body's old location and apply only if its
            // content still matches (otherwise the next restyle picks the
            // cached runs up).
            if let idx = self.parse.blockIndex(at: min(bodyRange.location, max(0, self.storage.length - 1))),
               case .fencedCode = self.parse.blocks[idx].kind {
                self.refreshHighlight(blockIndex: idx)
            }
        }
    }

    /// Overlay foreground colors onto the code body. Colors only — fonts,
    /// backgrounds, and metrics stay the editor theme's, so highlighting
    /// can never change layout.
    private func applyHighlight(runs: [(NSRange, PlatformColor)], at base: Int) {
        guard !runs.isEmpty else { return }
        isApplyingStyles = true
        storage.beginEditing()
        let limit = storage.length
        for (range, color) in runs {
            let target = NSRange(location: base + range.location, length: range.length)
            guard target.location + target.length <= limit else { continue }
            storage.addAttribute(.foregroundColor, value: color, range: target)
        }
        storage.endEditing()
        isApplyingStyles = false
    }

    // MARK: - Block embeds (inline-rendered images / diagrams / math)

    #if canImport(AppKit)
    /// Rendered image per (kind) content hash. Cached so a restyle re-applies
    /// the collapse+image synchronously (no flash on caret enter/leave).
    @ObservationIgnored private var blockImageCache: [Int: NSImage] = [:]
    @ObservationIgnored private var blockRendersInFlight: Set<Int> = []

    /// The renderable embed a block represents, or nil. A standalone image
    /// embed is a paragraph whose entire content is one `![[…]]`.
    private func blockEmbedKind(at blockIndex: Int) -> BlockEmbedKind? {
        guard blockIndex >= 0, blockIndex < parse.blocks.count else { return nil }
        let block = parse.blocks[blockIndex]
        let ns: NSString = storage.mutableString
        switch block.kind {
        case .fencedCode(let info, let closed):
            guard closed, info.split(separator: " ").first.map(String.init)?.lowercased() == "mermaid" else { return nil }
            let bodyFirst = block.firstLine + 1
            let bodyLast = block.firstLine + block.lineCount - 2
            guard bodyFirst <= bodyLast else { return nil }
            let start = parse.lines.lineRange(bodyFirst).location
            let end = parse.lines.contentRange(bodyLast, in: ns)
            return .mermaid(source: ns.substring(with: NSRange(location: start, length: end.location + end.length - start)))
        case .mathBlock(let closed):
            guard closed else { return nil }
            let src = ns.substring(with: block.range)
                .trimmingCharacters(in: CharacterSet(charactersIn: "$\n "))
            return src.isEmpty ? nil : .math(source: src)
        case .paragraph:
            // Exactly one `![[target]]` filling the paragraph's content.
            var content = block.range
            if content.length > 0, ns.character(at: content.location + content.length - 1) == 0x0A { content.length -= 1 }
            let nodes = InlineParser.parse(ns, in: content)
            guard nodes.count == 1, case .wikiLink(let target, true) = nodes[0].kind,
                  nodes[0].range.location == content.location,
                  nodes[0].range.length == content.length else { return nil }
            return .image(target: target)
        default:
            return nil
        }
    }

    private func refreshBlockEmbed(blockIndex: Int, revealed: Bool) {
        guard let renderer = services.blockRenderer,
              let kind = blockEmbedKind(at: blockIndex) else { return }
        // Caret inside → show source, don't collapse (base restyle already
        // cleared any prior collapse).
        guard !revealed else { return }

        let block = parse.blocks[blockIndex]
        var content = block.range
        let ns: NSString = storage.mutableString
        if content.length > 0, content.location + content.length <= ns.length,
           ns.character(at: content.location + content.length - 1) == 0x0A { content.length -= 1 }
        guard content.length > 0, content.location + content.length <= ns.length else { return }

        var hasher = Hasher()
        hasher.combine(kind)
        let key = hasher.finalize()

        if let image = blockImageCache[key] {
            collapse(range: content, to: image)
            return
        }
        guard !blockRendersInFlight.contains(key) else { return }
        blockRendersInFlight.insert(key)

        let maxWidth = renderMaxWidth
        let dark = isDarkAppearance
        Task { [weak self] in
            let image = await renderer.render(kind, maxWidth: maxWidth, darkMode: dark)
            guard let self else { return }
            self.blockRendersInFlight.remove(key)
            guard let image else { return }
            if self.blockImageCache.count > 64 { self.blockImageCache.removeAll() }
            self.blockImageCache[key] = image
            // Re-derive the block (text may have shifted) and re-apply if it's
            // still the same kind and not currently revealed.
            if let idx = self.parse.blockIndex(at: min(content.location, max(0, self.storage.length - 1))),
               !self.revealedBlocks.contains(idx),
               self.blockEmbedKind(at: idx) == kind {
                self.refreshBlockEmbed(blockIndex: idx, revealed: false)
            }
        }
    }

    /// Collapse a block's source to near-zero height and reserve the image's
    /// height below it (drawn by RenderedBlockFragment). Source stays in the
    /// storage — concealed, not deleted.
    private func collapse(range: NSRange, to image: NSImage) {
        guard range.location + range.length <= storage.length else { return }
        isApplyingStyles = true
        storage.beginEditing()
        // Collapse the source line(s).
        storage.addAttribute(.font, value: theme.concealed, range: range)
        storage.addAttribute(.foregroundColor, value: PlatformColor.clear, range: range)
        // Reserve the image band under the paragraph.
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = image.size.height + 2 * RenderedBlockFragment.imageGap
        storage.addAttribute(.paragraphStyle, value: para, range: range)
        // Mark the first char so the fragment knows to draw.
        storage.addAttribute(blockImageAttribute, value: image, range: NSRange(location: range.location, length: 1))
        storage.endEditing()
        isApplyingStyles = false
    }

    /// The usable text width for sizing rendered images.
    @ObservationIgnored public var renderMaxWidth: CGFloat = 640
    /// Whether the host is in dark appearance (host updates on change).
    @ObservationIgnored public var isDarkAppearance = false
    #endif
}

// MARK: - Storage delegate bridge

#if canImport(AppKit)
private typealias StorageEditActions = NSTextStorageEditActions
#else
private typealias StorageEditActions = NSTextStorage.EditActions
#endif

/// Small NSObject bridge (EditorDocument itself stays a pure @Observable).
private final class StorageDelegate: NSObject, NSTextStorageDelegate {
    weak var document: EditorDocument?

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: StorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            document?.storageDidEdit(editedRange: editedRange, changeInLength: delta)
        }
    }
}
