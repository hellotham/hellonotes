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

    /// Replace one range, keeping the parse, the styling and the undo stack —
    /// the path a keystroke takes, for a host that has text to substitute
    /// rather than a whole document to load.
    ///
    /// `replaceText` is the wrong tool for this: it reparses everything and
    /// clears undo, which for filling in an image's alt text a second after it
    /// was pasted would throw away the paste itself.
    /// - Parameter near: where the text being replaced was inserted, if known.
    ///   The search starts there and only falls back to the whole document if
    ///   it finds nothing — because `range(of:)` alone matches the **first**
    ///   occurrence anywhere, so pasting the same URL twice and letting the
    ///   title arrive rewrote the earlier link instead of the one just pasted.
    @discardableResult
    public func replaceFirst(_ needle: String, with replacement: String,
                             near hint: Int? = nil) -> Bool {
        let ns = storage.mutableString
        var found = NSRange(location: NSNotFound, length: 0)
        if let hint, hint != NSNotFound, hint <= ns.length {
            let start = max(0, hint - needle.utf16.count)
            found = ns.range(of: needle, options: [],
                             range: NSRange(location: start, length: ns.length - start))
        }
        if found.location == NSNotFound { found = ns.range(of: needle) }
        guard found.location != NSNotFound else { return false }

        // Register the inverse before mutating, on the same `UndoManager` the
        // text view uses (`undoManager(for:)` hands it this one). The edit goes
        // straight into the storage rather than through
        // `shouldChangeText`/`didChangeText`, so without this the substitution
        // is invisible to undo: ⌘Z replayed the *paste*'s registration against
        // ranges the substitution had already shifted, eating or stranding
        // fragments of whatever sat next to it.
        let previous = ns.substring(with: found)
        let location = found.location
        undoManager.registerUndo(withTarget: self) { document in
            document.replaceFirst(replacement, with: previous, near: location)
        }
        storage.replaceCharacters(in: found, with: replacement)
        return true
    }

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
        remapFoldedCallouts(oldRange: oldRange, delta: delta)

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
            // localizedStandardContains folds diacritics and width as well as
            // case: the rotor's search field is user input, so "cafe" must
            // reach a heading spelled "Café".
            candidates = candidates.filter { $0.title.localizedStandardContains(filter) }
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

    /// Source cmark keeps nothing of — link reference definitions. Cached on
    /// the same revision as the style runs, because it comes from the same
    /// parse.
    @ObservationIgnored private var unrenderedCache: [NSRange] = []
    @ObservationIgnored private var unrenderedCacheRevision = -1

    /// The document's link reference definitions: where they are, so they can
    /// be concealed, and what they say, so `![foo]` can be resolved.
    ///
    /// One scan answers both, cached on the same revision as everything else
    /// here. Two scans would be two opinions about which lines are definitions,
    /// and the failure mode is silent — a line concealed by one and left
    /// unresolvable by the other, so the source disappears and no picture
    /// takes its place.
    @ObservationIgnored private var referenceCache: [ReferenceDefinition.Found] = []
    @ObservationIgnored private var referenceMapCache = LinkReferenceMap.empty
    @ObservationIgnored private var referenceCacheRevision = -1

    private func refreshReferenceCache() {
        guard revision != referenceCacheRevision else { return }
        referenceCacheRevision = revision
        referenceCache = ReferenceDefinition.all(in: storage.mutableString, document: parse)
        referenceMapCache = LinkReferenceMap(referenceCache)
    }

    private func currentReferences() -> [ReferenceDefinition.Found] {
        refreshReferenceCache()
        return referenceCache
    }

    /// The document's label → destination map, for the inline parser.
    private func currentLinkReferences() -> LinkReferenceMap {
        refreshReferenceCache()
        return referenceMapCache
    }

    /// Source the reader will never see — reference definitions — minus
    /// whatever the caret is currently in.
    ///
    /// The subtraction is the whole difference between this being a feature and
    /// being a trap. Collapsed, a definition is half a point tall; without the
    /// reveal it stayed half a point tall *with the caret inside it*, so the
    /// one construct the editor had just learned to hide was also the one
    /// construct it had made impossible to edit or even see. Every other
    /// concealment in this editor opens when the caret arrives, and this is
    /// not the exception.
    ///
    /// Taking the revealed block's range out here rather than teaching
    /// `isUnrendered` about reveal keeps the *neighbours* honest too: a block's
    /// gap depends on whether the next block renders, so `isRendered`,
    /// `gapShares` and `blankRunHeight` all have to agree about this block, and
    /// they do when they are handed the same already-filtered array.
    private func currentUnrenderedRanges(revealed: Set<Int>) -> [NSRange] {
        let ranges = computeUnrenderedRanges()
        guard !ranges.isEmpty, !revealed.isEmpty else { return ranges }
        // A block index is the wrong unit for a rendered HTML span. The span is
        // one picture standing for several blocks, so the caret arriving in any
        // of them has to bring back *all* of the source: opening only the
        // caret's own block left `<table>` and `</table>` concealed around the
        // one row being edited, i.e. a construct the editor had just made
        // impossible to see whole. Every other concealment here opens on caret
        // entry and this is not the exception.
        let open = revealed.compactMap { index -> NSRange? in
            if let span = htmlSpan(at: index) { return span.range }
            return parse.blocks.indices.contains(index) ? parse.blocks[index].range : nil
        }
        return ranges.filter { range in
            !open.contains { NSIntersectionRange($0, range).length > 0 }
        }
    }

    private func computeUnrenderedRanges() -> [NSRange] {
        guard revision != unrenderedCacheRevision else { return unrenderedCache }
        unrenderedCacheRevision = revision
        let ns: NSString = storage.mutableString
        var ranges = ns.length < StyleApplier.gfmOverlayMaxLength
            ? GFMLiveStyle.unrenderedRanges(ns) : []
        ranges.append(contentsOf: wrapperHTMLRanges(ns))
        ranges.append(contentsOf: referenceDefinitionRanges(ns))
        ranges.append(contentsOf: frontMatterRange(ns))
        unrenderedCache = ranges
        return unrenderedCache
    }

    /// Runs of blocks that only mean anything rendered **together**: a raw HTML
    /// block that opens more elements than it closes, plus everything down to
    /// the block that closes them.
    ///
    /// CommonMark's block boundaries are not element boundaries — `<table>` on
    /// its own line is a whole HTML block, and so is the `</table>` four blocks
    /// later, with Markdown of its own in between. Rendered one at a time each
    /// half is meaningless, which is why `HTMLBlockShape` refuses them; but the
    /// *span* is exactly what the page draws there, and handing the whole span
    /// (raw blocks and the Markdown between them) to `GFMRenderer.page` renders
    /// it through the same cmark call Preview makes. Spec #118, #159 and #160
    /// are three shapes of the same thing, and the editor was 14–65pt short on
    /// all of them.
    ///
    /// Code blocks are stepped over rather than scanned: a `<td>` inside an
    /// indented listing is text on the page, and counting it as an open element
    /// unbalanced #160's span at the one block that must not move the stack.
    ///
    /// Nil-returning `advance` (crossed tags, an unterminated one) ends the
    /// search rather than widening it — a span that will never balance must not
    /// swallow the rest of the note looking for one.
    @ObservationIgnored private var htmlSpanCache: [(range: NSRange, first: Int, last: Int)] = []
    @ObservationIgnored private var htmlSpanCacheRevision = -1

    private func currentHTMLSpans() -> [(range: NSRange, first: Int, last: Int)] {
        guard revision != htmlSpanCacheRevision else { return htmlSpanCache }
        htmlSpanCacheRevision = revision
        htmlSpanCache = computeHTMLSpans()
        return htmlSpanCache
    }

    private func computeHTMLSpans() -> [(range: NSRange, first: Int, last: Int)] {
        let ns: NSString = storage.mutableString

        /// A block's text, or nil for one whose angle brackets are literal.
        func source(_ block: Block) -> String? {
            switch block.kind {
            case .fencedCode, .indentedCode, .mathBlock, .frontMatter: return nil
            default: break
            }
            guard block.range.location + block.range.length <= ns.length else { return nil }
            return ns.substring(with: block.range)
        }

        var spans: [(range: NSRange, first: Int, last: Int)] = []
        var i = 0
        while i < parse.blocks.count {
            guard case .htmlBlock = parse.blocks[i].kind, let head = source(parse.blocks[i]) else {
                i += 1; continue
            }
            var stack: [String] = []
            guard advance(&stack, head), let outermost = stack.first,
                  // Only where concealing the tags cannot give the same
                  // picture. See `HTMLBlockShape.laysOutItsChildren`.
                  HTMLBlockShape.laysOutItsChildren.contains(outermost)
            else { i += 1; continue }
            var j = i + 1
            var closedAt: Int? = nil
            while j < parse.blocks.count {
                if let text = source(parse.blocks[j]) {
                    guard advance(&stack, text) else { break }
                    if stack.isEmpty { closedAt = j; break }
                }
                j += 1
            }
            guard let last = closedAt else { i += 1; continue }
            let start = parse.blocks[i].range.location
            let end = parse.blocks[last].range.location + parse.blocks[last].range.length
            spans.append((NSRange(location: start, length: end - start), i, last))
            i = last + 1
        }
        return spans
    }

    private func advance(_ stack: inout [String], _ text: String) -> Bool {
        HTMLBlockShape.advance(stack: &stack, through: text) != nil
    }

    /// The span `blockIndex` belongs to, if any.
    private func htmlSpan(at blockIndex: Int) -> (range: NSRange, first: Int, last: Int)? {
        currentHTMLSpans().first { blockIndex >= $0.first && blockIndex <= $0.last }
    }

    /// Is the caret inside this block — or, when it is part of a rendered HTML
    /// span, inside any block of that span?
    private func isRevealedAllowingSpan(_ blockIndex: Int) -> Bool {
        guard let span = htmlSpan(at: blockIndex) else { return revealedBlocks.contains(blockIndex) }
        return revealedBlocks.contains { $0 >= span.first && $0 <= span.last }
    }

    /// A container line's own content, past the list marker or the `>`s.
    private func contentPastMarkers(_ content: NSRange, of block: Block,
                                    isFirstLine: Bool, in ns: NSString) -> NSRange {
        var i = content.location
        let end = content.location + content.length
        switch block.kind {
        case .listItem(let info) where isFirstLine:
            i = min(content.location + info.contentOffset, end)
        case .blockquote:
            while i < end, ns.character(at: i) == 0x20 { i += 1 }
            while i < end, ns.character(at: i) == 0x3E {
                i += 1
                if i < end, ns.character(at: i) == 0x20 { i += 1 }
            }
        default:
            break
        }
        return NSRange(location: i, length: end - i)
    }

    /// The note's YAML front matter, which the reader is never shown.
    ///
    /// `unrenderedRanges` asks cmark what it kept of the *note*, and Preview
    /// does not hand cmark the note: `NoteMarkdown.prepare` strips the front
    /// matter first. So cmark sees `---` / `title: x` / `---` as a thematic
    /// break and a paragraph, reports them as kept, and the editor reserved
    /// four full lines and a margin for a block the page has no element for at
    /// all — a note opening with nine lines of properties stood 240pt taller
    /// than its own preview, and the gap was empty. The editor's own fold
    /// covered exactly half of that: it cleared the glyphs and left their
    /// line boxes standing, so what the reader saw was a blank band the height
    /// of the YAML rather than the note starting at its title.
    ///
    /// Said here rather than inside `unrenderedRanges` because that function's
    /// question is "what did cmark keep of what it was given", and this one's
    /// is "what is cmark given" — the same distinction that had the sweep
    /// grading a page the app never builds (see `NoteMarkdown`). And said as a
    /// *range* rather than as a special case in `BlockBoxes`, because every
    /// consequence is already written down for unrendered source: no height,
    /// no margin, the next block becomes the document's first, and the whole
    /// block comes back the moment the caret arrives — which is the one thing
    /// a fold that reads properties for a living must never lose.
    private func frontMatterRange(_ ns: NSString) -> [NSRange] {
        guard let block = parse.blocks.first, case .frontMatter = block.kind,
              block.range.length > 0,
              block.range.location + block.range.length <= ns.length else { return [] }
        return [block.range]
    }

    /// Reference definitions the cmark inversion cannot see, because a
    /// container node covers them along with its children — one inside a list
    /// item, or one sitting above a paragraph in the same block.
    ///
    /// The walk itself is `ReferenceDefinition.all`, in MarkdownCore, because
    /// the same pass now has to answer a second question: what `[foo]` points
    /// at. It lived here while hiding the source was all anyone wanted from
    /// it, and a copy of it over there would be a second opinion about what
    /// counts as a definition — the way a line gets concealed by one scanner
    /// and left unresolvable by the other.
    private func referenceDefinitionRanges(_ ns: NSString) -> [NSRange] {
        currentReferences().map(\.range)
    }

    /// HTML blocks that are half an element — `<div class="x">` on its own, and
    /// the `</div>` that closes it further down.
    ///
    /// They cannot be *rendered* on their own (see `HTMLBlockShape`), and
    /// showing the source is not the alternative it looks like: the reader sees
    /// no tag, and a wrapper element contributes no height of its own, so a
    /// line of markup here is a line the rendered page does not have. Treating
    /// them as unrendered source puts them through the same path a link
    /// reference definition takes — concealed, no height, no margin, and back
    /// in full the moment the caret arrives.
    private func wrapperHTMLRanges(_ ns: NSString) -> [NSRange] {
        var out: [NSRange] = []
        let spans = currentHTMLSpans()
        for (index, block) in parse.blocks.enumerated() {
            // A block inside a rendered HTML span is not unrendered source —
            // the span's own collapse hides it, and the picture that replaces
            // it *is* rendered. Marking it unrendered as well told the blank
            // lines either side that they sat next to nothing, and they gave
            // back a third of a margin: 5.33pt where the page puts 16.
            if spans.contains(where: { index >= $0.first && index <= $0.last }) { continue }
            // Wrapper tags inside a container. `- <div>` and `> <div>` are a
            // list item and a quote holding an element that draws nothing, and
            // the reader sees no tag there — but the `<div>` is part of the
            // item's own block, so no `htmlBlock` exists to notice it.
            switch block.kind {
            case .listItem, .blockquote:
                let last = block.firstLine + block.lineCount - 1
                for lineNumber in block.firstLine...last {
                    let range = parse.lines.lineRange(lineNumber)
                    guard range.length > 0, range.location + range.length <= ns.length else { continue }
                    let content = parse.lines.contentRange(lineNumber, in: ns)
                    let inner = contentPastMarkers(content, of: block, isFirstLine: lineNumber == block.firstLine, in: ns)
                    guard inner.length > 0 else { continue }
                    if HTMLBlockShape.isBareWrapperLine(ns.substring(with: inner)) {
                        out.append(range)
                    }
                }
                continue
            // A paragraph of nothing but wrapper tags. cmark hands `</a></foo >`
            // through as raw inline HTML because condition 7 wants a *single*
            // tag on its line, so no `htmlBlock` exists — and then the browser
            // throws stray closing tags away and paints an empty `<p>` of zero
            // height. The editor drew 24pt of source against a page showing
            // nothing, which is the same divergence the block branch below
            // exists to close, arriving by a different route.
            //
            // The predicate has to be the strict one. `isBareWrapperLine` asks
            // only whether the line is `<…>` runs, and inside a paragraph that
            // is also true of every autolink and every malformed tag in the Raw
            // HTML section — all of which the page prints as text.
            case .paragraph:
                // The **whole** paragraph, not a line at a time. A tag is not
                // required to fit on one line, and cmark does not make it: the
                // line ending inside `<a href="foo⏎bar">` is part of the tag,
                // the browser gets one well-formed anchor, and the page paints
                // the same empty zero-height `<p>` it paints for `<a href="x">`
                // written on one. Asked per line, neither half parses, so the
                // editor kept 48pt of source under a page showing nothing —
                // twice the divergence the single-line case had.
                //
                // The predicate reads a line ending as whitespace already
                // (`isHTMLSpace`), so this is the same grammar over a longer
                // string, and a paragraph whose lines each parse on their own
                // parses identically either way.
                let content = ns.substring(with: block.range)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { continue }
                let lowered = content.lowercased()
                if HTMLBlockShape.isWellFormedTagsOnlyLine(content),
                   !HTMLBlockShape.drawsSomething(lowered),
                   !HTMLBlockShape.isEscapedByTagFilter(lowered) {
                    out.append(block.range)
                }
                continue
            default: break
            }
            guard case .htmlBlock(_, let closed) = block.kind else { continue }
            let source = ns.substring(with: block.range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // `<script>` and `<style>` draw nothing on the page whatever is
            // inside them, and a **closed** one already collapses here: it is
            // self-contained, so it renders as an embed of nothing and the
            // source folds away. Measured at base 16 / width 800, in context:
            // `<style>`, `<script>` and `<script type=…>` all sit within 0.6pt
            // of the page. (An earlier note here claimed the collapse had been
            // backed out over margins 10–23pt short — that is no longer true,
            // and a stale KNOWN GAP sends the next reader chasing a fixed bug.)
            //
            // Source the HTML *tokenizer* swallows, which is not the same set
            // as the source cmark passes through. Two shapes of it, and both
            // used to be drawn in full against a page painting nothing.
            //
            // (1) A tag that never finds its `>`. `<div id="foo"` eats the
            // next line as attribute soup and then hits the end of the input,
            // which is a parse error the browser resolves by dropping the lot.
            // The strict tag grammar `isTagsOnly` reaches for says "not a tag"
            // and leaves the line visible — right for CommonMark, which prints
            // `<div *???-&&&-<---` as text, and wrong for the page, which does
            // not. Everything from that `<` to the end of the block goes.
            //
            // What is *not* here: an unclosed `<style` or `<script`. Those look
            // like the same case — CommonMark runs the block to the end of the
            // document and the browser would put every line of it inside a
            // RAWTEXT element — and they are the opposite one. GitHub's
            // `tagfilter` extension escapes the leading `<`, so the page never
            // sees an element at all: it prints the tag as text, on one line,
            // with the block's newlines collapsed like any other run of HTML
            // whitespace. Concealing it hid four lines the reader can see.
            // `blockEmbedKind` renders that block instead.
            let raw = ns.substring(with: block.range)
            if let cut = HTMLBlockShape.unterminatedRunStart(raw) {
                out.append(NSRange(location: block.range.location + cut,
                                   length: block.range.length - cut))
                continue
            }
            guard closed, !source.isEmpty, !HTMLBlockShape.isSelfContained(source) else { continue }
            // Every line tags: collapse the block whole, as before.
            if source.split(separator: "\n", omittingEmptySubsequences: true)
                .allSatisfy({ HTMLBlockShape.isTagsOnly(String($0)) }) {
                out.append(block.range)
                continue
            }
            // Otherwise line by line. An unbalanced block carries text as well
            // — `</div>` then `*foo*` — and only the *tag* line draws nothing:
            // the page shows one line where the editor showed two. Refusing the
            // whole block because one line has content left the tag visible in
            // every such example. The mechanism was never the obstacle; the
            // cache is a list of ranges, and the container branch above has
            // always appended single lines.
            let last = block.firstLine + block.lineCount - 1
            guard last >= block.firstLine else { continue }
            for lineNumber in block.firstLine...last {
                let range = parse.lines.lineRange(lineNumber)
                guard range.length > 0, range.location + range.length <= ns.length else { continue }
                let content = parse.lines.contentRange(lineNumber, in: ns)
                guard content.length > 0 else { continue }
                if HTMLBlockShape.isTagsOnly(ns.substring(with: content)) { out.append(range) }
            }
        }
        return out
    }

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
        // A block's trailing gap is the *collapsed* margin between it and its
        // neighbour, so it belongs to two blocks: typing `#` in front of a
        // paragraph changes the space above it, which is spacing stored on the
        // block *before*. Restyling only the block that changed left that
        // neighbour holding the old gap. Still O(damage) — one block wider on
        // each side, not a document pass.
        var indices = blockIndices
        for index in blockIndices {
            if index > 0 { indices.insert(index - 1) }
            if index + 1 < parse.blocks.count { indices.insert(index + 1) }
        }
        // A rendered HTML span is one picture over several blocks, and it has
        // to be restyled as one. The block that *owns* it is its first, so
        // without this the embed pass never visited the owner and the picture
        // neither arrived when the caret left nor went away when it came back;
        // and `collapse` wrote its attributes over **every** block of the span,
        // so restyling only the owner left `</table>` collapsed around a row
        // that had just been revealed.
        var spanBlocks = Set<Int>()
        for index in indices {
            if let span = htmlSpan(at: index) { spanBlocks.formUnion(span.first...span.last) }
        }
        indices.formUnion(spanBlocks)
        /// Revealed for embed purposes: any block of a span reveals the span.
        func spanRevealed(_ index: Int) -> Bool {
            guard let span = htmlSpan(at: index) else { return revealed.contains(index) }
            return revealed.contains { $0 >= span.first && $0 <= span.last }
        }
        isApplyingStyles = true
        StyleApplier.apply(
            blockIndices: indices.sorted(),
            parse: parse,
            text: storage.mutableString,
            to: storage,
            theme: theme,
            revealedLines: revealedLines,
            resolveWiki: services.wikiLinkExists,
            gfmRuns: currentGFMRuns(),
            unrendered: currentUnrenderedRanges(revealed: revealed)
        )
        isApplyingStyles = false
        notifyRestyled(indices)
        // Everything below re-applies attributes that `StyleApplier` has just
        // wiped, so it has to run over the same widened set. Running it over
        // the narrow one left the extra neighbour freshly base-styled and
        // stripped: a folded callout one block away from an edit came unfolded,
        // its highlighted code lost its colours, and its rendered table came
        // back as pipes.
        if services.codeHighlighter != nil {
            for index in indices {
                refreshHighlight(blockIndex: index, revealed: revealed.contains(index))
            }
        }
        // Folds before embeds, as this has always run. The `#if canImport(AppKit)`
        // around this block came off when block embeds reached iOS — correctly —
        // but the two loops were reordered on the way, with nothing to say why.
        // These apply attributes to the same blocks, so the order is behaviour,
        // not arrangement: a fold conceals a range and an embed replaces one,
        // and which goes last decides what a callout containing a fence looks
        // like. An unexplained change to that is a change nobody chose.
        for index in indices {
            refreshCalloutFold(blockIndex: index, revealed: revealed.contains(index))
        }
        if services.blockRenderer != nil {
            for index in indices {
                refreshBlockEmbed(blockIndex: index, revealed: spanRevealed(index))
                refreshInlineMath(blockIndex: index, revealed: revealed.contains(index))
                refreshInlineImages(blockIndex: index, revealed: revealed.contains(index))
            }
        }
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
        // scattering of coloured specks under the diagram. A listing inside a
        // collapsed HTML span is the same thing arriving by a different route.
        if !revealed, blockEmbedKind(at: blockIndex) != nil { return }
        if isInsideCollapsedSpan(blockIndex, revealed: revealed) { return }

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
        case .htmlBlock(let condition, let closed):
            // Half an element is not a thing that has a size, but the span it
            // opens is: render from the span's first block, and nothing at all
            // from the blocks it covers — the `<td>…</td>` inside `<table>` …
            // `</table>` is self-contained and would otherwise draw a second,
            // smaller picture inside the first.
            if let span = htmlSpan(at: blockIndex) {
                guard span.first == blockIndex else { return nil }
                let text = ns.substring(with: span.range)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return .html(source: text,
                             keepsTrailingMargin: !isLastRenderedBlock(span.last))
            }
            let src = ns.substring(with: block.range).trimmingCharacters(in: .whitespacesAndNewlines)
            // Only once it is closed. Half-typed markup (`<div` with no `>`,
            // an unterminated `<!--`) would otherwise be re-rendered on every
            // keystroke, and would render as whatever WebKit makes of a
            // fragment — which is not what you are in the middle of writing.
            //
            // One exception, and it is not half-typed anything: a condition-1
            // block opening with a tag the GFM tag filter escapes — `<script`,
            // `<style`, `<textarea`. CommonMark waits for a close tag that
            // never comes, so the block is "unclosed" to the end of the note;
            // the page has no element to close, because the filter turned the
            // tag into text before the browser ever saw it. Left out, the
            // editor drew four lines of source against a page printing them as
            // one collapsed line of text (spec #142). Nothing is re-rendered
            // per keystroke either: the caret is inside the block while it is
            // being typed, and a revealed block is never collapsed.
            guard closed || (condition == 1 && HTMLBlockShape.opensTagFilteredElement(src))
            else { return nil }
            // Only a block that stands alone. An opening tag is a complete
            // HTML block by itself, and rendering that half-element in
            // isolation draws a box around nothing while the content it was
            // meant to wrap sits outside it. See `HTMLBlockShape`.
            guard !src.isEmpty, HTMLBlockShape.isSelfContained(src) else { return nil }
            return .html(source: src, keepsTrailingMargin: !isLastRenderedBlock(blockIndex))
        case .paragraph:
            // Exactly one image filling the paragraph's content — either an
            // Obsidian `![[target]]` embed or a Markdown `![alt](path)`.
            //
            // The Markdown form used to be missing, so a note illustrated the
            // ordinary way showed a line of `![alt](photo.jpg)` in Edit and the
            // photograph in Preview. That is the largest layout difference the
            // two surfaces can have, and the only construct where the *content*
            // differed rather than its spacing.
            var content = block.range
            if content.length > 0, ns.character(at: content.location + content.length - 1) == 0x0A { content.length -= 1 }
            // Through the document's reference map, so `![foo]` with a
            // `[foo]: photo.jpg` further down reserves the same box
            // `![foo](photo.jpg)` does. Without it the inline parser saw four
            // characters of prose here and the editor kept a line of text
            // where the Preview drew the picture.
            let references = currentLinkReferences()
            let nodes = InlineParser.parse(ns, in: content, references: references)
            guard nodes.count == 1,
                  nodes[0].range.location == content.location,
                  nodes[0].range.length == content.length else { return nil }
            // `[![moon](moon.jpg)](/uri)` — a picture with somewhere to click,
            // and the ordinary way to publish a linked figure. The anchor
            // contributes no box of its own: the browser lays the image out
            // exactly as it would unwrapped, so the paragraph is still one
            // image filling itself. Reading only the outer node, the editor
            // saw a link, reserved nothing, and drew 25 characters of source
            // under a page showing the photograph.
            var node = nodes[0]
            if case .link(_, false) = node.kind {
                let inner = InlineParser.parse(ns, in: node.contentRange, references: references)
                guard inner.count == 1,
                      inner[0].range.location == node.contentRange.location,
                      inner[0].range.length == node.contentRange.length else { return nil }
                node = inner[0]
            }
            switch node.kind {
            case .wikiLink(let target, true):
                return .image(target: target)
            case .link(let url, true):
                // Local files only. `.image` falls back to a note-transclusion
                // card when the target is not an image *file*, which is right
                // for `![[Some Note]]` and quite wrong for an `https://` URL —
                // that would draw a card for a note named after the host.
                // Fetching remote images is a separate decision with a network
                // policy attached; until then such a link stays as source.
                guard !url.contains("://"), !url.hasPrefix("data:"),
                      !url.hasPrefix("mailto:") else { return nil }
                // Percent-encoded paths are what a file with a space in its
                // name becomes when it is written as a Markdown link.
                let path = url.removingPercentEncoding ?? url
                return path.isEmpty ? nil : .image(target: path)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// Is this the last block the page draws anything for?
    ///
    /// The question the stylesheet asks is `.markdown-body > *:last-child`, and
    /// blank lines are not children: a note ending in `<table>…</table>` and a
    /// note ending in the same thing plus two empty lines have the same last
    /// child. Asking "is this the last block" instead put the margin back the
    /// moment someone left a blank line under it.
    private func isLastRenderedBlock(_ blockIndex: Int) -> Bool {
        var i = blockIndex + 1
        while i < parse.blocks.count {
            if case .blank = parse.blocks[i].kind { i += 1; continue }
            return false
        }
        return true
    }

    private func refreshBlockEmbed(blockIndex: Int, revealed: Bool) {
        guard let renderer = services.blockRenderer,
              let kind = blockEmbedKind(at: blockIndex) else { return }
        // Caret inside → show source, don't collapse (base restyle already
        // cleared any prior collapse).
        guard !revealed else { return }

        // The span's range where there is one: the picture stands for every
        // block it covers, so every one of them has to collapse under it.
        var content = htmlSpan(at: blockIndex)?.range ?? parse.blocks[blockIndex].range
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
            collapse(range: content, to: image, extraBelow: baselineAllowance(for: kind))
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
               !self.isRevealedAllowingSpan(idx),
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
    /// The space an *inline* embed needs below it.
    ///
    /// An `<img>` is inline: it sits on the text baseline, so the line box
    /// holding it is the image plus whatever the strut hangs below that
    /// baseline — a half-leading and a descender, 6pt at 16pt body. A table, a
    /// diagram or a display formula is block-level and needs none of it.
    /// Without this a rendered image sat 6pt tighter in Edit than in Preview,
    /// on the most common embed there is.
    private func baselineAllowance(for kind: BlockEmbedKind) -> CGFloat {
        guard case .image = kind else { return 0 }
        return BlockBoxes.halfLeading(.paragraph, theme: theme)
            + (-theme.body.descender).rounded()
    }

    private func collapse(range: NSRange, to image: PlatformImage, extraBelow: CGFloat = 0) {
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
        // …and every piece of chrome the styler hung on that source. Invisible
        // text must not keep a code band, a heading rule or a bottom padding:
        // see `chromeAttributes`.
        for key in chromeAttributes { storage.removeAttribute(key, range: concealed) }

        // Reserve the image band *once*. `paragraphSpacing` applies at the end
        // of every paragraph and a newline ends a paragraph, so setting it
        // across a multi-line block reserved the band once per line — three
        // times for `$$…$$`, i.e. ~90pt of dead space for a one-line formula.
        // The band belongs to the last paragraph; the ones before it get zero.
        let band = NSMutableParagraphStyle()
        let bandHeight = image.size.height + 2 * RenderedBlockFragment.imageGap + extraBelow
        let last = lastParagraphRange(in: concealed, text: ns)
        // …*plus* whatever margin the block already had below it. This style
        // replaces the one `StyleApplier` laid down, and that one is where the
        // collapsed CSS margin lives when there is no blank line to hold it —
        // so a rendered block butted straight against the next one (a table
        // with `> quote` on the very next line, which is how the specification
        // writes it) lost its `margin-bottom: 16` the moment its picture
        // arrived. Invisible in a note with blank lines between its blocks,
        // which is every note anyone writes by hand.
        //
        // Read from the storage rather than recomputed, because the answer is
        // "0 when a blank run below is already holding the gap" and only the
        // styler knows which of the two it chose. Safe to read because every
        // path here restyles first: `restyle` runs `StyleApplier.apply` before
        // it refreshes embeds, and the async render completion collapses a
        // block the earlier pass left un-collapsed. The line-height check is
        // the belt: a band pins the line to `collapsedLine`, so a style already
        // holding one is never mistaken for a fresh margin and added twice.
        let existing = storage.attribute(.paragraphStyle, at: last.location,
                                         effectiveRange: nil) as? NSParagraphStyle
        let existingGap = existing?.minimumLineHeight == BlockBoxes.collapsedLine
            ? 0 : (existing?.paragraphSpacing ?? 0)
        band.paragraphSpacing = bandHeight + existingGap
        let leading = NSRange(location: concealed.location, length: last.location - concealed.location)
        if leading.length > 0 {
            let flat = NSMutableParagraphStyle()
            flat.paragraphSpacing = 0
            // Concealed source takes no room. Left at its natural height each
            // hidden line still cost a few points — three per line of a table's
            // source, which is a rendered block standing visibly lower than the
            // one Preview draws.
            flat.minimumLineHeight = BlockBoxes.collapsedLine
            flat.maximumLineHeight = BlockBoxes.collapsedLine
            storage.addAttribute(.paragraphStyle, value: flat, range: leading)
        }

        // A block that ends the note cannot hold its band in `paragraphSpacing`:
        // TextKit drops the trailing spacing of the document's last paragraph.
        // The image was then drawn into space nothing had reserved, below the
        // end of the document — so a note finishing with a table, a diagram, a
        // formula or an HTML block showed no rendered block at all.
        //
        // Make the band out of the line box instead, which cannot be dropped.
        // Safe here and nowhere else: the source underneath is concealed at
        // `EditorTheme.concealedSize`, so it has no width to wrap with, and a
        // line height that is applied to "every line" is applied to one line.
        let endsDocument = concealed.location + concealed.length >= ns.length
        var drawAt = concealed.location
        band.minimumLineHeight = BlockBoxes.collapsedLine
        band.maximumLineHeight = BlockBoxes.collapsedLine
        if endsDocument {
            band.paragraphSpacing = 0
            band.minimumLineHeight = bandHeight
            band.maximumLineHeight = bandHeight
            drawAt = last.location
        }
        storage.addAttribute(.paragraphStyle, value: band, range: last)

        // Mark one char so the fragment knows to draw.
        storage.addAttribute(blockImageAttribute, value: image, range: NSRange(location: drawAt, length: 1))
        if endsDocument {
            storage.addAttribute(blockImageTopAttribute, value: RenderedBlockFragment.imageGap,
                                 range: NSRange(location: drawAt, length: 1))
        }
        storage.endEditing()
        isApplyingStyles = false
        // The image arrives asynchronously, long after the restyle that
        // asked for it. Nothing else tells the host, and on iOS the chrome
        // is painted by a separate overlay view rather than by the fragment
        // — so the overlay kept whatever it had drawn before, which for a
        // fragment not yet laid out is the top of the document.
        onRestyle?(range)
    }

    // MARK: - Front-matter fold
    //
    // There is no function here any more. The fold used to be one — it cleared
    // the YAML's glyphs and marked the block concealed — and it was half a
    // fold: a line box whose glyphs are invisible is still a line box, so what
    // the reader got was a blank band exactly as tall as the properties, above
    // a note that was meant to start at its title. The other half is not a
    // second attribute pass, it is `frontMatterRange`: front matter is source
    // the reader never sees, and every consequence of that — no height, no
    // margin, the next block becomes the document's first, the whole thing
    // back the moment the caret arrives — is already written down once, for
    // reference definitions, and is now shared. Two mechanisms for one job is
    // how the fold came to conceal without collapsing in the first place.

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

    @ObservationIgnored private var inlineMathCache: [Int: PlatformImage] = [:]
    @ObservationIgnored private var inlineMathInFlight: Set<Int> = []

    /// Render each inline `$…$` span in a block to an image drawn at its
    /// baseline, concealing the source and reserving its width — unless the
    /// caret is in the block (then the source shows for editing).
    private func refreshInlineMath(blockIndex: Int, revealed: Bool) {
        guard let renderer = services.blockRenderer, !revealed,
              !isInsideCollapsedSpan(blockIndex, revealed: revealed),
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
    private func applyInlineMath(range: NSRange, image: PlatformImage) {
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

    // MARK: - Inline images (a replaced element inside a line of prose)

    /// Rendered image per (target, width, appearance) hash — the same
    /// re-apply-synchronously-on-restyle contract the block embeds use.
    @ObservationIgnored private var inlineImageCache: [Int: PlatformImage] = [:]
    @ObservationIgnored private var inlineImagesInFlight: Set<Int> = []

    /// Draw every `![alt](path)` and `<img src=…>` that sits *inside* a line
    /// of text as the picture it stands for.
    ///
    /// The editor has always drawn a paragraph that is nothing but an image —
    /// `refreshBlockEmbed` collapses the whole block — and has never drawn one
    /// with a word beside it. `My ![foo](train.jpg)` stayed as source while the
    /// Preview showed a sentence with a photograph in it, which is the largest
    /// difference the two surfaces can have and reads in the height sweep as a
    /// tidy two points: the source happens to occupy one line, and one line of
    /// prose is 24pt where a line seating a 20pt picture is 26.
    ///
    /// `![[embed]]` is deliberately not here. The host's renderer answers an
    /// `.image` whose target is not an image *file* with a note-transclusion
    /// card, which is the right answer for a block on a line of its own and an
    /// absurd one for a word inside a sentence. Nothing in the editor can tell
    /// the two apart, so the construct that can mean "transclude a note" stays
    /// as source inline.
    /// Is this block covered by an HTML span that is currently collapsed to its
    /// picture?
    ///
    /// `blockEmbedKind` answers nil for every block of a span *except* its
    /// first — that is what stops five fragments drawing five pictures — so the
    /// usual "am I an embed" guard lets a span's interior through, and an
    /// `![img]` or a `$…$` four blocks into a `<table>` would have been drawn
    /// over source that is already invisible under the table.
    private func isInsideCollapsedSpan(_ blockIndex: Int, revealed: Bool) -> Bool {
        !revealed && htmlSpan(at: blockIndex) != nil
    }

    private func refreshInlineImages(blockIndex: Int, revealed: Bool) {
        guard let renderer = services.blockRenderer, !revealed,
              !isInsideCollapsedSpan(blockIndex, revealed: revealed),
              blockIndex >= 0, blockIndex < parse.blocks.count else { return }
        let block = parse.blocks[blockIndex]
        guard block.hasInlineContent else { return }
        // A block that *is* an embed has already been collapsed to one picture;
        // finding the same image again inside it would conceal the source a
        // second time and reserve its width in a band that has no text in it.
        guard blockEmbedKind(at: blockIndex) == nil else { return }
        let ns: NSString = storage.mutableString
        let references = currentLinkReferences()
        let dark = isDarkAppearance
        let maxWidth = renderMaxWidth

        for span in StyleSpec.contentSpans(for: block, text: ns, lines: parse.lines) {
            for node in imageBearingNodes(in: span, text: ns, references: references) {
                guard let target = inlineImageTarget(node.kind), node.range.length > 1,
                      node.range.location + node.range.length <= ns.length else { continue }
                var hasher = Hasher()
                hasher.combine(target); hasher.combine(Int(maxWidth)); hasher.combine(dark)
                let key = hasher.finalize()

                if let image = inlineImageCache[key] {
                    applyInlineImage(range: node.range, image: image)
                    continue
                }
                guard !inlineImagesInFlight.contains(key) else { continue }
                inlineImagesInFlight.insert(key)
                let rangeLoc = node.range.location
                Task { [weak self] in
                    let image = await renderer.render(.image(target: target),
                                                      maxWidth: maxWidth, darkMode: dark)
                    guard let self else { return }
                    self.inlineImagesInFlight.remove(key)
                    guard let image else { return }
                    if self.inlineImageCache.count > 256 { self.inlineImageCache.removeAll() }
                    self.inlineImageCache[key] = image
                    // Re-derive the block (text may have shifted under the
                    // render) and re-apply if the caret has not since arrived.
                    guard let idx = self.parse.blockIndex(at: min(rangeLoc, max(0, self.storage.length - 1))),
                          !self.revealedBlocks.contains(idx) else { return }
                    self.refreshInlineImages(blockIndex: idx, revealed: false)
                    // The picture arrives long after the restyle that asked for
                    // it, and on iOS the chrome is painted by an overlay view
                    // rather than by the fragment — so without this the overlay
                    // keeps whatever it drew before the image existed.
                    if self.parse.blocks.indices.contains(idx) {
                        self.onRestyle?(self.parse.blocks[idx].range)
                    }
                }
            }
        }
    }

    /// The inline nodes of `span`, plus the ones **inside a link**.
    ///
    /// A picture wrapped in a link is the most common picture in a README —
    /// `[![build](badge.svg)](https://ci.example.com)`, three of them in a row
    /// under the title — and the top-level node there is the *link*, so a walk
    /// over `InlineParser.parse` alone never sees the image at all. The result
    /// was not a missing picture, which somebody would have noticed: the badges
    /// drew, because the link's own markup is concealed either way, and only
    /// the *line box* was wrong — 24pt of prose where the page seats a 20pt
    /// replaced element on the baseline and makes the line 26. Two points, on
    /// a line that looked right.
    ///
    /// One level down and no further, because Markdown does not nest links
    /// inside links: the only thing that can be inside a link's text and be a
    /// picture is a picture. `blockEmbedKind` has always descended this way for
    /// the *block* case (a paragraph that is one linked image), which is why
    /// `![badge](b.png)` alone on a line has always been right and the same
    /// image in a sentence has not.
    private func imageBearingNodes(in span: NSRange, text ns: NSString,
                                   references: LinkReferenceMap) -> [InlineNode] {
        var out: [InlineNode] = []
        for node in InlineParser.parse(ns, in: span, references: references) {
            out.append(node)
            guard case .link(_, false) = node.kind, node.contentRange.length > 1,
                  node.contentRange.location >= span.location,
                  node.contentRange.location + node.contentRange.length
                      <= span.location + span.length else { continue }
            out.append(contentsOf: InlineParser.parse(ns, in: node.contentRange,
                                                      references: references))
        }
        return out
    }

    /// The image file an inline node stands for, or nil if it stands for
    /// something the editor must leave as source.
    private func inlineImageTarget(_ kind: InlineKind) -> String? {
        let url: String
        switch kind {
        case .link(let u, true): url = u
        case .rawImage(let src): url = src
        default: return nil
        }
        // Local files only, exactly as `blockEmbedKind` decides it: fetching a
        // remote image is a separate decision with a network policy attached.
        guard !url.contains("://"), !url.hasPrefix("data:"), !url.hasPrefix("mailto:") else { return nil }
        // A file with a space in its name is percent-encoded by the time it is
        // written as a Markdown link.
        let path = url.removingPercentEncoding ?? url
        return path.isEmpty ? nil : path
    }

    /// Conceal an inline image's source and put the picture in its place,
    /// **growing the line box the way CSS grows it**.
    ///
    /// The width half is the same trick the maths spans use: the source
    /// collapses to nothing and the last character's `.kern` reserves exactly
    /// the picture's width. The height half is new, and is the part the editor
    /// has never had — it had no inline replaced box at all, so a line with a
    /// picture in it stayed the height of a line of prose.
    ///
    /// Three things make the box. An `NSTextAttachment` is *not* one of them:
    /// TextKit lays an attachment out from the attachment **character**
    /// (U+FFFC) and this storage is byte-pure Markdown with no such character
    /// in it — measured, and the attribute alone changes no line by any amount.
    ///
    /// 1. A **positive** `.baselineOffset` on the concealed first character
    ///    raises that run by the picture's height, so the run's ascent above
    ///    the baseline *is* the picture: that is what a replaced element on the
    ///    baseline contributes to a line box, spelled in the only vocabulary
    ///    TextKit takes. (Positive raises. The half-leading correction
    ///    elsewhere is negative because it works the other way about — it
    ///    lengthens the run's descent.)
    /// 2. The paragraph's `maximumLineHeight` comes off the line, or the pin
    ///    clamps the taller box straight back to 24 and the raise buys nothing.
    ///    `minimumLineHeight` stays: an icon shorter than the strut's ascent
    ///    must not shrink the line, which is CSS's `max` and not an accident.
    /// 3. Nothing else. The descent side of the box — the strut's descender
    ///    plus its half-leading — is already there, on every other run of the
    ///    paragraph, put there by `StyleApplier.applyBase`.
    ///
    /// The line height that comes out is `BlockBoxes.lineHeight(seating:)`, and
    /// only the visual line **carrying** the picture grows: the pin is what
    /// applies to every wrapped line, and the ascent applies to the one run.
    /// `![foo]` / `[]` — one paragraph, two source lines, one picture — is the
    /// example that tells the two apart, and a per-paragraph line height gets
    /// it 2pt wrong.
    private func applyInlineImage(range: NSRange, image: PlatformImage) {
        guard range.length > 1, range.location + range.length <= storage.length,
              image.size.width > 0, image.size.height > 0 else { return }
        isApplyingStyles = true
        storage.beginEditing()
        // The paragraph's half-leading lift, which the drawing needs to find the
        // inked baseline (see `inlineImageBaselineAttribute`). Read at the
        // span's **last** character, never its first: the first one's offset is
        // the raise this function itself writes, and two pictures in one
        // paragraph arrive one at a time — the second one's restyle would have
        // re-read the first's raise as a half-leading and seated it a whole
        // image-height too high. The last character is only ever kerned.
        let lift = (storage.attribute(.baselineOffset, at: range.location + range.length - 1,
                                      effectiveRange: nil) as? CGFloat) ?? 0
        storage.addAttributes([.font: theme.concealed,
                               .foregroundColor: PlatformColor.clear], range: range)
        let first = NSRange(location: range.location, length: 1)
        storage.addAttribute(inlineImageAttribute, value: image, range: first)
        storage.addAttribute(inlineImageBaselineAttribute, value: -lift, range: first)
        storage.addAttribute(.baselineOffset, value: image.size.height, range: first)
        // Exactly the picture's width — an inline `<img>` advances the line by
        // its own width and by nothing else.
        storage.addAttribute(.kern, value: image.size.width,
                             range: NSRange(location: range.location + range.length - 1, length: 1))

        // Let *this* line grow. The style is copied from the line rather than
        // rebuilt, so whatever else it carries — the block's trailing margin
        // when the picture is on the last line, a list item's indents — comes
        // with it.
        let lineNumber = parse.lines.lineNumber(at: range.location)
        let lineRange = parse.lines.lineRange(lineNumber)
        if lineRange.length > 0, lineRange.location + lineRange.length <= storage.length,
           let pinned = storage.attribute(.paragraphStyle, at: lineRange.location,
                                          effectiveRange: nil) as? NSParagraphStyle,
           pinned.maximumLineHeight > 0,
           let relaxed = pinned.mutableCopy() as? NSMutableParagraphStyle {
            relaxed.maximumLineHeight = 0
            storage.addAttribute(.paragraphStyle, value: relaxed, range: lineRange)
        }
        storage.endEditing()
        isApplyingStyles = false
    }
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
