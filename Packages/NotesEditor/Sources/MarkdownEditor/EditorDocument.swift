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
    /// The foreground colours for `code` in `language`, or empty when the
    /// language is unknown or highlighting fails.
    func highlight(_ code: String, language: String) async -> [CodeColorRun]
}

/// One run of syntax colour: a range in the code, and the colour to draw it in.
///
/// The protocol used to hand back a whole `NSAttributedString`, which the editor
/// then mined for `.foregroundColor` and threw away. That was both more than it
/// needed and not `Sendable` — an implementation running on an actor (the usual
/// shape, since highlighting engines are not thread-safe) could not return one
/// without crossing an isolation boundary with a mutable-by-subclass class.
/// Returning the runs is what the editor actually wanted, and it crosses safely.
///
/// `nonisolated` because the target defaults to `MainActor` isolation, and a
/// value whose whole purpose is to be *returned from* a highlighting actor
/// cannot have a main-actor initializer.
public nonisolated struct CodeColorRun: Sendable {
    public let range: NSRange
    public let color: PlatformColor

    public init(range: NSRange, color: PlatformColor) {
        self.range = range
        self.color = color
    }
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

    /// Fired after a restyle, with the character range whose styling changed.
    ///
    /// Styling is not purely a matter of attributes here: block decorations —
    /// a blockquote's gutter bar, a callout's band — are painted by the layout
    /// *fragment*, which only repaints when TextKit re-lays out that range. The
    /// background styling pass already calls `invalidateLayout` for exactly this
    /// reason (`ensureVisibleRangeStyled`), but the caret-driven path did not,
    /// so a block that gained a decoration while the caret sat in it could keep
    /// the old rendering after the caret left: the `>` concealed in the model,
    /// no bar on screen.
    @ObservationIgnored public var onRestyle: ((NSRange) -> Void)?

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
    /// Lines whose raw Markdown is showing — the caret's line, and the boundary
    /// lines of a selection. Inline syntax reveals per *line* (Bear/Obsidian
    /// behaviour); only folds and rendered-block embeds reveal per block.
    private var revealedLines: Set<Int> = []
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
        revealedLines = []
        // Invalidate the whole-document GFM-run cache BEFORE styling the new
        // text: `revision` isn't bumped until the end of this method, so an
        // unreset cache (stamped equal by a prior caret move) would make
        // `currentGFMRuns` apply the OLD document's inline runs to the new
        // storage — bold/link/code at the wrong offsets on the styled prefix.
        gfmRunsCacheRevision = -1
        ensureStyled(charactersIn: NSRange(location: 0, length: min(Self.initialStyledPrefix, storage.length)))
        scheduleBackgroundStyling()
        undoManager.removeAllActions()
        revision &+= 1
    }

    // MARK: - Progressive styling

    /// Style every not-yet-styled block intersecting `range`. The view
    /// calls this as content scrolls into view; the background pass calls
    /// it batch by batch. Idempotent and cheap on styled regions.
    /// Style any not-yet-styled blocks intersecting `range`. Returns the
    /// character range actually restyled (nil if nothing was pending) so the
    /// caller can invalidate TextKit 2 layout for it: concealment changes a
    /// run's font size, and an attribute-only edit does not force a re-layout
    /// of a fragment TextKit already laid out at the body font — without the
    /// invalidation a first-seen concealed marker stays full-width (invisible
    /// but occupying space) until some later edit happens to re-lay it out.
    @discardableResult
    public func ensureStyled(charactersIn range: NSRange) -> NSRange? {
        guard !parse.blocks.isEmpty else { return nil }
        guard let lo = parse.blockIndex(at: max(0, min(range.location, storage.length))),
              let hi = parse.blockIndex(at: max(0, min(range.location + range.length, storage.length)))
        else { return nil }
        var pending: [Int] = []
        for i in lo...hi where !(styledBlocks.indices.contains(i) && styledBlocks[i]) {
            pending.append(i)
        }
        guard !pending.isEmpty else { return nil }
        restyle(blockIndices: Set(pending), revealed: revealedBlocks, revealedLines: revealedLines)
        for i in pending where styledBlocks.indices.contains(i) { styledBlocks[i] = true }
        let lowBlock = parse.blocks[pending.min()!].range
        let highBlock = parse.blocks[pending.max()!].range
        return NSRange(location: lowBlock.location,
                       length: highBlock.location + highBlock.length - lowBlock.location)
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
                self.restyle(blockIndices: indices, revealed: self.revealedBlocks, revealedLines: self.revealedLines)
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
    /// The window switched between Light and Dark.
    ///
    /// Rendered blocks are *images*, so unlike text attributes they do not
    /// follow the appearance on their own — they have to be drawn again in the
    /// new one. Marking every block unstyled is what makes the styling pass
    /// re-derive them; the caches now key on appearance, so the second render
    /// is a genuine miss rather than a stale hit.
    ///
    /// - Returns: `true` if anything needed redrawing.
    @discardableResult
    public func appearanceDidChange(isDark: Bool) -> Bool {
        guard isDark != isDarkAppearance else { return false }
        isDarkAppearance = isDark
        for i in styledBlocks.indices { styledBlocks[i] = false }
        styleEverythingNow()
        return true
    }

    public func styleEverythingNow() {
        stylingTask?.cancel()
        var cursor = 0
        while cursor < styledBlocks.count {
            guard let next = styledBlocks[cursor...].firstIndex(of: false) else { break }
            let batchEnd = min(next + 250, styledBlocks.count)
            let indices = Set((next..<batchEnd).filter { !styledBlocks[$0] })
            restyle(blockIndices: indices, revealed: revealedBlocks, revealedLines: revealedLines)
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
        #if canImport(AppKit)
        remapFoldedCallouts(oldRange: oldRange, delta: delta)
        #endif

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
            // While typing, reveal the *lines* being edited — not every line of
            // every damaged block, which would strip the bars off a whole
            // blockquote the moment you touched any line of it.
            let editedLines = lineNumbers(coveringCharactersIn: edit.newRange)
            let stillRevealed = damaged.union(revealedBlocks)
            restyle(blockIndices: damaged, revealed: stillRevealed,
                    revealedLines: editedLines.union(revealedLines))
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
            restyle(blockIndices: Set(lo...hi), revealed: revealedBlocks, revealedLines: revealedLines)
        }
    }

    /// The line numbers a character range touches (a caret touches one).
    private func lineNumbers(coveringCharactersIn range: NSRange) -> Set<Int> {
        guard storage.length > 0 else { return [0] }
        let start = min(max(0, range.location), max(0, storage.length - 1))
        let end = min(max(start, range.location + range.length), max(0, storage.length - 1))
        let first = parse.lines.lineNumber(at: start)
        let last = parse.lines.lineNumber(at: end)
        guard first <= last else { return [first] }
        return Set(first...last)
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
        let newRevealedLines = lineNumbers(coveringCharactersIn: selection)
        guard newRevealed != revealedBlocks || newRevealedLines != revealedLines else { return }
        // Blocks whose reveal state flipped, plus — when the caret merely moved
        // to another line of the same block — that block, since its per-line
        // concealment changed even though the block set did not.
        var changed = newRevealed.symmetricDifference(revealedBlocks)
        if newRevealedLines != revealedLines {
            changed.formUnion(newRevealed)
            changed.formUnion(revealedBlocks)
        }
        revealedBlocks = newRevealed
        revealedLines = newRevealedLines
        guard !changed.isEmpty else { return }
        restyle(blockIndices: changed, revealed: newRevealed, revealedLines: newRevealedLines)
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

    /// Whether `range` is source rather than prose — a fenced or indented code
    /// block, display maths, or front matter. The spell checker has nothing
    /// useful to say about any of them.
    ///
    /// This is not only noise: when such a block is collapsed to a rendered
    /// image its source is concealed with a 0.1pt font, but the misspelling
    /// underline is drawn by the spell checker and **not** scaled by the font —
    /// so the squiggle survives at full weight and paints a stray red dash
    /// above the formula. A Mermaid fence escaped it only by luck, because
    /// `graph`, `Start`, `Middle` and `End` are all real words.
    public func isSourceOnly(_ range: NSRange) -> Bool {
        guard storage.length > 0 else { return false }
        let probe = min(max(0, range.location), storage.length - 1)
        guard let index = parse.blockIndex(at: probe), index < parse.blocks.count else { return false }
        switch parse.blocks[index].kind {
        case .fencedCode, .indentedCode, .mathBlock, .frontMatter: return true
        default: return false
        }
    }

    /// The heading a VoiceOver headings rotor should move to: the first one
    /// after `location`, or before it when searching backwards. `location`
    /// is nil when the rotor has no current item, which starts from whichever
    /// end the search direction implies.
    ///
    /// `filter` is the rotor's search field. Ignoring it — as both platform
    /// views used to — makes typing there look broken: VoiceOver narrows
    /// nothing and keeps stepping through every heading.
    ///
    /// Lives here rather than in the views because AppKit and UIKit each had
    /// their own copy of this walk, and only one coordinate system difference
    /// actually separates them.
    public func rotorHeading(
        after location: Int?,
        forward: Bool,
        matching filter: String = ""
    ) -> (level: Int, title: String, range: NSRange)? {
        var candidates = headings()
        if !filter.isEmpty {
            candidates = candidates.filter { $0.title.localizedCaseInsensitiveContains(filter) }
        }
        guard !candidates.isEmpty else { return nil }
        guard let location else { return forward ? candidates.first : candidates.last }
        return forward
            ? candidates.first { $0.range.location > location }
            : candidates.last { $0.range.location < location }
    }

    // MARK: - Restyle

    /// Whole-document cmark-gfm inline style runs, cached per `revision` so pure
    /// caret moves (which restyle without editing) don't re-parse. cmark isn't
    /// incremental, so this is one whole-document parse per edit — measured at
    /// ~4.7 ms for a 200 KB note, comfortably sub-frame; above the size gate the
    /// overlay is skipped and StyleSpec alone styles inline.
    @ObservationIgnored private var gfmRunsCache: [StyleRun] = []
    @ObservationIgnored private var gfmRunsCacheRevision = -1

    private func currentGFMRuns() -> [StyleRun] {
        guard revision != gfmRunsCacheRevision else { return gfmRunsCache }
        gfmRunsCacheRevision = revision
        let ns: NSString = storage.mutableString
        gfmRunsCache = ns.length < StyleApplier.gfmOverlayMaxLength
            ? GFMLiveStyle.runs(ns) : []
        return gfmRunsCache
    }

    /// Tell the view which characters were restyled, so the layout fragments
    /// covering them repaint their decorations.
    private func notifyRestyled(_ blockIndices: Set<Int>) {
        guard onRestyle != nil else { return }
        var lo = Int.max, hi = 0
        for index in blockIndices where parse.blocks.indices.contains(index) {
            let range = parse.blocks[index].range
            lo = min(lo, range.location)
            hi = max(hi, range.location + range.length)
        }
        guard lo < hi else { return }
        onRestyle?(NSRange(location: lo, length: hi - lo))
    }

    private func restyle(blockIndices: Set<Int>, revealed: Set<Int>, revealedLines: Set<Int>) {
        guard !blockIndices.isEmpty else { return }
        isApplyingStyles = true
        StyleApplier.apply(
            blockIndices: blockIndices.sorted(),
            parse: parse,
            text: storage.mutableString,
            to: storage,
            theme: theme,
            revealedLines: revealedLines,
            resolveWiki: services.wikiLinkExists,
            gfmRuns: currentGFMRuns()
        )
        isApplyingStyles = false
        notifyRestyled(blockIndices)
        if services.codeHighlighter != nil {
            for index in blockIndices {
                refreshHighlight(blockIndex: index, revealed: revealed.contains(index))
            }
        }
        if services.blockRenderer != nil {
            for index in blockIndices {
                refreshBlockEmbed(blockIndex: index, revealed: revealed.contains(index))
            }
        }
        #if canImport(AppKit)
        for index in blockIndices {
            refreshFrontMatterFold(blockIndex: index, revealed: revealed.contains(index))
            refreshCalloutFold(blockIndex: index, revealed: revealed.contains(index))
        }
        if services.blockRenderer != nil {
            for index in blockIndices {
                refreshInlineMath(blockIndex: index, revealed: revealed.contains(index))
            }
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

    private func refreshHighlight(blockIndex: Int, revealed: Bool) {
        guard let highlighter = services.codeHighlighter,
              blockIndex >= 0, blockIndex < parse.blocks.count else { return }
        let block = parse.blocks[blockIndex]
        guard case .fencedCode(let info, let closed) = block.kind, !info.isEmpty else { return }

        // A Mermaid fence is both a highlightable code block and a rendered
        // embed. Once collapsed, its source is concealed at 0.1pt with a clear
        // color — painting syntax colors back over it (this runs async, so it
        // lands *after* the collapse) turns the invisible source into a
        // scattering of coloured specks under the diagram.
        if !revealed, blockEmbedKind(at: blockIndex) != nil { return }

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
            let highlighted = await highlighter.highlight(code, language: language)
            guard let self else { return }
            self.highlightsInFlight.remove(key)
            guard !highlighted.isEmpty else { return }
            let runs = highlighted.map { ($0.range, $0.color) }
            if self.highlightColorCache.count > 128 { self.highlightColorCache.removeAll() }
            self.highlightColorCache[key] = runs
            // The text may have shifted while the highlight ran; re-derive
            // the block from the body's old location and apply only if its
            // content still matches (otherwise the next restyle picks the
            // cached runs up).
            if let idx = self.parse.blockIndex(at: min(bodyRange.location, max(0, self.storage.length - 1))),
               case .fencedCode = self.parse.blocks[idx].kind {
                self.refreshHighlight(blockIndex: idx, revealed: self.revealedBlocks.contains(idx))
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

    /// The usable text width for sizing rendered images (host updates on layout).
    /// Cross-platform: the iOS view reads/writes it too.
    @ObservationIgnored public var renderMaxWidth: CGFloat = 640
    /// Whether the host is in dark appearance (host updates on change).
    @ObservationIgnored public var isDarkAppearance = false

    // Block embeds are cross-platform. The renderers and `RenderedBlockFragment`
    // already were; only this collapse-and-band step was gated, so iOS wired
    // a `BlockRenderAdapter` that was never invoked and a table stayed as
    // pipes and dashes. docs/unimplemented.md §6.
    /// Rendered image per (kind) content hash. Cached so a restyle re-applies
    /// the collapse+image synchronously (no flash on caret enter/leave).
    @ObservationIgnored private var blockImageCache: [Int: PlatformImage] = [:]
    @ObservationIgnored private var blockRendersInFlight: Set<Int> = []

    /// The renderable embed a block represents, or nil. A standalone image
    /// embed is a paragraph whose entire content is one `![[…]]`.
    private func blockEmbedKind(at blockIndex: Int) -> BlockEmbedKind? {
        guard blockIndex >= 0, blockIndex < parse.blocks.count else { return nil }
        let block = parse.blocks[blockIndex]
        let ns: NSString = storage.mutableString
        // A transient parse/storage mismatch (e.g. an async render completion
        // re-deriving after an edit) could otherwise make `substring(with:)` /
        // `character(at:)` below go out of range — a crash, not a silent skip,
        // unlike the guarded sibling refresh methods.
        guard block.range.location >= 0,
              block.range.location + block.range.length <= ns.length else { return nil }
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
        case .table:
            let src = ns.substring(with: block.range).trimmingCharacters(in: .whitespacesAndNewlines)
            return src.isEmpty ? nil : .table(source: src)
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

        let maxWidth = renderMaxWidth
        let dark = isDarkAppearance

        // Appearance is part of the key, exactly as it is for inline math
        // below. Keyed on `kind` alone, a block rendered in one appearance was
        // served from the cache forever after: switch to Dark and the maths,
        // Mermaid charts and tables kept their light-mode ink, which on a dark
        // ground reads as washed-out and half-legible. Inline `$…$` on the very
        // same line re-rendered correctly, which is what made the two disagree.
        var hasher = Hasher()
        hasher.combine(kind)
        hasher.combine(dark)
        hasher.combine(Int(maxWidth))
        let key = hasher.finalize()

        if let image = blockImageCache[key] {
            collapse(range: content, to: image)
            return
        }
        guard !blockRendersInFlight.contains(key) else { return }
        blockRendersInFlight.insert(key)

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

    /// The final newline-delimited paragraph inside `range`. A trailing
    /// newline *terminates* the last paragraph rather than starting a new one,
    /// so it is not treated as a separator.
    private func lastParagraphRange(in range: NSRange, text ns: NSString) -> NSRange {
        guard range.length > 0 else { return range }
        var searchEnd = range.location + range.length
        if ns.character(at: searchEnd - 1) == 0x0A { searchEnd -= 1 }
        var start = range.location
        var i = searchEnd - 1
        while i >= range.location {
            if ns.character(at: i) == 0x0A { start = i + 1; break }
            i -= 1
        }
        return NSRange(location: start, length: range.location + range.length - start)
    }

    /// Collapse a block's source to near-zero height and reserve the image's
    /// height below it (drawn by RenderedBlockFragment). Source stays in the
    /// storage — concealed, not deleted.
    private func collapse(range: NSRange, to image: PlatformImage) {
        guard range.location + range.length <= storage.length else { return }
        let ns: NSString = storage.mutableString

        // Conceal the block's trailing newline as well. Left at the body font
        // it lays out as a full-height empty line directly beneath the
        // rendered image — visible dead space in every note with display maths.
        var concealed = range
        if concealed.location + concealed.length < ns.length,
           ns.character(at: concealed.location + concealed.length) == 0x0A {
            concealed.length += 1
        }

        isApplyingStyles = true
        storage.beginEditing()
        // Collapse the source line(s).
        storage.addAttribute(.font, value: theme.concealed, range: concealed)
        storage.addAttribute(.foregroundColor, value: PlatformColor.clear, range: concealed)

        // Reserve the image band *once*. `paragraphSpacing` applies at the end
        // of every paragraph and a newline ends a paragraph, so setting it
        // across a multi-line block reserved the band once per line — three
        // times for `$$…$$`, i.e. ~90pt of dead space for a one-line formula.
        // The band belongs to the last paragraph; the ones before it get zero.
        let band = NSMutableParagraphStyle()
        band.paragraphSpacing = image.size.height + 2 * RenderedBlockFragment.imageGap
        let last = lastParagraphRange(in: concealed, text: ns)
        let leading = NSRange(location: concealed.location, length: last.location - concealed.location)
        if leading.length > 0 {
            let flat = NSMutableParagraphStyle()
            flat.paragraphSpacing = 0
            storage.addAttribute(.paragraphStyle, value: flat, range: leading)
        }
        storage.addAttribute(.paragraphStyle, value: band, range: last)

        // Mark the first char so the fragment knows to draw.
        storage.addAttribute(blockImageAttribute, value: image, range: NSRange(location: concealed.location, length: 1))
        storage.endEditing()
        isApplyingStyles = false
    }

    // MARK: - Front-matter fold

    /// Fold a front-matter block: conceal the raw YAML (near-zero height) so
    /// the editor body starts at the first real content — the app's dedicated
    /// Properties panel is the front-matter editing surface. The source stays
    /// byte-pure in storage; caret entry (e.g. arrowing up into it) reveals
    // Folds and inline math are still AppKit-only — they need the
    // fold/replacement machinery, not just an image band. Tables,
    // Mermaid, display maths and transclusions need only the band.
    #if canImport(AppKit)
    /// the raw YAML for direct editing.
    private func refreshFrontMatterFold(blockIndex: Int, revealed: Bool) {
        guard blockIndex >= 0, blockIndex < parse.blocks.count else { return }
        let block = parse.blocks[blockIndex]
        guard case .frontMatter = block.kind, !revealed else { return }
        // Conceal the closing `---` line's newline too. Stripped from the range
        // it keeps the body font and lays out as a full-height empty line above
        // the note's first real content — the fold is meant to leave nothing.
        let ns: NSString = storage.mutableString
        let content = NSRange(location: block.range.location,
                              length: min(block.range.length, ns.length - block.range.location))
        guard content.length > 0 else { return }

        isApplyingStyles = true
        storage.beginEditing()
        storage.addAttribute(.font, value: theme.concealed, range: content)
        storage.addAttribute(.foregroundColor, value: PlatformColor.clear, range: content)
        storage.endEditing()
        isApplyingStyles = false
    }

    // MARK: - Callout fold

    /// Character offsets (callout header-line starts) of folded callouts.
    /// Ephemeral view state — never written to the file — kept stable across
    /// edits by `remapFoldedCallouts`.
    @ObservationIgnored private var foldedCallouts: Set<Int> = []

    /// Mark a foldable (multi-line) callout header with its fold state so the
    /// fragment draws the chevron, and conceal the body when folded. Skipped
    /// while the callout is revealed (caret inside → full source for editing).
    private func refreshCalloutFold(blockIndex: Int, revealed: Bool) {
        guard blockIndex >= 0, blockIndex < parse.blocks.count else { return }
        let block = parse.blocks[blockIndex]
        guard case .blockquote(.some) = block.kind, block.lineCount > 1, !revealed else { return }
        let headerLine = parse.lines.lineRange(block.firstLine)
        guard headerLine.location < storage.length else { return }
        let folded = foldedCallouts.contains(block.range.location)

        isApplyingStyles = true
        storage.beginEditing()
        storage.addAttribute(calloutFoldAttribute, value: folded,
                             range: NSRange(location: headerLine.location, length: 1))
        if folded {
            let bodyStart = headerLine.location + headerLine.length
            var bodyLen = block.range.location + block.range.length - bodyStart
            let ns: NSString = storage.mutableString
            if bodyLen > 0, bodyStart + bodyLen <= ns.length,
               ns.character(at: bodyStart + bodyLen - 1) == 0x0A { bodyLen -= 1 }
            if bodyLen > 0, bodyStart + bodyLen <= storage.length {
                let bodyRange = NSRange(location: bodyStart, length: bodyLen)
                storage.addAttribute(.font, value: theme.concealed, range: bodyRange)
                storage.addAttribute(.foregroundColor, value: PlatformColor.clear, range: bodyRange)
                storage.removeAttribute(calloutTintAttribute, range: bodyRange)
            }
        }
        storage.endEditing()
        isApplyingStyles = false
    }

    /// Toggle the fold state of the callout header containing `offset`. Returns
    /// the block's character range (so the caller can invalidate layout), or
    /// nil if `offset` isn't on a foldable callout header.
    @discardableResult
    public func toggleCalloutFold(atHeaderOffset offset: Int) -> NSRange? {
        guard let idx = parse.blockIndex(at: offset), idx < parse.blocks.count else { return nil }
        let block = parse.blocks[idx]
        guard case .blockquote(.some) = block.kind, block.lineCount > 1 else { return nil }
        let key = block.range.location
        if foldedCallouts.contains(key) { foldedCallouts.remove(key) } else { foldedCallouts.insert(key) }
        restyle(blockIndices: [idx], revealed: revealedBlocks, revealedLines: revealedLines)
        return block.range
    }

    /// True if `offset` falls on a foldable callout's header line.
    public func isFoldableCalloutHeader(atCharacter offset: Int) -> Bool {
        guard let idx = parse.blockIndex(at: offset), idx < parse.blocks.count else { return false }
        let block = parse.blocks[idx]
        guard case .blockquote(.some) = block.kind, block.lineCount > 1 else { return false }
        return offset < parse.lines.lineRange(block.firstLine).location + parse.lines.lineRange(block.firstLine).length
    }

    /// Keep folded-callout offsets valid after a text edit at `editStart`
    /// with `delta` change in length.
    private func remapFoldedCallouts(oldRange: NSRange, delta: Int) {
        guard !foldedCallouts.isEmpty else { return }
        let oldEnd = oldRange.location + oldRange.length
        foldedCallouts = Set(foldedCallouts.compactMap { off in
            if off < oldRange.location { return off }        // before the edit
            if off < oldEnd { return nil }                    // inside → drop
            return off + delta                                // after → shift
        })
    }

    // MARK: - Inline math (`$…$` rendered as baseline images)

    @ObservationIgnored private var inlineMathCache: [Int: NSImage] = [:]
    @ObservationIgnored private var inlineMathInFlight: Set<Int> = []

    /// Render each inline `$…$` span in a block to an image drawn at its
    /// baseline, concealing the source and reserving its width — unless the
    /// caret is in the block (then the source shows for editing).
    private func refreshInlineMath(blockIndex: Int, revealed: Bool) {
        guard let renderer = services.blockRenderer, !revealed,
              blockIndex >= 0, blockIndex < parse.blocks.count else { return }
        let block = parse.blocks[blockIndex]
        guard block.hasInlineContent else { return }
        let ns: NSString = storage.mutableString
        let fontSize = theme.body.pointSize
        let dark = isDarkAppearance

        for span in StyleSpec.contentSpans(for: block, text: ns, lines: parse.lines) {
            for node in InlineParser.parse(ns, in: span) where isInlineMath(node.kind) {
                guard node.contentRange.length > 0,
                      node.range.location + node.range.length <= ns.length else { continue }
                let source = ns.substring(with: node.contentRange)
                var hasher = Hasher(); hasher.combine(source); hasher.combine(Int(fontSize)); hasher.combine(dark)
                let key = hasher.finalize()

                if let image = inlineMathCache[key] {
                    applyInlineMath(range: node.range, image: image)
                    continue
                }
                guard !inlineMathInFlight.contains(key) else { continue }
                inlineMathInFlight.insert(key)
                let rangeLoc = node.range.location
                Task { [weak self] in
                    let image = await renderer.renderInlineMath(source, fontSize: fontSize, darkMode: dark)
                    guard let self else { return }
                    self.inlineMathInFlight.remove(key)
                    guard let image else { return }
                    if self.inlineMathCache.count > 256 { self.inlineMathCache.removeAll() }
                    self.inlineMathCache[key] = image
                    // Re-derive the span (text may have shifted) and re-apply
                    // if the block is still unrevealed inline content.
                    if let idx = self.parse.blockIndex(at: min(rangeLoc, max(0, self.storage.length - 1))),
                       !self.revealedBlocks.contains(idx) {
                        self.refreshInlineMath(blockIndex: idx, revealed: false)
                    }
                }
            }
        }
    }

    private func isInlineMath(_ kind: InlineKind) -> Bool {
        if case .math = kind { return true }
        return false
    }

    /// Collapse the `$…$` source to near-zero width (concealed font + clear
    /// color) and reserve exactly the image's width via kern on the last char,
    /// so the invisible span occupies precisely `image.width`. Mark the first
    /// char so the fragment draws the image there.
    private func applyInlineMath(range: NSRange, image: NSImage) {
        guard range.length > 0, range.location + range.length <= storage.length else { return }
        isApplyingStyles = true
        storage.beginEditing()
        storage.addAttributes([.font: theme.concealed, .foregroundColor: PlatformColor.clear], range: range)
        storage.addAttribute(inlineImageAttribute, value: image, range: NSRange(location: range.location, length: 1))
        // Collapsed source ≈ 0 width; kern on the last char reserves the image
        // width plus a hair of breathing room.
        storage.addAttribute(.kern, value: image.size.width + 2,
                             range: NSRange(location: range.location + range.length - 1, length: 1))
        storage.endEditing()
        isApplyingStyles = false
    }
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
