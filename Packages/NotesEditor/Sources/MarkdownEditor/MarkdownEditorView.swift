//
//  MarkdownEditorView.swift
//  MarkdownEditor
//
//  The editor view — an `NSTextView` on one platform and a `UITextView` on the
//  other, bound to the same `EditorDocument`.
//
//  The document, parser, style spec, style applier and block-render fragment
//  are shared; only the view shell differs, which is the same split
//  `NoteOutlineList` makes for the sidebar and `FileViewerView` for PDFs.
//
//  **One gate, not two files.** These were `MarkdownTextView.swift` and
//  `MarkdownUITextView.swift`, each wrapped in a one-sided `#if`, and nothing
//  in either could be seen from the other. That is what let `EditorProxy` be
//  declared twice with different members, `showMatch(of:index:)` exist on one
//  editor only — taking every heading jump with it — and the find command bus
//  reach one of them. None of those failed to compile; all three were found by
//  putting the two side by side, which is what this file is for.
//

import Foundation

/// What the user tapped, resolved for the host app. (Cross-platform.)
public enum EditorLinkTap {
    case wiki(target: String)
    case url(URL)
}

/// How the caret left the top of the text, and therefore where it should land
/// in the chrome above it.
public enum CaretEscape: Equatable, Sendable {
    /// Arrowed up off the first line: keep the column. `x` is measured in points
    /// from the text's left edge, not the view's, so it survives the different
    /// inset and different font on the other side of the seam.
    case vertical(x: CGFloat)
    /// Walked backwards off character zero (← or ⌃B): there is no column to
    /// keep, so land at the very end of what is above.
    case backward
}

#if canImport(AppKit)
import AppKit
import SwiftUI
import MarkdownCore

/// The host's handle on a live editor: programmatic edits (undoable, via
/// the same path typing takes), formatting commands, and navigation. This
/// is the seam app-level AI actions drive — completion acceptance, rewrite-
/// selection results, template insertion all land through `replace`.
@Observable
public final class EditorProxy {
    @ObservationIgnored weak var textView: MarkdownTextView?

    public init() {}

    @discardableResult
    public func replace(range: NSRange, with text: String) -> Bool {
        textView?.performEdit(replacing: range, with: text) ?? false
    }

    public func apply(_ command: EditorFormatCommand) {
        textView?.apply(command)
    }

    public func scroll(to range: NSRange) {
        textView?.reliablyScroll(to: range)
    }

    /// Make the editor first responder with the caret on the **first line**, at
    /// the horizontal offset `x` (points from the text's left edge).
    ///
    /// Used when the caret arrives from chrome *above* the text — the inline
    /// note title — so the two read as one continuous flow. Arrowing down a
    /// column is supposed to keep your place in that column: landing at the
    /// start of the line instead is the thing AppKit spends real effort not
    /// doing within a single text view, and the seam must not undo it.
    public func focusFirstLine(atX x: CGFloat) {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
        let location = tv.offsetOnFirstLine(nearestTo: x)
        tv.setSelectedRange(NSRange(location: location, length: 0))
        tv.document?.selectionDidChange(NSRange(location: location, length: 0))
        tv.scrollRangeToVisible(NSRange(location: location, length: 0))
        // Without this the view is first responder but draws no insertion
        // point: AppKit only restarts the blink timer for focus changes it
        // made itself, so a programmatic handover leaves an invisible caret.
        tv.updateInsertionPointStateAndRestartTimer(true)
    }

    /// The caret arrived from above with no column to honour (it walked
    /// backwards off the start of the title, rather than arrowing down).
    public func focusStart() { focusFirstLine(atX: 0) }

    /// Discard the undo stack after a wholesale text replacement.
    ///
    /// Nothing to do on AppKit: undo lives on the *document's* `UndoManager`,
    /// which `EditorDocument.replaceText` already clears. UIKit resolves
    /// `undoManager` up the responder chain, so its stack survives the
    /// replacement still describing the text that is gone — which is why the
    /// method exists at all. It is here so the host can call it unconditionally
    /// instead of asking which platform it is on.
    public func resetUndo() {}

    /// Restore the insertion point after an in-place buffer replacement
    /// (external reload). Clamps to the new length and deliberately does NOT
    /// autoscroll, so a reload triggered by another editor keeps this view's
    /// scroll position. Also syncs the document's caret-reveal state.
    public func setSelection(_ range: NSRange) {
        guard let tv = textView else { return }
        let len = (tv.string as NSString).length
        let loc = min(max(0, range.location), len)
        let clamped = NSRange(location: loc, length: min(max(0, range.length), len - loc))
        tv.setSelectedRange(clamped)
        tv.document?.selectionDidChange(clamped)
    }

    /// Where the caret is. Lets a deferred rewrite (an image's alt text, a
    /// pasted link's title) name *which* occurrence it meant.
    public func selection() -> NSRange {
        textView?.selectedRange() ?? NSRange(location: NSNotFound, length: 0)
    }

    /// Offer ghost text at `location`, or clear it with `nil`.
    ///
    /// Pushed through the proxy rather than through a SwiftUI binding on
    /// purpose: this changes on a debounce timer while someone is typing, and
    /// routing it through `updateNSView` would re-run the representable's
    /// update on every suggestion — for a value that only ever reaches one
    /// stored property on one view.
    ///
    /// The view refuses anything that no longer describes the current caret,
    /// so a reply that arrives late is dropped rather than shown.
    public func showInlineSuggestion(_ text: String?, at location: Int) {
        guard let tv = textView else { return }
        guard let text, !text.isEmpty else {
            tv.clearInlineSuggestion()
            return
        }
        tv.showInlineSuggestion(InlineSuggestion(location: location, text: text))
    }

    public func clearInlineSuggestion() { textView?.clearInlineSuggestion() }

    /// Insert the showing suggestion. Returns false when there is none, or
    /// when the document moved under it.
    @discardableResult
    public func acceptInlineSuggestion() -> Bool {
        textView?.acceptInlineSuggestion() ?? false
    }

    /// Whether ghost text is on screen right now — for a host that wants to
    /// show an "⌥⇥ to accept" hint, and for tests.
    public var hasInlineSuggestion: Bool { textView?.inlineSuggestion != nil }

    /// Wrap an AI-driven mutation so the document pauses its styling while
    /// the transform streams in, then restyles once at the end.
    public func performAITransform(_ body: (EditorProxy) -> Void) {
        textView?.document?.beginExternalTextSession()
        body(self)
        textView?.document?.endExternalTextSession()
    }
}

public final class MarkdownTextView: NSTextView {

    /// Build the full scroll-view + TextKit 2 text-view assembly. Public so
    /// hosts (and offscreen fidelity-snapshot tests) can embed the exact same
    /// view the representable builds.
    public static func scrollableEditor(document: EditorDocument) -> (NSScrollView, MarkdownTextView) {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.bind(to: document)

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        // From EditorMetrics so a host can align chrome with the text — see
        // the inline note title. One number, not two that drift.
        textView.textContainerInset = NSSize(width: EditorMetrics.textContainerInset.width,
                                             height: EditorMetrics.textContainerInset.height)
        textView.textContainer?.lineFragmentPadding = EditorMetrics.lineFragmentPadding
        textView.drawsBackground = false

        textView.allowsUndo = true
        textView.isRichText = true                       // attributes are ours
        textView.usesFindBar = true                      // native ⌘F
        textView.isIncrementalSearchingEnabled = true
        // Markdown is source text: typographic substitutions corrupt syntax.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.smartInsertDeleteEnabled = false

        // AI-native: full Apple Intelligence Writing Tools (proofread,
        // rewrite, summarize — inline, because this is a real TextKit 2
        // view), constrained to plain text so a rewrite can never come back
        // as rich text and corrupt Markdown syntax.
        if #available(macOS 15.1, *) {
            textView.writingToolsBehavior = .complete
            textView.allowedWritingToolsResultOptions = [.plainText]
        }
        // System inline predictive completion (ghost text) while typing —
        // honoring the user's system-wide keyboard setting rather than
        // forcing it on (predictions can suggest code-shaped fragments
        // that don't belong in Markdown source; the system toggle is the
        // right control surface).
        if #available(macOS 15.0, *) {
            textView.inlinePredictionType = .default
        }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        // Leave `automaticallyAdjustsContentInsets` at its default (true).
        // A SwiftUI window with a toolbar uses `.fullSizeContentView`, so this
        // scroll view extends UP UNDER the toolbar; the automatic content
        // inset is what compensates, and it makes the minimum scroll offset
        // NEGATIVE (-toolbarHeight) so document y=0 can sit below the toolbar.
        // Disabling it leaves the first ~66pt of the note rendered under the
        // toolbar with no way to scroll to it. Verified in a clean-room
        // harness: scratchpad/EditorProbe.swift, stages 7 vs 8.
        scrollView.documentView = textView

        // Progressive styling: as content scrolls into view, make sure its
        // blocks are styled (idempotent; free once the initial pass ends).
        scrollView.contentView.postsBoundsChangedNotifications = true
        // Store the token so the view's `deinit` can remove it — otherwise
        // NotificationCenter retains the registration (and its block) for the
        // process lifetime, leaking one live observer per editor view created.
        textView.boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView, queue: .main
        ) { [weak textView] _ in
            MainActor.assumeIsolated {
                textView?.ensureVisibleRangeStyled()
            }
        }
        return (scrollView, textView)
    }

    /// The scroll-view bounds-change observer registered in `scrollableEditor`.
    /// Assigned once on the main thread; `deinit` only reads it to remove.
    nonisolated(unsafe) private var boundsObserver: NSObjectProtocol?

    // MARK: - Caret escaping upward

    /// Called when the caret leaves the top of the text. The host puts focus on
    /// whatever sits above — the inline note title — so arrowing between them
    /// feels like one document even though the title lives in the filename,
    /// not the file.
    var onCaretEscapeTop: ((CaretEscape) -> Void)?

    /// "At the start" means the start of the *body*: a note whose text opens
    /// with front matter still begins, as far as the reader is concerned, at
    /// the first line after it.
    private var caretIsAtStart: Bool {
        selectedRange().length == 0 && selectedRange().location <= firstBodyLineStart
    }

    public override func moveUp(_ sender: Any?) {
        // Anywhere but the first line this is ordinary caret movement and must
        // behave exactly as AppKit intends. On the first line there is nothing
        // above *in the text*, so the title is what "up" means — and it must
        // arrive there in the same column, which is the whole point of arrowing
        // up rather than clicking.
        if selectedRange().length == 0, caretIsOnFirstLine, let escape = onCaretEscapeTop {
            escape(.vertical(x: caretXOffset))
            return
        }
        super.moveUp(sender)
    }

    public override func moveLeft(_ sender: Any?) {
        if caretIsAtStart, let escape = onCaretEscapeTop { escape(.backward); return }
        super.moveLeft(sender)
    }

    public override func moveBackward(_ sender: Any?) {
        if caretIsAtStart, let escape = onCaretEscapeTop { escape(.backward); return }
        super.moveBackward(sender)
    }

    // MARK: - Where the caret is, horizontally

    /// The caret's x offset from the **text's** left edge (not the view's), so
    /// it means the same thing to a different view with a different inset and a
    /// different font — which is exactly what the title is.
    var caretXOffset: CGFloat {
        guard let frame = segmentFrame(at: selectedRange().location) else { return 0 }
        // Measured from the first glyph, not the container edge: both sides of
        // the seam have their own line-fragment padding, and only the distance
        // into the *text* means the same thing to both.
        return max(0, frame.minX - (textContainer?.lineFragmentPadding ?? 0))
    }

    /// True when the caret sits on the first *visual* line — a soft-wrapped
    /// first paragraph still has real lines above the caret, and moving up
    /// through them is AppKit's job, not ours.
    private var caretIsOnFirstLine: Bool {
        let start = firstBodyLineStart
        guard selectedRange().location >= start,
              let here = segmentFrame(at: selectedRange().location),
              let first = segmentFrame(at: start) else { return caretIsAtStart }
        return abs(here.minY - first.minY) < 0.5
    }

    /// The caret rect for `location`, in text-container coordinates.
    private func segmentFrame(at location: Int) -> CGRect? {
        guard let tlm = textLayoutManager,
              let content = tlm.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: location)
        else { return nil }
        var rect: CGRect?
        tlm.enumerateTextSegments(in: NSTextRange(location: start), type: .selection,
                                  options: [.rangeNotRequired]) { _, frame, _, _ in
            rect = frame
            return false
        }
        return rect
    }

    /// The character offset on the first line closest to `x` (measured from the
    /// text's left edge). Ask the layout for the position rather than counting
    /// characters: the title is set in the document's H1 and the body is not, so
    /// a column is a distance, never a character count.
    func offsetOnFirstLine(nearestTo x: CGFloat) -> Int {
        let start = firstBodyLineStart
        guard x > 0, let firstLine = segmentFrame(at: start) else { return start }
        let origin = textContainerOrigin
        let padding = textContainer?.lineFragmentPadding ?? 0
        let point = CGPoint(x: x + padding + origin.x, y: firstLine.midY + origin.y)
        let offset = characterIndexForInsertion(at: point)
        // Never past that line: a first line shorter than the title must not
        // drop the caret into the second one.
        let end = lineEnd(from: start)
        return min(max(offset, start), end)
    }

    /// Where the note's *text* begins — after any front matter.
    ///
    /// Front matter is concealed until the caret enters it, so landing the
    /// caret on literal line 0 of a note that has some pops the whole `---`
    /// block open. That is the note's metadata appearing in the middle of the
    /// prose, and it belongs in the inspector's Properties tab, not underneath
    /// the title. Arrowing down from the title means "the first line I would
    /// write on", which is the first line after it.
    var firstBodyLineStart: Int {
        guard let document,
              let front = document.parse.blocks.first(where: { $0.kind == .frontMatter })
        else { return 0 }
        let end = NSMaxRange(front.range)
        let text = string as NSString
        return min(end, text.length)
    }

    /// The offset just before the next line break at or after `start` (or the
    /// end of the text).
    private func lineEnd(from start: Int) -> Int {
        let text = string as NSString
        guard start < text.length else { return text.length }
        let search = NSRange(location: start, length: text.length - start)
        let newline = text.range(of: "\n", options: [], range: search)
        return newline.location == NSNotFound ? text.length : newline.location
    }



    // MARK: - Wrap guide

    /// A vertical guide at this many characters, or 0 for none.
    ///
    /// A *guide*, in the Xcode and VS Code sense: a line you can see while the
    /// text still wraps at the view's edge. Making it a wrap point would be a
    /// different (and much more intrusive) feature — anyone who wants a hard
    /// column sets a fixed Editor width instead.
    public var wrapGuideColumns: Int = 0 {
        didSet { if wrapGuideColumns != oldValue { needsDisplay = true } }
    }

    /// Where the guide sits, in view coordinates — `nil` when it is off or
    /// would fall outside the text area, in which case drawing it would just
    /// be a line hugging the edge of the view.
    private var wrapGuideX: CGFloat? {
        guard wrapGuideColumns > 0, let font = document?.theme.body else { return nil }
        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        guard advance > 0 else { return nil }
        let x = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)
              + advance * CGFloat(wrapGuideColumns)
        return x < bounds.width - 1 ? x : nil
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawInlineSuggestion()
        guard let x = wrapGuideX else { return }
        NSColor.separatorColor.withAlphaComponent(0.55).setFill()
        // Hairline at the current backing scale, so it stays one pixel.
        let width = 1 / (window?.backingScaleFactor ?? 2)
        NSRect(x: x, y: dirtyRect.minY, width: width, height: dirtyRect.height).fill()
    }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    /// Ask the document to style what's on screen (± a margin), so fast
    /// scrolling never outruns the background styling pass.
    func ensureVisibleRangeStyled() {
        guard let document, let tlm = textLayoutManager,
              let contentManager = tlm.textContentManager,
              let viewport = tlm.textViewportLayoutController.viewportRange else { return }
        let start = contentManager.offset(from: contentManager.documentRange.location, to: viewport.location)
        let end = contentManager.offset(from: contentManager.documentRange.location, to: viewport.endLocation)
        let margin = 8_000
        let range = NSRange(location: max(0, start - margin), length: (end - start) + 2 * margin)
        guard let styled = document.ensureStyled(charactersIn: range) else { return }
        // Concealment shrinks a run's font; force TextKit 2 to re-lay-out the
        // freshly-styled span so collapsed markers don't keep their old width.
        textLayoutManager?.invalidateLayout(charactersIn: styled)
    }

    private(set) weak var document: EditorDocument?
    /// Retains the layout delegate that vends image-drawing fragments.
    private let blockLayoutDelegate = RenderedBlockLayoutDelegate()
    /// Retains the content-storage delegate that merges the source lines the
    /// page draws as one. `NSTextContentStorage.delegate` is weak.
    private let joinedLineDelegate = JoinedLineDelegate()

    func bind(to document: EditorDocument) {
        self.document = document
        // Block decorations (a blockquote's gutter bar, a callout's band) are
        // painted by the layout fragment, so a restyle that adds or removes one
        // has to re-lay out that range or the old rendering stays on screen.
        document.onRestyle = { [weak self] range in
            self?.textLayoutManager?.invalidateLayout(charactersIn: range)
        }
        // Setting `font` applies it to the **whole text storage attached right
        // now**, so it must be done while no real document is in place. Two
        // separate hazards, and only the first was handled before:
        //
        //  1. It must precede attaching the *new* storage, or it flattens the
        //     per-run concealed (0.1pt) fonts the document has already applied.
        //  2. It must not run while the *previous* document's storage is still
        //     attached — otherwise re-binding reaches back and flattens the
        //     note you just left. Documents outlive their views (they are kept
        //     alive across view churn), so that damage is permanent: headings
        //     came back at body size and folded front matter came back at full
        //     height but still transparent, leaving an empty band at the top.
        //
        // Parking a throwaway storage first gives the assignment somewhere
        // harmless to land.
        if let contentStorage = textContentStorage {
            contentStorage.textStorage = NSTextStorage()
        }
        font = document.theme.body
        typingAttributes = [
            .font: document.theme.body,
            .foregroundColor: document.theme.text,
        ]
        // Custom fragments draw inline-rendered block embeds (images…).
        textLayoutManager?.delegate = blockLayoutDelegate
        // Attach the document's storage to this view's TextKit 2 stack.
        if let contentStorage = textContentStorage {
            // Before the storage, so the first element enumeration already sees
            // the joins: attaching first lays the note out line-for-line and
            // the merge then arrives as a visible reflow.
            contentStorage.delegate = joinedLineDelegate
            contentStorage.textStorage = document.storage
        }
        syncRenderMetrics()
        // Diagnostics: report geometry once layout has settled. Note-open path
        // only, and only when HN_GEOM_LOG asked for it — so an ordinary run
        // doesn't even schedule the work.
        if Self.geomLoggingEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.dumpGeometry("bind")
            }
        }
    }

    /// Feed the document the current usable width + appearance for sizing
    /// rendered block images.
    ///
    /// The container's width is **already** inset — `widthTracksTextView` sizes
    /// it to `bounds.width - 2 * textContainerInset.width` — so taking the
    /// inset off again charged it twice. Every table, diagram, formula and HTML
    /// block in Edit was rendered 32pt narrower than the same block in Preview,
    /// whose content width is `paneWidth - 2 * textLeadingInset` and is the
    /// same 758pt of an 800pt pane the text container gives a line of prose.
    /// The height sweep could not see it: a box that is 32pt narrower is the
    /// same height until something in it wraps, and nothing in 672 one-construct
    /// examples did. Two dumps of the same `<table>`, laid side by side, were
    /// 1452px and 1516px wide. (The iOS half measures `bounds.width` and has
    /// always been right, which is what made the difference look like a
    /// platform quirk rather than a subtraction.)
    ///
    /// And the width is the content width, with **no cap of its own**. It used
    /// to be `min(width, 900)` — an undocumented number that arrived with the
    /// embed feature and that the page has no equivalent of: `img` is
    /// `max-width: 100%` and a `<table>` grows to the column, so on any pane
    /// wider than about 930pt every picture in Edit was smaller than the same
    /// picture in Preview. A 1600×900 screenshot measured −33pt at a 1000pt
    /// pane and −145 at 1200, and no gate could see it: the document sweep runs
    /// at 800 and 560, where the cap never bites, and the spec corpus's own
    /// fixtures are 20×20 squares. Same shape as `RenderedBlockFragment.imageGap`
    /// — a number in a renderer that `GFMBoxMetrics` knew nothing about.
    func syncRenderMetrics() {
        guard let document else { return }
        let padding = (textContainer?.lineFragmentPadding ?? 0) * 2
        let width = (textContainer?.size.width ?? bounds.width - textContainerInset.width * 2)
            - padding
        if width > 0 { document.renderMaxWidth = width }
        document.isDarkAppearance = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    public override func layout() {
        super.layout()
        syncRenderMetrics()
    }

    /// Light ↔ Dark. `syncRenderMetrics()` runs from `layout()`, and switching
    /// appearance does not necessarily lay the view out again — so without this
    /// the document kept the appearance it was born with, and every rendered
    /// block (maths, Mermaid, tables, transclusion cards) stayed drawn in the
    /// old theme's ink while the text around it changed.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        document?.appearanceDidChange(isDark: isDark)
    }

    /// Layout diagnostics, off unless deliberately switched on:
    ///
    ///     HN_GEOM_LOG=1 scripts/relaunch-debug.sh
    ///     cat ~/Library/Containers/com.hellotham.HelloNotes/Data/Library/Caches/hn-geom.log
    ///
    /// A plain file rather than `os_log` — readable from a terminal with `cat`,
    /// with none of the unified log's level/predicate fragility, and with no
    /// need to look at the screen. Debug builds only, and gated, so a shipped
    /// build neither writes the file nor pays for the geometry walk.
    private static let geomLoggingEnabled: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["HN_GEOM_LOG"] != nil
        #else
        return false
        #endif
    }()

    private static let geomLogURL: URL? = {
        (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true))?
            .appendingPathComponent("hn-geom.log")
    }()

    /// Throttle so scroll/layout-driven dumps stay off the hot path.
    private var lastGeomDump = Date.distantPast

    /// Append the editor's scroll/layout geometry to the probe file. Never on
    /// the typing path, and a no-op unless `HN_GEOM_LOG` is set.
    func dumpGeometry(_ tag: String, throttle: Bool = false) {
        guard Self.geomLoggingEnabled else { return }
        let now = Date()
        if throttle, now.timeIntervalSince(lastGeomDump) < 0.2 { return }
        lastGeomDump = now

        let sv = enclosingScrollView
        let insets = sv?.contentInsets ?? NSEdgeInsetsZero
        let autoInsets = sv?.automaticallyAdjustsContentInsets ?? false
        let visible = sv?.documentVisibleRect ?? .zero
        let clipBounds = sv?.contentView.bounds ?? .zero

        // The Y of the first laid-out fragment — if this is negative, or below 0
        // while the clip can't reach it, the document top is offscreen.
        var firstFragTop = CGFloat.nan
        var usage = CGRect.zero
        if let tlm = textLayoutManager {
            usage = tlm.usageBoundsForTextContainer
            tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location,
                                              options: [.ensuresLayout]) { frag in
                firstFragTop = frag.layoutFragmentFrame.origin.y
                return false   // first only
            }
        }

        // Window-relative geometry: is the scroll view's top ABOVE the window's
        // content layout rect (i.e. extending up under the titlebar/toolbar, so
        // content at scroll y=0 is hidden behind it)?
        let winFrame = window?.frame ?? .zero
        let contentLayout = window?.contentLayoutRect ?? .zero
        let svInWindow = sv.map { $0.convert($0.bounds, to: nil) } ?? .zero
        // Caret rect (first selection) in view coords, if any.
        var caretRect = CGRect.zero
        if let tlm = textLayoutManager, let sel = tlm.textSelections.first?.textRanges.first {
            tlm.enumerateTextSegments(in: sel, type: .selection, options: []) { _, rect, _, _ in
                caretRect = rect; return false
            }
        }
        let head = (self.textStorage?.string.prefix(28)).map { String($0).replacingOccurrences(of: "\n", with: "⏎") } ?? ""

        let line = "[\(tag)] autoInsets=\(autoInsets) "
            + "contentInsets.top=\(String(format: "%.1f", insets.top)) "
            + "tvFrame=\(NSStringFromRect(self.frame)) "
            + "tcInset.h=\(String(format: "%.1f", self.textContainerInset.height)) "
            + "firstFragTop=\(String(format: "%.1f", firstFragTop)) "
            + "caret=\(NSStringFromRect(caretRect)) "
            + "usage=\(NSStringFromRect(usage)) "
            + "docVisible=\(NSStringFromRect(visible)) "
            + "clipBounds=\(NSStringFromRect(clipBounds)) "
            + "svInWindow=\(NSStringFromRect(svInWindow)) "
            + "contentLayoutRect=\(NSStringFromRect(contentLayout)) "
            + "winH=\(String(format: "%.0f", winFrame.height)) "
            + "head=\"\(head)\" "
            + "len=\(self.textStorage?.length ?? -1)"

        // Walk UP from the scroll view to the window's content view, printing
        // each ancestor's height. Whichever ancestor is taller than the
        // window's content area is the one proposing the oversized height.
        var chain = "\n  ancestors (bottom-up):"
        var node: NSView? = sv
        var depth = 0
        while let v = node, depth < 14 {
            chain += "\n    \(depth): \(type(of: v)) h=\(String(format: "%.1f", v.frame.height))"
                + " y=\(String(format: "%.1f", v.frame.origin.y))"
            node = v.superview
            depth += 1
        }

        guard let url = Self.geomLogURL,
              let data = (line + chain + "\n").data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile(); fh.write(data); try? fh.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Accessibility: VoiceOver headings rotor

    /// A standard VoiceOver "Headings" rotor so a long note can be navigated by
    /// heading like a web page. Backed by the document's already-extracted
    /// headings; `.heading` is the system rotor type VoiceOver users expect.
    private lazy var headingRotor = NSAccessibilityCustomRotor(rotorType: .heading, itemSearchDelegate: self)

    public override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] {
        [headingRotor]
    }

    /// Pasteboard intents, injected by the host: return the Markdown to
    /// insert (image saved to the vault, HTML converted, …) or nil to fall
    /// through to the default plain paste.
    /// Convert whatever is on the pasteboard to Markdown, or nil to paste as
    /// usual. No argument: it was `(NSPasteboard) -> String?`, and a host
    /// cannot supply an `NSPasteboard` on iOS — so one hook the two platforms
    /// could not share, for a parameter every caller filled with
    /// `NSPasteboard.general`.
    var onPasteMarkdown: (() -> String?)?
    /// Save a pasted image and return the Markdown link to insert. UIKit has
    /// had this as its own hook since the iOS editor shipped; AppKit folded it
    /// into `onPasteMarkdown` at the call site, so the two hosts took different
    /// paste arguments for identical behaviour.
    var onPasteImage: (() -> String?)?

    /// Reports the caret's autocomplete context (`[[link` / `#tag`) and its
    /// rect in this view's enclosing scroll-view coordinates, or nil.
    var onInlineContextChange: ((EditorDocument.InlineContext?, CGRect) -> Void)?

    /// Host AI hook: when set (and the view is editable), the selection's
    /// context menu offers "Rewrite with AI…", delivering the selected range.
    var onRewriteSelection: ((NSRange) -> Void)?
    /// Host actions added to the selection's context menu — the same hook UIKit
    /// has, so the vault actions are offered by one mechanism on both platforms
    /// rather than by a menu here and a floating bar there.
    var selectionMenuItems: ((String) -> [EditorMenuItem])?


    /// Ghost text, drawn after the caret and **never** in the text storage.
    /// See `InlineSuggestion.swift` — the invariant is the feature.
    ///
    /// Read it through the computed `inlineSuggestion`, which re-checks the
    /// caret. This is the raw value and may be stale.
    var storedInlineSuggestion: InlineSuggestion?
    /// Asks the host for a completion. Debouncing and the model live there;
    /// this view only knows where the caret is and what is around it.
    var onInlineCompletionRequest: ((InlineCompletionContext) -> Void)?

    // MARK: - Inline completion keys

    /// ⌥⇥ accepts.
    ///
    /// Not ⇥, which indents and outdents lists; not ⌃⇥, which macOS uses for
    /// tab cycling and this app has editor tabs. ⌥⇥ is bound nowhere else, is
    /// not a standard `NSTextView` binding, and — unlike ⌥+letter — produces no
    /// character, so intercepting it cannot swallow someone's typing.
    public override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 48, modifiers == .option, inlineSuggestion != nil {
            if acceptInlineSuggestion() { return }
        }
        super.keyDown(with: event)
    }

    /// → accepts while a suggestion shows: the caret moves *into* the ghost,
    /// which is what the ghost looks like it is inviting. Safe to consume only
    /// because suggestions are offered at end-of-line, where → would otherwise
    /// just wrap to the next line.
    public override func moveRight(_ sender: Any?) {
        if inlineSuggestion != nil, acceptInlineSuggestion() { return }
        super.moveRight(sender)
    }

    /// Esc dismisses — but only when there is something to dismiss, so the
    /// wiki-link autocomplete and the find bar keep their Escape.
    public override func cancelOperation(_ sender: Any?) {
        if inlineSuggestion != nil {
            clearInlineSuggestion()
            return
        }
        super.cancelOperation(sender)
    }

    /// macOS binds `complete:` to ⌥Esc and F5 in every text view, so asking for
    /// a suggestion on demand costs nothing. Falls back to AppKit's own word
    /// completion when no host is offering completions, rather than removing a
    /// standard behaviour in exchange for nothing.
    public override func complete(_ sender: Any?) {
        guard onInlineCompletionRequest != nil else {
            super.complete(sender)
            return
        }
        requestInlineCompletion()
    }

    public override func didChangeText() {
        super.didChangeText()
        clearInlineSuggestion()
        // Next runloop turn on purpose: `performEdit` calls this *before* it
        // moves the caret, so asking now would describe the caret's old
        // position and the host's reply would be rejected as stale. The host
        // debounces anyway, so the hop is free.
        DispatchQueue.main.async { [weak self] in self?.requestInlineCompletion() }
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        let selection = selectedRange()
        guard selection.length > 0 else { return menu }

        var inserted = 0
        // Rewrite first, then the vault actions — the same order UIKit builds
        // them in, so the two menus read the same way.
        if onRewriteSelection != nil, isEditable {
            let item = NSMenuItem(title: String(localized: "Rewrite with AI…"),
                                  action: #selector(rewriteSelectionFromMenu(_:)),
                                  keyEquivalent: "")
            item.target = self
            menu?.insertItem(item, at: inserted)
            inserted += 1
        }
        if let selectionMenuItems {
            let selected = (string as NSString).substring(with: selection)
            for action in selectionMenuItems(selected) {
                let item = NSMenuItem(title: action.title,
                                      action: #selector(runSelectionItem(_:)),
                                      keyEquivalent: "")
                item.target = self
                // The closure travels with the item, so the menu can be built
                // fresh per selection without the view holding the actions.
                item.representedObject = SelectionMenuAction(perform: action.perform,
                                                             selected: selected)
                if let symbol = action.systemImage {
                    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                }
                menu?.insertItem(item, at: inserted)
                inserted += 1
            }
        }
        if inserted > 0 { menu?.insertItem(.separator(), at: inserted) }
        return menu
    }

    /// Carries one host action and the text it was offered for.
    private final class SelectionMenuAction: NSObject {
        let perform: (String) -> String?
        let selected: String
        init(perform: @escaping (String) -> String?, selected: String) {
            self.perform = perform
            self.selected = selected
        }
    }

    @objc private func runSelectionItem(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let action = item.representedObject as? SelectionMenuAction else { return }
        guard let replacement = action.perform(action.selected) else { return }
        // Through `performEdit`, the path typing takes, so the edit lands in the
        // undo stack and the document's change notifications fire as usual.
        performEdit(replacing: selectedRange(), with: replacement)
    }

    @objc private func rewriteSelectionFromMenu(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length > 0 else { return }
        onRewriteSelection?(selection)
    }

    // Report every selection movement so the document can flip syntax
    // reveal on the caret's block (O(paragraph)).
    public override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting, let document {
            document.selectionDidChange(selectedRange())
            reportInlineContext()
            // Moving the caret is not typing, so this clears without asking for
            // a new one — a suggestion that followed the caret around would be
            // answering a question nobody asked.
            clearInlineSuggestion()
        }
    }

    public override func mouseDown(with event: NSEvent) {
        // A click on a rendered task checkbox toggles `[ ]` ↔ `[x]` instead
        // of moving the caret.
        if toggleTaskCheckbox(at: event) { return }
        // A click on a callout header's fold chevron toggles the fold.
        if toggleCalloutFold(at: event) { return }
        super.mouseDown(with: event)
    }

    /// If the click landed on a foldable callout header's right-aligned
    /// disclosure chevron, toggle the fold and return true.
    private func toggleCalloutFold(at event: NSEvent) -> Bool {
        guard let document, let storage = textStorage,
              let container = textContainer else { return false }
        let point = convert(event.locationInWindow, from: nil)
        // The chevron sits at the right edge of the text container.
        let containerRight = textContainerOrigin.x + container.size.width
        let chevronZoneLeft = containerRight - RenderedBlockFragment.calloutChevronInset - 10
        guard point.x >= chevronZoneLeft else { return false }

        let index = characterIndexForInsertion(at: point)
        guard index >= 0, index <= storage.length else { return false }
        let ns = storage.string as NSString
        let line = ns.lineRange(for: NSRange(location: min(index, max(0, ns.length - 1)), length: 0))
        guard document.isFoldableCalloutHeader(atCharacter: line.location) else { return false }
        guard let blockRange = document.toggleCalloutFold(atHeaderOffset: line.location) else { return false }
        textLayoutManager?.invalidateLayout(charactersIn: blockRange)
        // The chevron only shows when the callout isn't revealed, so the caret
        // is already elsewhere — leave the selection untouched.
        return true
    }

    /// If the click landed on a concealed task box, toggle it (undoably) and
    /// return true. The box is 3 chars (`[ ]`); we accept a click anywhere in
    /// that range plus the glyph's small overhang.
    private func toggleTaskCheckbox(at event: NSEvent) -> Bool {
        guard isEditable, let storage = textStorage else { return false }
        // The selection before this click (we intercept before super.mouseDown,
        // so this is where the caret was, not the checkbox we're clicking).
        let priorSelection = selectedRange()
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        // Check the clicked index and the three before it (the click may land
        // just after the box; the attribute spans the 3-char `[ ]`).
        for probe in stride(from: min(index, storage.length - 1), through: max(0, index - 3), by: -1) {
            guard probe < storage.length else { continue }
            var effective = NSRange(location: 0, length: 0)
            if let checked = storage.attribute(taskCheckboxAttribute, at: probe, effectiveRange: &effective) as? Bool {
                let ns = storage.string as NSString
                // The state char is the middle of `[ ]` / `[x]`.
                let stateIndex = effective.location + 1
                guard stateIndex < ns.length else { return false }
                let replacement = checked ? " " : "x"
                let stateRange = NSRange(location: stateIndex, length: 1)
                performEdit(replacing: stateRange, with: replacement)
                // Restore the pre-click selection. The toggle is a 1-for-1 char
                // replacement (no length change), so offsets are unchanged — and
                // this keeps the caret OUT of the toggled block, so the checkbox
                // stays rendered instead of revealing its raw `- [x]` source
                // (which `effective.location`, inside the block, would trigger).
                setSelectedRange(priorSelection)
                return true
            }
        }
        return false
    }

    public override func paste(_ sender: Any?) {
        if let onPasteImage, let markdown = onPasteImage() {
            performEdit(replacing: selectedRange(), with: markdown)
            return
        }
        if let onPasteMarkdown, let markdown = onPasteMarkdown() {
            performEdit(replacing: selectedRange(), with: markdown)
            return
        }
        pasteAsPlainText(sender)   // never import rich text into Markdown
    }

    /// Copy only the plain-text Markdown source. This is a rich-text view (our
    /// styling lives in the storage), so the default copy would also write an
    /// RTF flavor carrying the concealed 0.1pt / clear-color marker runs —
    /// pasting that into Mail/Pages yields invisible, un-round-trippable text.
    public override func copy(_ sender: Any?) {
        let selected = (string as NSString).substring(with: selectedRange())
        guard !selected.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(selected, forType: .string)
    }

    public override func cut(_ sender: Any?) {
        guard selectedRange().length > 0 else { return }
        copy(sender)
        deleteBackward(sender)
    }

    func reportInlineContext() {
        guard let onInlineContextChange, let document else { return }
        let selection = selectedRange()
        guard selection.length == 0,
              let context = document.inlineContext(at: selection.location) else {
            onInlineContextChange(nil, .zero)
            return
        }
        onInlineContextChange(context, caretRect(at: selection.location))
    }


    /// The caret's rect in the enclosing scroll view's coordinate space —
    /// which is what a SwiftUI `.overlay` on the wrapper sees.
    private func caretRect(at location: Int) -> CGRect {
        guard let tlm = textLayoutManager,
              let contentManager = tlm.textContentManager,
              let start = contentManager.location(contentManager.documentRange.location, offsetBy: location)
        else { return .zero }
        let range = NSTextRange(location: start)
        var rect = CGRect.zero
        tlm.enumerateTextSegments(in: range, type: .selection, options: [.rangeNotRequired]) { _, frame, _, _ in
            rect = frame
            return false
        }
        rect = rect.offsetBy(dx: textContainerInset.width, dy: textContainerInset.height)
        guard let scrollView = enclosingScrollView else { return rect }
        return convert(rect, to: scrollView)
    }

    /// Scroll a character range into view the TextKit 2-safe way: lay out
    /// the target first, then scroll to its real frame (estimated heights
    /// make a bare scrollRangeToVisible land short on long documents).
    public func reliablyScroll(to range: NSRange) {
        guard let tlm = textLayoutManager,
              let contentManager = tlm.textContentManager,
              let start = contentManager.location(contentManager.documentRange.location, offsetBy: range.location),
              let end = contentManager.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else {
            scrollRangeToVisible(range)
            return
        }
        tlm.ensureLayout(for: textRange)
        var frame: CGRect? = nil
        tlm.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, rect, _, _ in
            frame = frame?.union(rect) ?? rect
            return true
        }
        if let frame {
            scrollToVisible(frame.insetBy(dx: 0, dy: -40).offsetBy(dx: textContainerInset.width, dy: textContainerInset.height))
        } else {
            scrollRangeToVisible(range)
        }
    }
}

// MARK: - SwiftUI wrapper

/// The SwiftUI editor. Holds a reference to the document — text never
/// round-trips through SwiftUI, so updateNSView has almost nothing to do
/// (the exact property that makes large-note editing cheap).
public struct MarkdownEditorView: NSViewRepresentable {
    private let document: EditorDocument
    private var isEditable = true
    private var onLinkTap: ((EditorLinkTap) -> Void)?
    private var onPasteMarkdown: (() -> String?)?
    private var selectionMenuItemsBuilder: ((String) -> [EditorMenuItem])?
    private var onPasteImageHandler: (() -> String?)?
    private var onInlineContext: ((EditorDocument.InlineContext?, CGRect) -> Void)?
    private var onRewriteSelectionHandler: ((NSRange) -> Void)?
    private var busDocumentId: String?
    private var editorProxy: EditorProxy?
    private var wrapGuideColumns = 0
    private var onCaretEscapeTopHandler: ((CaretEscape) -> Void)?
    private var onInlineCompletionRequestHandler: ((InlineCompletionContext) -> Void)?

    public init(document: EditorDocument) {
        self.document = document
    }

    /// Take exactly the space offered — never advertise an ideal size.
    ///
    /// Without this, SwiftUI sizes the representable from the scroll view's
    /// `fittingSize`, which derives from its document view: the WHOLE note
    /// (measured at 3433pt for a 76-line note). That ideal height propagates
    /// up — detail column 1477.5pt, `NSSplitView` 1477.5pt — so the entire
    /// `NavigationSplitView` became taller than the 923pt window and was
    /// offset to y = -251. The top of every note was laid out *above* the
    /// window and no scrolling could reach it.
    ///
    /// A scroll view must never report its content's height as its ideal size;
    /// it is by definition a viewport onto content larger than itself. Never
    /// return nil here: that falls back to `fittingSize` and re-arms the bug.
    public func sizeThatFits(_ proposal: ProposedViewSize,
                             nsView: NSScrollView,
                             context: Context) -> CGSize? {
        viewportSizeThatFits(proposal)
    }

    public func editable(_ flag: Bool) -> Self {
        var copy = self; copy.isEditable = flag; return copy
    }

    /// Show a vertical guide at `columns` characters, or 0 for none. A line to
    /// see, not a wrap point — the text still runs to the edge of the pane.
    public func wrapGuide(_ columns: Int) -> Self {
        var copy = self; copy.wrapGuideColumns = columns; return copy
    }

    /// Called when the caret leaves through the top of the document.
    public func onCaretEscapeTop(_ handler: @escaping (CaretEscape) -> Void) -> Self {
        var copy = self; copy.onCaretEscapeTopHandler = handler; return copy
    }

    public func onLinkTap(_ handler: @escaping (EditorLinkTap) -> Void) -> Self {
        var copy = self; copy.onLinkTap = handler; return copy
    }

    /// Host paste hook: return Markdown to insert, or nil for plain paste.
    public func onPasteMarkdown(_ handler: @escaping () -> String?) -> Self {
        var copy = self; copy.onPasteMarkdown = handler; return copy
    }

    /// Save a pasted image and return the Markdown link to insert.
    public func onPasteImage(_ handler: @escaping () -> String?) -> Self {
        var copy = self; copy.onPasteImageHandler = handler; return copy
    }

    /// Host actions added to the selection's menu. Called with the selected
    /// text each time the menu is built, so the host can decide per selection
    /// which items make sense — an item that cannot apply is better absent than
    /// present and inert.
    public func selectionMenuItems(_ build: @escaping (String) -> [EditorMenuItem]) -> Self {
        var copy = self; copy.selectionMenuItemsBuilder = build; return copy
    }

    /// Autocomplete context reporting (`[[link` / `#tag` at the caret, with
    /// the caret rect in the wrapper's coordinate space).
    public func onInlineContext(_ handler: @escaping (EditorDocument.InlineContext?, CGRect) -> Void) -> Self {
        var copy = self; copy.onInlineContext = handler; return copy
    }

    /// AI rewrite hook: adds "Rewrite with AI…" to the selection context
    /// menu; the handler receives the selected range (resolve its text via
    /// `document.text(in:)`, apply results via the proxy).
    public func onRewriteSelection(_ handler: @escaping (NSRange) -> Void) -> Self {
        var copy = self; copy.onRewriteSelectionHandler = handler; return copy
    }


    /// Join the app's per-document notification bus (Format menu commands,
    /// find bar queries, scroll-to-heading) under this document id.
    public func commandBus(documentId: String) -> Self {
        var copy = self; copy.busDocumentId = documentId; return copy
    }

    /// Attach a host-side handle for programmatic edits and commands.
    public func proxy(_ proxy: EditorProxy) -> Self {
        var copy = self; copy.editorProxy = proxy; return copy
    }

    /// Ghost-text hook: the editor asks here when the caret settles somewhere a
    /// completion could be shown; answer through the proxy's
    /// `showInlineSuggestion`. Installing it also takes over ⌥Esc / F5.
    public func onInlineCompletionRequest(_ handler: @escaping (InlineCompletionContext) -> Void) -> Self {
        var copy = self; copy.onInlineCompletionRequestHandler = handler; return copy
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let (scrollView, textView) = MarkdownTextView.scrollableEditor(document: document)
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.subscribeToBus(documentId: busDocumentId)
        applyProperties(textView)
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownTextView else { return }
        // The other half of the re-target: the Coordinator outlives a note
        // switch here, so `make` alone is not enough.
        context.coordinator.subscribeToBus(documentId: busDocumentId)
        if textView.document !== document {
            textView.bind(to: document)
        }
        context.coordinator.onLinkTap = onLinkTap
        textView.wrapGuideColumns = wrapGuideColumns
        textView.onCaretEscapeTop = onCaretEscapeTopHandler
        textView.onPasteMarkdown = onPasteMarkdown
        textView.onPasteImage = onPasteImageHandler
        textView.selectionMenuItems = selectionMenuItemsBuilder
        textView.onInlineContextChange = onInlineContext
        textView.onRewriteSelection = onRewriteSelectionHandler
        textView.onInlineCompletionRequest = onInlineCompletionRequestHandler
        editorProxy?.textView = textView
        applyProperties(textView)
    }

    private func applyProperties(_ textView: MarkdownTextView) {
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
            textView.insertionPointColor = isEditable ? document.theme.text : .clear
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(document: document, onLinkTap: onLinkTap)
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        let document: EditorDocument
        var onLinkTap: ((EditorLinkTap) -> Void)?
        weak var textView: MarkdownTextView?
        // Registered/removed on the main thread; deinit only removes.
        nonisolated(unsafe) private var busTokens: [NSObjectProtocol] = []
        /// What the tokens above are addressed to, so a note switch re-targets
        /// them rather than leaving them pointed at the note you left.
        private var busDocumentId: String?
        private var findQuery = ""
        private var findIndex = 0

        init(document: EditorDocument, onLinkTap: ((EditorLinkTap) -> Void)?) {
            self.document = document
            self.onLinkTap = onLinkTap
        }

        deinit {
            for token in busTokens { NotificationCenter.default.removeObserver(token) }
        }

        public func undoManager(for view: NSTextView) -> UndoManager? {
            document.undoManager
        }

        /// Keep the spell checker out of code and maths. Returning 0 clears the
        /// spelling state for that range, so no misspelling underline is drawn.
        ///
        /// Necessary because the underline is the one part of a concealed block
        /// the 0.1pt font does *not* shrink: a collapsed `$$…$$` rendered its
        /// formula correctly and then painted a red squiggle above it, from the
        /// LaTeX source nobody can see.
        public func textView(_ textView: NSTextView,
                             shouldSetSpellingState value: Int,
                             range affectedCharRange: NSRange) -> Int {
            document.isSourceOnly(affectedCharRange) ? 0 : value
        }

        // MARK: Writing Tools session lifecycle — pause our restyling so it
        // never fights the session's own decorations; one catch-up restyle
        // at the end.

        public func textViewWritingToolsWillBegin(_ textView: NSTextView) {
            document.beginExternalTextSession()
        }

        public func textViewWritingToolsDidEnd(_ textView: NSTextView) {
            document.endExternalTextSession()
        }

        // MARK: App command bus (same notification names the app's Format
        // menu, find bar, and outline already post).

        /// Observe formatting and find commands addressed to `documentId`.
        ///
        /// **Re-targets.** This guarded on `busTokens.isEmpty` and was called
        /// only from `makeNSView`, while the UIKit half keys on the id and
        /// re-registers from both `make` and `update`. The AppKit representable
        /// carries no `.id()` — the iOS one wraps itself in
        /// `.id(ObjectIdentifier(document))` — so its Coordinator survives a
        /// note switch, and after the first switch it was still listening on
        /// `hnEditorFormat.<kind>.<note A>` while the Format menu posted
        /// `<note B>`. Bold, Italic and Heading did nothing from the second
        /// note onward, silently. Find kept working, which is why it never
        /// looked like a dead bus: those names carry no document id.
        func subscribeToBus(documentId: String?) {
            guard busDocumentId != documentId else { return }
            for token in busTokens { NotificationCenter.default.removeObserver(token) }
            busTokens.removeAll()
            busDocumentId = documentId
            guard let documentId, !documentId.isEmpty else { return }
            let center = NotificationCenter.default

            let formats: [(String, EditorFormatCommand)] = [
                ("bold", .bold), ("italic", .italic), ("strikethrough", .strikethrough),
                ("highlight", .highlight), ("inlineCode", .inlineCode),
                ("blockquote", .blockquote), ("unorderedList", .unorderedList),
                ("orderedList", .orderedList),
            ]
            for (kind, command) in formats {
                busTokens.append(center.addObserver(
                    forName: Notification.Name("hnEditorFormat.\(kind).\(documentId)"),
                    object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.textView?.apply(command) }
                })
            }
            busTokens.append(center.addObserver(
                forName: Notification.Name("hnEditorFormat.heading.\(documentId)"),
                object: nil, queue: .main
            ) { [weak self] note in
                let level = note.userInfo?["level"] as? Int ?? 1
                MainActor.assumeIsolated { [level] in self?.textView?.apply(.heading(level)) }
            })

            // Find bar + scroll-to-heading (both arrive as find queries).
            busTokens.append(center.addObserver(
                forName: Notification.Name("hn.editor.findQuery"),
                object: nil, queue: .main
            ) { [weak self] note in
                let query = note.userInfo?["query"] as? String ?? ""
                let index = note.userInfo?["currentIndex"] as? Int
                MainActor.assumeIsolated { [query, index] in
                    guard let self, let textView = self.textView, textView.window != nil else { return }
                    if query != self.findQuery { self.findIndex = 0 }
                    self.findQuery = query
                    if let index { self.findIndex = index }
                    let count = textView.showMatch(of: query, index: self.findIndex)
                    NotificationCenter.default.post(
                        name: Notification.Name("hn.editor.findResults"),
                        object: nil, userInfo: ["count": count])
                }
            })
            busTokens.append(center.addObserver(
                forName: Notification.Name("hn.editor.replaceCurrent"),
                object: nil, queue: .main
            ) { [weak self] note in
                let replacement = note.userInfo?["replacement"] as? String
                MainActor.assumeIsolated { [replacement] in
                    guard let self, let textView = self.textView, textView.window != nil,
                          let replacement else { return }
                    let sel = textView.selectedRange()
                    if sel.length > 0 { textView.performEdit(replacing: sel, with: replacement) }
                    _ = textView.showMatch(of: self.findQuery, index: self.findIndex)
                }
            })
            busTokens.append(center.addObserver(
                forName: Notification.Name("hn.editor.replaceAll"),
                object: nil, queue: .main
            ) { [weak self] note in
                let replacement = note.userInfo?["replacement"] as? String
                MainActor.assumeIsolated { [replacement] in
                    guard let self, let textView = self.textView, textView.window != nil,
                          let replacement,
                          !self.findQuery.isEmpty else { return }
                    // Back to front, so earlier ranges stay valid.
                    for range in self.document.findMatches(of: self.findQuery).reversed() {
                        textView.performEdit(replacing: range, with: replacement)
                    }
                }
            })
            busTokens.append(center.addObserver(
                forName: Notification.Name("hn.editor.clearHighlights"),
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let textView = self.textView, textView.window != nil else { return }
                    self.findQuery = ""
                    self.findIndex = 0
                    let caret = textView.selectedRange()
                    textView.setSelectedRange(NSRange(location: caret.location, length: 0))
                }
            })
        }

        public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let onLinkTap else { return false }
            if let url = link as? URL {
                if url.scheme == "hellonotes-wiki" {
                    // The raw target travels in the custom attribute (the
                    // URL form is only for hover/click affordances).
                    let target = textView.textStorage?.attribute(wikiTargetAttribute, at: charIndex, effectiveRange: nil) as? String
                    if let target {
                        onLinkTap(.wiki(target: target))
                        return true
                    }
                    if let host = url.host()?.removingPercentEncoding {
                        onLinkTap(.wiki(target: host))
                        return true
                    }
                    return false
                }
                onLinkTap(.url(url))
                return true
            }
            return false
        }
    }
}

extension MarkdownTextView: NSAccessibilityCustomRotorItemSearchDelegate {
    @objc public func rotor(_ rotor: NSAccessibilityCustomRotor,
                            resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters)
        -> NSAccessibilityCustomRotor.ItemResult? {
        guard let heading = document?.rotorHeading(
            after: searchParameters.currentItem?.targetRange.location,
            forward: searchParameters.searchDirection == .next,
            matching: searchParameters.filterString ?? ""
        ) else { return nil }
        let result = NSAccessibilityCustomRotor.ItemResult(targetElement: self)
        result.targetRange = heading.range
        result.customLabel = heading.title
        return result
    }
}

#else
import UIKit
import SwiftUI
import MarkdownCore

/// A TextKit 2 `UITextView` bound to an `EditorDocument`'s storage.
public final class MarkdownUITextView: UITextView {

    private(set) weak var document: EditorDocument?
    /// Retains the layout delegate that vends chrome-drawing fragments.
    /// `lazy`, not a stored default: `init(usingTextLayoutManager:)` is an
    /// inherited convenience initializer that skips the subclass's stored-
    /// property synthesis, leaving plain defaults null (a weak-assign into a
    /// null `chromeOverlay` faults at 0x8). Lazy init runs on first access.
    private lazy var blockLayoutDelegate = RenderedBlockLayoutDelegate()
    /// Retains the content-storage delegate that merges the source lines the
    /// page draws as one — `NSTextContentStorage.delegate` is weak, and here
    /// the stack is built before the view, so `make` hands it over.
    var joinedLineDelegate: JoinedLineDelegate?
    /// Draws the fragment chrome (bullets, callout bands, checkboxes, gutter
    /// bars, heading rules) — UITextView doesn't invoke custom fragments' draw.
    private lazy var chromeOverlay = ChromeOverlayView()
    var onLinkTap: ((EditorLinkTap) -> Void)?
    /// Keeps the link tap from competing with the text view's own caret tap.
    /// A separate object, deliberately: `UITextView` is already the delegate of
    /// its own recognisers, so making the view the delegate would replace
    /// UIKit's arbitration for all of them, not just add to ours. `delegate` is
    /// weak, so the view has to hold it.
    private lazy var linkTapDelegate = LinkTapDelegate()
    /// The link tap, exposed so its arbitration can be asserted.
    private(set) var linkTapRecognizer: UITapGestureRecognizer?

    /// Ghost text. See `InlineSuggestion.swift` — the invariant *is* the
    /// feature. Read it through the computed `inlineSuggestion`, which
    /// re-validates it against the caret; never through this directly.
    var storedInlineSuggestion: InlineSuggestion?
    /// The host's completion source. Nil disables ghost text outright, which is
    /// what a build without an on-device model amounts to.
    var onInlineCompletionRequest: ((InlineCompletionContext) -> Void)?

    /// Asked for "Rewrite with AI…" on the current selection.
    ///
    /// The same hook `MarkdownTextView` has, delivered the same way: the view
    /// contributes a menu item and hands the *range* back, because what happens
    /// next is a sheet with alternatives, a replace and an insert-below — none
    /// of which fits `EditorMenuItem`'s synchronous `(String) -> String?`. That
    /// mismatch is why the iPad's edit menu offered Link, Find Related and Ask
    /// Your Library but not the fourth one the Mac's context menu has.
    var onRewriteSelection: ((NSRange) -> Void)?

    /// A *guide*, in the Xcode and VS Code sense: a line you can see while the
    /// text still wraps at the view's edge — the same thing `MarkdownTextView`
    /// draws on the Mac, and the same reason it is a guide rather than a wrap
    /// point (a hard column is the Editor width setting instead).
    ///
    /// Painted by `ChromeOverlayView`, not here: UIKit does not call a
    /// `UITextView` subclass's `draw(_:)` over its own text, which is why every
    /// other piece of editor chrome lives on that overlay too.
    public var wrapGuideColumns: Int = 0 {
        didSet {
            guard wrapGuideColumns != oldValue else { return }
            chromeOverlay.setNeedsDisplay()
        }
    }

    /// Where the guide sits, in the overlay's coordinates — `nil` when it is
    /// off or would fall outside the text area, where it would just be a line
    /// hugging the edge of the view.
    public var wrapGuideX: CGFloat? {
        guard wrapGuideColumns > 0, let font = document?.theme.body else { return nil }
        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        guard advance > 0 else { return nil }
        let x = textContainerInset.left + textContainer.lineFragmentPadding
              + advance * CGFloat(wrapGuideColumns)
        return x < bounds.width - 1 ? x : nil
    }

    /// The formatting bar above the keyboard.
    ///
    public static func make(document: EditorDocument) -> MarkdownUITextView {
        // Build the TextKit 2 stack around the document's storage *first*, and
        // hand the finished container to the initialiser.
        //
        // The alternative — construct the view, then assign
        // `textContentStorage.textStorage` — is what AppKit's half does, and it
        // does not work here. A TextKit 2 `UITextView` keeps two references to
        // the document: the content storage the layout manager reads, and its
        // own `textStorage`. Replacing the first leaves the second pointing at
        // whatever storage the initialiser made, so the view reports
        // `textStorage.length == 0` and `text == ""` for a 19,450-character
        // note while its layout manager lays out all 19,450. UIKit then takes a
        // range from one and reads attributes from the other:
        //
        //     NSRangeException: -[NSConcreteTextStorage
        //     attribute:atIndex:longestEffectiveRange:inRange:]
        //
        // thrown from inside UIKit with no app frames on the stack, on any tap
        // or selection past the start of the document. Harmless while notes
        // were empty; fatal the moment they had content.
        // `UITextViewBindTests` holds the invariant.
        let contentStorage = NSTextContentStorage()
        let joins = JoinedLineDelegate()
        contentStorage.delegate = joins
        contentStorage.textStorage = document.storage
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.textContainer = container

        let tv = MarkdownUITextView(frame: .zero, textContainer: container)
        tv.joinedLineDelegate = joins          // `delegate` above is weak
        tv.bind(to: document)
        tv.isEditable = true
        tv.isScrollEnabled = true
        tv.alwaysBounceVertical = true
        tv.backgroundColor = .clear
        // From EditorMetrics so a host can align chrome with the text.
        tv.textContainerInset = UIEdgeInsets(top: EditorMetrics.textContainerInset.height,
                                             left: EditorMetrics.textContainerInset.width,
                                             bottom: EditorMetrics.textContainerInset.height,
                                             right: EditorMetrics.textContainerInset.width)
        tv.textContainer.lineFragmentPadding = EditorMetrics.lineFragmentPadding
        // Markdown is source text: typographic substitutions corrupt syntax.
        // Autocorrect/autocapitalization can rewrite source (e.g. inside code
        // spans or link targets), so disable them, matching the macOS view.
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartDashesType = .no
        tv.smartQuotesType = .no
        tv.smartInsertDeleteType = .no
        // **`.no`, and it is a performance fix, not a preference.**
        //
        // The Mac keeps continuous spell checking on (`isContinuousSpellChecking
        // Enabled = true`) and pays nothing for it. iOS is not the same shape:
        // spell checking there is served by `UIKeyboardAutocorrectionController`,
        // which lives behind `UIKeyboardTaskQueue` — a *cross-thread condition
        // lock*. Measured on an iPad, every character typed put the main thread
        // in `-[UIKeyboardTaskQueue _lockWhenReadyForMainThread]` →
        // `NSConditionLock.lockWhenCondition(_:before:)` → `__psynch_cvwait`,
        // waiting on that queue inside `acceptAutocorrectionForWordTerminator:`.
        // The editor's own work per keystroke is ~1.3ms; this wait was ~90ms.
        //
        // Autocorrection is already `.no` for a source editor, so the only thing
        // being given up is the red underline — and it was being paid for in
        // dropped keystrokes.
        tv.spellCheckingType = .no
        tv.keyboardDismissMode = .interactive
        // Formatting goes where iOS puts editor affordances: the iPad shortcuts
        // bar (the floating pill with the language selector and the mic), or an
        // accessory on iPhone, which has no such bar. See
        // `installFormattingAssistant` — and note the deliberate absence of a
        // hand-rolled `inputAccessoryView` on iPad, which is what used to dock
        // at the bottom of the screen over the app's own status row.
        tv.installFormattingAssistant()
        // **No `inputAccessoryView`.**
        //
        // The format bar used to live here, which tied its visibility to
        // *first-responder state* rather than to anything the user can name.
        // That is not a design: switching to Edit mode did not show it (you had
        // to tap into the text as well), tapping the sidebar hid it while still
        // in Edit mode, and in Preview it was absent only because nothing
        // happened to be focused. "Sometimes there, sometimes not" was the
        // accurate description of the rule.
        //
        // The commands live in the system's own editor affordance now —
        // `installFormattingAssistant`, just below — which on iPad is the
        // floating shortcuts pill beside the language selector and the mic, and
        // on iPhone an accessory. That is where a person looks for them, it
        // costs the app no screen space, and it cannot overlap the app's own
        // status row the way a hand-rolled accessory did.

        // AI-native, exactly as the Mac (`MarkdownTextView`): the full Apple
        // Intelligence Writing Tools experience — inline, because this is a
        // real TextKit 2 view — constrained to plain text so a rewrite can
        // never come back as rich text and corrupt Markdown syntax.
        //
        // Not optional here: the coordinator already forwards the system's
        // `suggestedActions` into the selection menu, so Writing Tools has
        // been reachable on iOS the whole time — with the default result
        // options, which permit attributed replacements straight into storage
        // whose only meaning is its bytes.
        tv.writingToolsBehavior = .complete
        tv.allowedWritingToolsResultOptions = [.plainText]

        // The system find bar — ⌘F on a hardware keyboard, and "Find…" in the
        // edit menu. This was switched off for a while on the theory that
        // `UIFindInteraction` walked the storage over stale ranges of its own.
        // It did not: it walked the *empty* `UITextView.textStorage` described
        // above, which is why turning it off did not stop the crash. With the
        // view built around the document's storage it searches the note it is
        // showing.
        tv.isFindInteractionEnabled = true

        // Tap-to-navigate wiki links / URLs (an editable text view otherwise
        // just moves the caret).
        //
        // The delegate is not optional here. A `UITextView` places its caret
        // with a tap recogniser of its own, and two recognisers that both
        // recognise a single tap are mutually exclusive unless a delegate says
        // otherwise — so ours won, `handleTap` returned without doing anything
        // (there is no link under most taps), and the tap was simply eaten.
        // Scrolling still worked, which is what made it look like the editor
        // was fine and the keyboard was broken. `cancelsTouchesInView = false`
        // does not help: it governs touch *delivery* to the view, not gesture
        // *arbitration* between recognisers.
        let tap = UITapGestureRecognizer(target: tv, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = tv.linkTapDelegate
        tv.addGestureRecognizer(tap)
        tv.linkTapRecognizer = tap

        // Overlay that paints the fragment chrome over the text (scrolls with
        // the content as a subview of the scroll view).
        tv.chromeOverlay.textView = tv
        tv.chromeOverlay.isUserInteractionEnabled = false
        tv.chromeOverlay.backgroundColor = .clear
        tv.chromeOverlay.contentMode = .redraw
        tv.addSubview(tv.chromeOverlay)

        tv.installHeadingRotor()
        return tv
    }

    /// A standard VoiceOver "Headings" rotor so a long note can be navigated by
    /// heading, matching the macOS editor. Backed by the document's already-
    /// extracted headings; `.heading` is the system rotor VoiceOver users reach
    /// for. Heading ranges are mapped to `UITextRange`s so selecting a rotor
    /// item moves VoiceOver focus (and the caret) to that heading.
    private func installHeadingRotor() {
        let rotor = UIAccessibilityCustomRotor(systemType: .heading) { [weak self] predicate in
            guard let self else { return nil }
            let currentLocation: Int? = predicate.currentItem.targetRange.map {
                self.offset(from: self.beginningOfDocument, to: $0.start)
            }
            guard let heading = self.document?.rotorHeading(
                    after: currentLocation,
                    forward: predicate.searchDirection == .next
                  ),
                  let start = self.position(from: self.beginningOfDocument, offset: heading.range.location),
                  let end = self.position(from: start, offset: heading.range.length),
                  let textRange = self.textRange(from: start, to: end)
            else { return nil }
            return UIAccessibilityCustomRotorItemResult(targetElement: self, targetRange: textRange)
        }
        accessibilityCustomRotors = [rotor]
    }

    /// Redraw the chrome overlay (after edits, selection/reveal changes, layout).
    /// Only the visible slice is invalidated — the overlay spans the whole
    /// content size, so a full `setNeedsDisplay()` would repaint (and re-walk)
    /// the entire document on every keystroke.
    func refreshChrome() {
        chromeOverlay.frame = CGRect(origin: .zero, size: contentSize)
        let visible = CGRect(origin: contentOffset, size: bounds.size)
        chromeOverlay.setNeedsDisplay(visible)
    }

    /// The pasteboard is imported as plain text only: the document storage is
    /// byte-pure Markdown source, so rich text / attachments would corrupt the
    /// parser's view of it. Mirrors the macOS view's `pasteAsPlainText`.
    /// The host's chance to turn a pasted image into Markdown — it saves the
    /// file beside the note and returns the link to insert. Nil means the host
    /// does not handle images, and an image-only paste is dropped as before.
    var onPasteImage: (() -> String?)?
    /// The host's chance to convert a pasted URL or rich text into Markdown.
    /// Nil, or a nil return, falls through to the plain-string paste.
    var onPasteMarkdown: (() -> String?)?

    public override func paste(_ sender: Any?) {
        // Images first: a pasteboard carrying an image often also carries a
        // string (a filename, a URL), and inserting that instead of the picture
        // is the wrong answer.
        if UIPasteboard.general.hasImages, let markdown = onPasteImage?() {
            insertText(markdown)
            return
        }
        if let markdown = onPasteMarkdown?() {
            insertText(markdown)
            return
        }
        if let string = UIPasteboard.general.string {
            insertText(string)
        }
        // No plain-text representation and no image handler: drop it rather
        // than let UITextView insert a foreign attachment into storage.
    }

    /// Adopt `document`, whose storage the caller has *already* built this view
    /// around. Nothing here touches the storage.
    ///
    /// In particular there is no `font = document.theme.body`. On AppKit that
    /// assignment is a hazard handled by ordering it against the storage swap;
    /// here there is no swap to order it against, and it would be pure damage:
    /// `font` applies to the whole attached storage, flattening the per-run
    /// concealed 0.1pt fonts the document has already applied. It is also
    /// unnecessary — `EditorDocument.init` writes the theme's body font and
    /// colour across the entire string before any view exists.
    private func bind(to document: EditorDocument) {
        self.document = document
        // A restyle can change what a fragment *is* — a collapsed block, a
        // concealed marker, a gutter bar — so TextKit has to lay it out again
        // and the overlay has to repaint. AppKit wires exactly this and iOS
        // never did, which is why a rendered table drew at the top of the
        // document until a scroll happened to force both.
        document.onRestyle = { [weak self] range in
            self?.textLayoutManager?.invalidateLayout(charactersIn: range)
            self?.refreshChrome()
        }
        typingAttributes = [
            .font: document.theme.body,
            .foregroundColor: document.theme.text,
        ]
        textLayoutManager?.delegate = blockLayoutDelegate
        syncRenderMetrics()
    }

    /// Throw away the undo stack UIKit is keeping for this text view.
    ///
    /// Call after the document's whole text has been replaced under the view
    /// (an external reload, a conflict resolution). `EditorDocument.replaceText`
    /// ends by clearing *its own* `UndoManager`, which is where undo lives on
    /// AppKit — `MarkdownTextView`'s coordinator returns it from
    /// `undoManager(for:)`, so the clear lands on the stack the text view uses.
    /// UIKit resolves `undoManager` up the responder chain instead, so that
    /// clear reaches nothing here and the responder's stack keeps operations
    /// describing the *pre-reload* document. Replaying one applies a patch at
    /// offsets that no longer mean anything.
    ///
    /// Clearing the responder's stack rather than overriding `undoManager` to
    /// return the document's: `UIResponder` documents the override as
    /// supported, but it would re-point every ordinary keystroke's undo
    /// registration — and the keyboard bar's Undo button, and shake-to-undo —
    /// at a manager UIKit has never driven, to fix a stack that is only ever
    /// wrong right here. This discards exactly what is stale and leaves typing
    /// undo on the path UIKit already owns.
    func resetUndoStack() {
        undoManager?.removeAllActions()
    }

    func syncRenderMetrics() {
        guard let document else { return }
        let padding = textContainer.lineFragmentPadding * 2
        let width = bounds.width - padding - textContainerInset.left - textContainerInset.right
        // No cap here either — see the Mac half's note on the 900 that used to be.
        if width > 0 { document.renderMaxWidth = width }
        document.isDarkAppearance = traitCollection.userInterfaceStyle == .dark
    }

    /// Light ↔ Dark — the iOS half of the same problem the Mac has: rendered
    /// blocks are images and do not follow the trait change by themselves.
    public override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard traitCollection.userInterfaceStyle != previous?.userInterfaceStyle else { return }
        document?.appearanceDidChange(isDark: traitCollection.userInterfaceStyle == .dark)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        syncRenderMetrics()
        // The counterpart of the Mac's bounds observer, which fires on the
        // scroll view's *first* layout as well as on every scroll. iOS only had
        // the scroll half (`scrollViewDidScroll`), so nothing styled the visible
        // range until the user scrolled — which is why `makeUIView` compensated
        // by styling whole documents up to 200KB synchronously on the main
        // thread, something the Mac has never done. Same rule on both platforms
        // now: prefix at init, viewport on layout and scroll, the rest in the
        // background. Idempotent — `ensureStyled` returns nil once a range is
        // done, so repeated layout passes cost a range check.
        ensureVisibleRangeStyled()
        refreshChrome()
    }

    /// Ask the document to style what's on screen (± a margin), so fast
    /// scrolling never outruns the background styling pass.
    func ensureVisibleRangeStyled() {
        guard let document, let tlm = textLayoutManager,
              let contentManager = tlm.textContentManager,
              let viewport = tlm.textViewportLayoutController.viewportRange else { return }
        let start = contentManager.offset(from: contentManager.documentRange.location, to: viewport.location)
        let end = contentManager.offset(from: contentManager.documentRange.location, to: viewport.endLocation)
        let margin = 8_000
        let range = NSRange(location: max(0, start - margin), length: (end - start) + 2 * margin)
        guard let styled = document.ensureStyled(charactersIn: range) else { return }
        // Concealment shrinks a run's font; force TextKit 2 to re-lay-out the
        // freshly-styled span so collapsed markers don't keep their old width.
        textLayoutManager?.invalidateLayout(charactersIn: styled)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let document else { return }
        let point = gesture.location(in: self)
        // Ghost text first: a tap on it accepts it. Checked before the caret
        // because that region has no other meaning — the caret is already at
        // the end of that line, which is all a tap there could otherwise ask
        // for. See `InlineSuggestion.swift`.
        if acceptInlineSuggestion(ifTappedAt: point) { return }
        // A tap on a rendered task checkbox toggles `[ ]` ↔ `[x]`.
        if toggleTaskCheckbox(at: point) { return }
        // A tap on a foldable callout header's chevron folds it.
        if toggleCalloutFold(at: point) { return }
        // Resolve the tapped character offset.
        guard let position = closestPosition(to: point) else { return }
        let index = offset(from: beginningOfDocument, to: position)
        let storage = document.storage
        guard index >= 0, index < storage.length else { return }
        if let target = storage.attribute(wikiTargetAttribute, at: index, effectiveRange: nil) as? String {
            onLinkTap?(.wiki(target: target))
        } else if let link = storage.attribute(.link, at: index, effectiveRange: nil) {
            if let url = link as? URL { onLinkTap?(.url(url)) }
            else if let s = link as? String, let url = URL(string: s) { onLinkTap?(.url(url)) }
        }
    }

    /// If the tap landed on a concealed task box, toggle it (undoably) and
    /// report the tap as spent. The box is three characters (`[ ]`); a tap
    /// anywhere in that range, or just past it, counts.
    ///
    /// Unlike the Mac, the caret is *not* restored afterwards. AppKit lets us
    /// intercept before the click moves it; here the text view's own recogniser
    /// runs alongside ours, so there is no "before" to restore to. The line
    /// therefore reveals its `- [x]` source — which is what tapping any line in
    /// this editor does, so the checkbox behaves like everything around it.
    func toggleTaskCheckbox(at point: CGPoint) -> Bool {
        guard isEditable, let document else { return false }
        let storage = document.storage
        guard let position = closestPosition(to: point) else { return false }
        let index = offset(from: beginningOfDocument, to: position)
        for probe in stride(from: min(index, storage.length - 1), through: max(0, index - 3), by: -1) {
            guard probe >= 0, probe < storage.length else { continue }
            var effective = NSRange(location: 0, length: 0)
            guard let checked = storage.attribute(taskCheckboxAttribute, at: probe,
                                                  effectiveRange: &effective) as? Bool else { continue }
            // The state character is the middle of `[ ]` / `[x]`.
            let stateIndex = effective.location + 1
            guard stateIndex < storage.length else { return false }
            return performEdit(replacing: NSRange(location: stateIndex, length: 1),
                               with: checked ? " " : "x")
        }
        return false
    }

    /// If the tap landed on a foldable callout header's right-aligned
    /// disclosure chevron, toggle the fold and report the tap as spent.
    func toggleCalloutFold(at point: CGPoint) -> Bool {
        guard let document else { return false }
        // The chevron sits at the right edge of the text container.
        let containerRight = textContainerInset.left + textContainer.size.width
        // A wider zone than the Mac's: this is a fingertip, not a pointer.
        guard point.x >= containerRight - RenderedBlockFragment.calloutChevronInset - 22 else { return false }

        guard let position = closestPosition(to: point) else { return false }
        let index = offset(from: beginningOfDocument, to: position)
        let ns = document.storage.mutableString
        guard ns.length > 0, index >= 0, index <= ns.length else { return false }
        let line = ns.lineRange(for: NSRange(location: min(index, ns.length - 1), length: 0))
        guard document.isFoldableCalloutHeader(atCharacter: line.location) else { return false }
        guard let blockRange = document.toggleCalloutFold(atHeaderOffset: line.location) else { return false }
        textLayoutManager?.invalidateLayout(charactersIn: blockRange)
        refreshChrome()
        return true
    }

    /// ⌥⇥ accepts the ghost and Esc dismisses it, exactly as on the Mac —
    /// but only while one is showing. Offered unconditionally, Esc would be
    /// swallowed from a text view that has no suggestion to dismiss.
    public override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        if inlineSuggestion != nil {
            commands += [
                UIKeyCommand(input: "\t", modifierFlags: .alternate,
                             action: #selector(acceptInlineSuggestionCommand(_:))),
                UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [],
                             action: #selector(dismissInlineSuggestionCommand(_:))),
            ]
        }
        // Arrowing off the top of the note lands in the title above it — the
        // Mac has done this since the inline title shipped, by overriding
        // `moveUp` / `moveLeft`. UIKit gives a `UITextView` no such overrides,
        // so it is a key command instead — offered **only** while the caret is
        // somewhere the escape applies, because a permanently-installed ↑ would
        // swallow ordinary caret movement for the whole document.
        if onCaretEscapeTop != nil {
            if caretIsOnFirstLine {
                commands.append(UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [],
                                             action: #selector(escapeTopVertical(_:))))
            }
            if caretIsAtStart {
                commands.append(UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [],
                                             action: #selector(escapeTopBackward(_:))))
            }
        }
        return commands
    }

    // MARK: - Caret escape (↑ / ← off the top of the note)

    /// The caret left the top of the text; the host decides what is above it.
    var onCaretEscapeTop: ((CaretEscape) -> Void)?

    /// Where the note's *text* begins — after any front matter.
    ///
    /// The same answer AppKit's `MarkdownTextView.firstBodyLineStart` gives, and
    /// for the same reason: front matter is concealed until the caret enters it,
    /// so landing on literal offset 0 of a note that has some pops the whole
    /// `---` block open — the note's metadata unfolding between the title and
    /// the prose. This half used literal `0` in all three places, so ↓ from the
    /// inline title, ← from the first body line and `focusFirstLine` each landed
    /// *inside* the front matter on iPad while the Mac skipped past it.
    var firstBodyLineStart: Int {
        guard let document,
              let front = document.parse.blocks.first(where: { $0.kind == .frontMatter })
        else { return 0 }
        return min(NSMaxRange(front.range), (text as NSString).length)
    }

    private var caretIsAtStart: Bool {
        selectedRange.length == 0 && selectedRange.location <= firstBodyLineStart
    }

    private var caretIsOnFirstLine: Bool {
        guard selectedRange.length == 0 else { return false }
        if selectedRange.location <= firstBodyLineStart { return true }
        // Compare caret rects, not fragment frames. The obvious version asks
        // `textLayoutFragment(for:)` for the caret's fragment and tests whether
        // its frame sits at the top — and a fragment TextKit has not laid out
        // yet reports `.zero`, so *every* offset past the viewport read as the
        // first line and ↑ stopped working through the whole document. Caught
        // by `theCaretEscapesTheTopOnlyFromTheTop`.
        //
        // `caretRect(for:)` lays out what it needs, and equal tops is what
        // "same line" means on screen — which is also the right answer for a
        // wrapped first paragraph, where the second visual line is not the
        // first line even though it shares a fragment.
        guard let caretPosition = position(from: beginningOfDocument, offset: selectedRange.location),
              let bodyStart = position(from: beginningOfDocument, offset: firstBodyLineStart)
        else { return false }
        let here = caretRect(for: caretPosition)
        // Measured against the first *body* line, not the document's, so a note
        // with front matter compares against the line the user can actually see.
        let start = caretRect(for: bodyStart)
        guard here.minY.isFinite, start.minY.isFinite else { return false }
        return abs(here.minY - start.minY) < 0.5
    }

    /// Where the caret sits horizontally, in points from the text's left edge —
    /// so the column survives the different inset and font above the seam.
    private var caretXOffset: CGFloat {
        guard let position = position(from: beginningOfDocument, offset: selectedRange.location)
        else { return 0 }
        // `max(0, …)` as on the Mac: this is posted as the caret's column for
        // the inline title to honour, and a negative column is not a column.
        return max(0, caretRect(for: position).minX
                      - textContainerInset.left - textContainer.lineFragmentPadding)
    }

    @objc private func escapeTopVertical(_ sender: Any?) {
        onCaretEscapeTop?(.vertical(x: caretXOffset))
    }

    @objc private func escapeTopBackward(_ sender: Any?) {
        onCaretEscapeTop?(.backward)
    }

    // MARK: - Inline context (autocomplete)

    /// The host's autocomplete hook: what the caret is inside — a `[[link` or
    /// a `#tag` — and where to draw the list, or nil for plain text.
    var onInlineContextChange: ((EditorDocument.InlineContext?, CGRect) -> Void)?

    /// Report the caret's inline context, with the caret rect in **viewport**
    /// coordinates.
    ///
    /// Viewport, not content: a `UITextView` scrolls its own content, so a rect
    /// in content space is correct exactly once — the popup would then drift up
    /// the screen as the note scrolls, because the SwiftUI overlay it positions
    /// sits over the viewport, not over the document.
    func reportInlineContext() {
        guard let onInlineContextChange, let document else { return }
        let selection = selectedRange
        guard selection.length == 0,
              let context = document.inlineContext(at: selection.location) else {
            onInlineContextChange(nil, .zero)
            return
        }
        onInlineContextChange(context, caretRectInViewport(at: selection.location))
    }

    private func caretRectInViewport(at location: Int) -> CGRect {
        guard let position = position(from: beginningOfDocument, offset: location) else { return .zero }
        return caretRect(for: position).offsetBy(dx: -contentOffset.x, dy: -contentOffset.y)
    }

    /// Scroll a character range into view the TextKit 2-safe way: lay the target
    /// out first, then scroll to its real frame. `scrollRangeToVisible` alone
    /// lands short on a long note, because every fragment between here and there
    /// is still carrying an estimated height.
    public func reliablyScroll(to range: NSRange) {
        guard let tlm = textLayoutManager,
              let content = tlm.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else {
            scrollRangeToVisible(range)
            return
        }
        tlm.ensureLayout(for: textRange)
        var frame: CGRect?
        tlm.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, rect, _, _ in
            frame = frame?.union(rect) ?? rect
            return true
        }
        guard let frame else {
            scrollRangeToVisible(range)
            return
        }
        // Unanimated, like the Mac's `scrollToVisible`: the scroll is the
        // answer to a tap somewhere else in the window, so it should already be
        // there when you look back — and an animated one leaves `contentOffset`
        // unchanged until the animation runs, which is unobservable to a caller.
        scrollRectToVisible(frame.insetBy(dx: 0, dy: -40)
            .offsetBy(dx: textContainerInset.left, dy: textContainerInset.top), animated: false)
    }
}

/// The host's handle on a live editor: programmatic edits that take the same
/// path typing does, and navigation.
///
/// The UIKit half of the macOS `EditorProxy`, carrying only the two calls this
/// platform actually makes — accepting a `[[link]]` completion, and scrolling to
/// a heading picked in the outline. Same name and same shape as the AppKit one
/// so a host reads identically on both.
public final class EditorProxy {
    weak var textView: MarkdownUITextView?

    public init() {}

    @discardableResult
    public func replace(range: NSRange, with text: String) -> Bool {
        textView?.performEdit(replacing: range, with: text) ?? false
    }

    public func scroll(to range: NSRange) {
        textView?.reliablyScroll(to: range)
    }

    /// Offer ghost text at `location`, or clear it with `nil`.
    ///
    /// Pushed through the proxy rather than a SwiftUI binding on purpose: this
    /// changes on a debounce timer while someone is typing, and routing it
    /// through `updateUIView` would re-run the representable's update for a
    /// value that reaches exactly one stored property on one view.
    ///
    /// The view refuses anything that no longer describes the current caret, so
    /// a reply that arrives late is dropped rather than shown in the wrong place.
    public func showInlineSuggestion(_ text: String?, at location: Int) {
        guard let tv = textView else { return }
        guard let text, !text.isEmpty else {
            tv.clearInlineSuggestion()
            return
        }
        tv.showInlineSuggestion(InlineSuggestion(location: location, text: text))
    }

    public func clearInlineSuggestion() { textView?.clearInlineSuggestion() }

    /// Insert the showing suggestion. False when there is none, or when the
    /// document moved under it.
    @discardableResult
    public func acceptInlineSuggestion() -> Bool {
        textView?.acceptInlineSuggestion() ?? false
    }

    /// Whether ghost text is on screen right now — for a host that wants to
    /// show a hint, and for tests.
    public var hasInlineSuggestion: Bool { textView?.inlineSuggestion != nil }

    /// Make the editor first responder with the caret on the **first line**, at
    /// the horizontal offset `x` (points from the text's left edge).
    ///
    /// The other half of the caret handover: `onCaretEscapeTop` lifts the caret
    /// into the inline title, and this brings it back down. iOS had neither
    /// until this session, so on an iPad keyboard the title and the body were
    /// two islands.
    ///
    /// The column is honoured the same way AppKit's is — by asking the layout
    /// which offset on the first line sits nearest `x` — so arrowing down keeps
    /// your place in the column rather than jumping to the start of the line.
    public func focusFirstLine(atX x: CGFloat) {
        guard let tv = textView else { return }
        tv.becomeFirstResponder()
        let inset = tv.textContainerInset.left + tv.textContainer.lineFragmentPadding
        // The first *body* line: arrowing down from the title means "the first
        // line I would write on". Targeting the document's line 0 landed the
        // caret inside concealed front matter and unfolded it, which is the
        // note's metadata appearing between the title and the prose.
        let bodyStart = tv.firstBodyLineStart
        let anchor = tv.position(from: tv.beginningOfDocument, offset: bodyStart)
            ?? tv.beginningOfDocument
        let firstLineY = tv.caretRect(for: anchor).midY
        let point = CGPoint(x: inset + max(0, x), y: firstLineY)
        let location = tv.closestPosition(to: point).map {
            tv.offset(from: tv.beginningOfDocument, to: $0)
        } ?? bodyStart
        let range = NSRange(location: max(location, bodyStart), length: 0)
        tv.selectedRange = range
        tv.document?.selectionDidChange(range)
        tv.scrollRangeToVisible(range)
    }

    /// The caret arrived from above with no column to honour.
    public func focusStart() { focusFirstLine(atX: 0) }

    /// Apply a formatting command — bold, a list, a heading level.
    ///
    /// `EditorProxy` is declared once per platform, in two files that cannot
    /// see each other, so this and `performAITransform` existed on one of them
    /// and nothing failed to compile. A host holding a proxy could format on
    /// one platform and not the other.
    public func apply(_ command: EditorFormatCommand) {
        textView?.apply(command)
    }

    /// Wrap an AI-driven mutation so the document pauses its styling while the
    /// transform streams in, then restyles once at the end.
    ///
    /// Without it a streaming rewrite restyles per chunk — the whole-document
    /// highlight running once per token — which is the difference between a
    /// rewrite that streams and one that stutters.
    public func performAITransform(_ body: (EditorProxy) -> Void) {
        textView?.document?.beginExternalTextSession()
        body(self)
        textView?.document?.endExternalTextSession()
    }

    /// Discard the undo stack after the document's text has been replaced
    /// wholesale (`EditorDocument.replaceText`). See `resetUndoStack` for why
    /// the document clearing its own `UndoManager` is not enough on UIKit.
    public func resetUndo() { textView?.resetUndoStack() }

    /// Move the caret, clamped to the document. Deliberately does not scroll:
    /// the callers that want both say so.
    public func setSelection(_ range: NSRange) {
        guard let tv = textView else { return }
        let length = (tv.text as NSString?)?.length ?? 0
        let location = min(max(0, range.location), length)
        let clamped = NSRange(location: location,
                              length: min(max(0, range.length), length - location))
        tv.selectedRange = clamped
        tv.document?.selectionDidChange(clamped)
    }

    /// Where the caret is. Lets a deferred rewrite (an image's alt text, a
    /// pasted link's title) name *which* occurrence it meant.
    public func selection() -> NSRange {
        textView?.selectedRange ?? NSRange(location: NSNotFound, length: 0)
    }
}



/// Lets the link tap coexist with the caret tap.
///
/// Two recognisers that both recognise a single tap are mutually exclusive
/// unless a delegate says otherwise, and UIKit asks *both* delegates — so this
/// one saying yes is enough. Without it the link tap won, `handleTap` returned
/// having found no link under the finger, and the tap was eaten: a note you
/// could scroll and could not type into.
private final class LinkTapDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

/// Transparent subview that paints the fragment chrome over the text. It sits
/// in the scroll view's content, so it scrolls with the text; it enumerates the
/// laid-out `RenderedBlockFragment`s and calls their chrome-only draw.
final class ChromeOverlayView: UIView {
    weak var textView: MarkdownUITextView?

    override func draw(_ rect: CGRect) {
        guard let tv = textView, let tlm = tv.textLayoutManager,
              let context = UIGraphicsGetCurrentContext() else { return }
        let inset = tv.textContainerInset
        // No `.ensuresLayout` — layout is already done when we draw; forcing it
        // here re-enters layout during drawing and crashes.
        // Only draw fragments intersecting the dirty rect, and stop once we're
        // past it (fragments enumerate top-to-bottom). This trims drawing to the
        // visible slice; the enumeration itself still skips over fragments above
        // the rect, so the walk is O(offset-to-viewport + visible), not O(document).
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) { fragment in
            // A fragment TextKit has not laid out yet reports
            // `layoutFragmentFrame` of `.zero`, and `options: []` deliberately
            // does not force layout (forcing it here re-enters layout during
            // drawing and crashes — see above). Drawing at a zero frame paints
            // the fragment at the top of the view: invisible for a gutter bar,
            // glaring for a rendered table, which is exactly how a table came
            // out stamped over the first lines of the note until a scroll laid
            // the fragment out for real.
            guard fragment.state == .layoutAvailable else { return true }
            let frame = fragment.layoutFragmentFrame
            let top = inset.top + frame.origin.y
            if top > rect.maxY { return false }   // below the dirty rect; done
            if let chrome = fragment as? RenderedBlockFragment,
               top + frame.height >= rect.minY {   // intersects vertically
                chrome.drawChromeOnly(at: CGPoint(x: inset.left + frame.origin.x, y: top), in: context)
            }
            return true
        }
        if let x = tv.wrapGuideX {
            // Hairline at the current screen scale, so it stays one pixel.
            let width = 1 / (tv.window?.screen.scale ?? UIScreen.main.scale)
            UIColor.separator.withAlphaComponent(0.55).setFill()
            // Full height of the dirty rect: the overlay spans `contentSize`,
            // so this is the whole document's worth of guide, drawn a slice at
            // a time exactly like the fragments above it.
            context.fill(CGRect(x: x, y: rect.minY, width: width, height: rect.height))
        }
        // Last, so the ghost sits over the chrome rather than under a callout
        // band — it is the topmost thing in the editor while it is showing.
        tv.drawInlineSuggestion(in: rect)
    }
}


/// SwiftUI host for the iOS Markdown editor. Same public surface (`init`,
/// `editable`, `onLinkTap`) as the macOS `MarkdownEditorView`.
///
/// A `View` wrapping the representable rather than the representable itself,
/// so it can give the text view an **identity tied to the document**.
///
/// SwiftUI reuses a `UIViewRepresentable`'s view across updates, and a
/// `UITextView` built around one document's storage cannot be handed another:
/// re-binding means swapping the storage on a live view, which is the crash
/// this file exists to document. AppKit re-binds in `updateNSView`; here the
/// answer is to build a new view instead, and `.id` is what makes SwiftUI do
/// that. Without it, selecting a second note changed the title and left the
/// first note's text on screen — and, because the stale document's `onEdit`
/// still fed the model, typing into it would have saved the old note's
/// contents over the new file.
public struct MarkdownEditorView: View {
    private var representable: MarkdownEditorRepresentable

    public init(document: EditorDocument) {
        representable = MarkdownEditorRepresentable(document: document)
    }

    public var body: some View {
        representable.id(ObjectIdentifier(representable.document))
    }

    /// Listen for formatting and find commands addressed to `documentId`.
    ///
    /// Removed earlier in the day as dead weight — correctly, at the time:
    /// nothing on iOS posted on it, because the keyboard toolbar that was meant
    /// to never rendered. The iPad menu bar is the poster it was waiting for.
    public func commandBus(documentId: String) -> Self {
        var copy = self; copy.representable = representable.commandBus(documentId: documentId); return copy
    }

    public func editable(_ flag: Bool) -> Self {
        var copy = self; copy.representable = representable.editable(flag); return copy
    }

    /// Called when the caret leaves through the top of the document — ↑ from the
    /// first line, or ← from character zero. The host puts the caret wherever
    /// its own chrome above the text begins.
    public func onCaretEscapeTop(_ handler: @escaping (CaretEscape) -> Void) -> Self {
        var copy = self; copy.representable = representable.onCaretEscapeTop(handler); return copy
    }

    /// Offer "Rewrite with AI…" in the edit menu for a selection. The handler
    /// receives the range; presenting the sheet is the host's job.
    public func onRewriteSelection(_ handler: @escaping (NSRange) -> Void) -> Self {
        var copy = self; copy.representable = representable.onRewriteSelection(handler); return copy
    }

    /// Show a vertical guide at `columns` characters, or 0 for none. A line to
    /// see, not a wrap point — the text still runs to the edge of the pane.
    public func wrapGuide(_ columns: Int) -> Self {
        var copy = self; copy.representable = representable.wrapGuide(columns); return copy
    }

    public func onLinkTap(_ handler: @escaping (EditorLinkTap) -> Void) -> Self {
        var copy = self; copy.representable = representable.onLinkTap(handler); return copy
    }

    /// Save a pasted image and return the Markdown link to insert.
    public func onPasteImage(_ handler: @escaping () -> String?) -> Self {
        var copy = self; copy.representable = representable.onPasteImage(handler); return copy
    }

    /// Convert a pasted URL or rich text to Markdown.
    public func onPasteMarkdown(_ handler: @escaping () -> String?) -> Self {
        var copy = self; copy.representable = representable.onPasteMarkdown(handler); return copy
    }

    public func selectionMenuItems(_ build: @escaping (String) -> [EditorMenuItem]) -> Self {
        var copy = self; copy.representable = representable.selectionMenuItems(build); return copy
    }

    /// Hand the host a handle on the live text view (programmatic edits, scroll).
    public func proxy(_ proxy: EditorProxy) -> Self {
        var copy = self; copy.representable = representable.proxy(proxy); return copy
    }

    /// Called whenever the caret settles: the `[[link` / `#tag` it is inside
    /// (nil in plain text) and the caret rect in the editor's own coordinates.
    public func onInlineContext(_ handler: @escaping (EditorDocument.InlineContext?, CGRect) -> Void) -> Self {
        var copy = self; copy.representable = representable.onInlineContext(handler); return copy
    }

    /// Called when the caret settles somewhere ghost text could honestly be
    /// drawn. The debounce, the provider check and the cancellation are all the
    /// host's — see `InlineCompletionModel`.
    public func onInlineCompletionRequest(_ handler: @escaping (InlineCompletionContext) -> Void) -> Self {
        var copy = self; copy.representable = representable.onInlineCompletionRequest(handler); return copy
    }
}

struct MarkdownEditorRepresentable: UIViewRepresentable {
    /// Document id for the command bus, if the host wants one.
    private var busDocumentId: String?
    let document: EditorDocument
    private var isEditable = true
    private var wrapGuideColumns = 0
    private var onCaretEscapeTopHandler: ((CaretEscape) -> Void)?
    private var onRewriteSelectionHandler: ((NSRange) -> Void)?
    private var onLinkTap: ((EditorLinkTap) -> Void)?
    private var onPasteImage: (() -> String?)?
    private var onPasteMarkdown: (() -> String?)?
    private var selectionMenuItems: ((String) -> [EditorMenuItem])?
    private var editorProxy: EditorProxy?
    private var onInlineContext: ((EditorDocument.InlineContext?, CGRect) -> Void)?
    private var onInlineCompletionRequest: ((InlineCompletionContext) -> Void)?

    init(document: EditorDocument) { self.document = document }

    /// Take exactly the space offered — never the note's own height (S1).
    /// Returning nil here falls back to the text view's content size, which
    /// propagates up as an ideal and inflates every ancestor. See
    /// `viewportSizeThatFits` and docs/layout-architecture.md.
    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: MarkdownUITextView,
                      context: Context) -> CGSize? {
        viewportSizeThatFits(proposal)
    }

    func commandBus(documentId: String) -> Self {
        var copy = self; copy.busDocumentId = documentId; return copy
    }

    func editable(_ flag: Bool) -> Self {
        var copy = self; copy.isEditable = flag; return copy
    }

    func onLinkTap(_ handler: @escaping (EditorLinkTap) -> Void) -> Self {
        var copy = self; copy.onLinkTap = handler; return copy
    }

    func onPasteImage(_ handler: @escaping () -> String?) -> Self {
        var copy = self; copy.onPasteImage = handler; return copy
    }

    func onPasteMarkdown(_ handler: @escaping () -> String?) -> Self {
        var copy = self; copy.onPasteMarkdown = handler; return copy
    }

    /// Host actions added to the selection's edit menu. Called with the selected
    /// text each time the menu is built, so the host can decide per selection
    /// which items make sense — an item that cannot apply is better absent than
    /// present and inert.
    func selectionMenuItems(_ build: @escaping (String) -> [EditorMenuItem]) -> Self {
        var copy = self; copy.selectionMenuItems = build; return copy
    }

    func proxy(_ proxy: EditorProxy) -> Self {
        var copy = self; copy.editorProxy = proxy; return copy
    }

    func onInlineContext(_ handler: @escaping (EditorDocument.InlineContext?, CGRect) -> Void) -> Self {
        var copy = self; copy.onInlineContext = handler; return copy
    }

    func onInlineCompletionRequest(_ handler: @escaping (InlineCompletionContext) -> Void) -> Self {
        var copy = self; copy.onInlineCompletionRequest = handler; return copy
    }

    func makeUIView(context: Context) -> MarkdownUITextView {
        // A rebuild here is never routine: it makes a **new** `UITextView`, so
        // the old one loses first responder and its `inputAccessoryView` — the
        // format bar — goes away and comes back. If that happens while typing,
        // the bar flickers and the layout shifts under the caret.
        EditorProbe.logEdit("makeUIView — NEW text view (first responder and accessory reset)")
        let tv = MarkdownUITextView.make(document: document)
        tv.isEditable = isEditable
        tv.wrapGuideColumns = wrapGuideColumns
        tv.onCaretEscapeTop = onCaretEscapeTopHandler
        tv.onRewriteSelection = onRewriteSelectionHandler
        tv.onLinkTap = onLinkTap
        tv.onPasteImage = onPasteImage
        tv.onPasteMarkdown = onPasteMarkdown
        tv.onInlineContextChange = onInlineContext
        tv.onInlineCompletionRequest = onInlineCompletionRequest
        editorProxy?.textView = tv
        tv.delegate = context.coordinator
        context.coordinator.subscribe(documentId: busDocumentId, view: tv)
        // No whole-document styling pass here. It used to run for anything up
        // to 200KB — a synchronous restyle of every block, on the main thread,
        // at the moment a note opens — because `layoutSubviews` had no
        // `ensureVisibleRangeStyled` call and the viewport would otherwise
        // stay unstyled until the first scroll. It has one now, so opening a
        // note costs what it costs on the Mac: the prefix, the viewport, and a
        // background pass for the rest.
        return tv
    }

    /// Called when the caret leaves through the top of the document.
    func onCaretEscapeTop(_ handler: @escaping (CaretEscape) -> Void) -> Self {
        var copy = self; copy.onCaretEscapeTopHandler = handler; return copy
    }

    /// Offer "Rewrite with AI…" on a selection, reporting its range.
    func onRewriteSelection(_ handler: @escaping (NSRange) -> Void) -> Self {
        var copy = self; copy.onRewriteSelectionHandler = handler; return copy
    }

    /// Show a vertical guide at `columns` characters, or 0 for none.
    func wrapGuide(_ columns: Int) -> Self {
        var copy = self; copy.wrapGuideColumns = columns; return copy
    }

    func updateUIView(_ tv: MarkdownUITextView, context: Context) {
        // The wrapper's `.id` guarantees this; assert it rather than trust it,
        // because the failure is silent and destructive — a stale document
        // whose `onEdit` still feeds the model writes the wrong note to disk.
        assert(tv.document === document,
               "the text view is showing a different document than it was handed")
        tv.isEditable = isEditable
        // These three were set in `makeUIView` only, while `updateNSView`
        // re-applies all ten. The view's identity is the *document*, so nothing
        // rebuilds it when a setting changes: the wrap guide could not be turned
        // on or off from Settings on iPad until the note was evicted from the
        // document cache, and the two closures kept whatever they captured on
        // first render.
        tv.wrapGuideColumns = wrapGuideColumns
        tv.onCaretEscapeTop = onCaretEscapeTopHandler
        tv.onRewriteSelection = onRewriteSelectionHandler
        tv.onLinkTap = onLinkTap
        tv.onPasteImage = onPasteImage
        tv.onPasteMarkdown = onPasteMarkdown
        tv.onInlineContextChange = onInlineContext
        tv.onInlineCompletionRequest = onInlineCompletionRequest
        editorProxy?.textView = tv
        context.coordinator.selectionMenuItems = selectionMenuItems
        context.coordinator.subscribe(documentId: busDocumentId, view: tv)
    }

    func makeCoordinator() -> Coordinator { Coordinator(document: document) }

    public final class Coordinator: NSObject, UITextViewDelegate {
        let document: EditorDocument
        var selectionMenuItems: ((String) -> [EditorMenuItem])?
        init(document: EditorDocument) { self.document = document }

        /// Command-bus observers, and the id they are bound to. On the
        /// coordinator, never on the view: `MarkdownUITextView` is built
        /// through an initialiser that does not run subclass stored-property
        /// synthesis, so an array property there is never initialised and
        /// appending to it crashes on the first note opened.
        ///
        /// `nonisolated(unsafe)`, as on AppKit's coordinator: registration and
        /// removal happen on the main thread, and `deinit` — which cannot be
        /// isolated — only reads the array to remove what it registered.
        nonisolated(unsafe) private var busTokens: [NSObjectProtocol] = []
        private var busDocumentId: String?
        private weak var busView: MarkdownUITextView?
        /// The find bar's query and position, so Next/Previous and Replace act
        /// on the same match the bar is showing.
        private var findQuery = ""
        private var findIndex = 0

        /// Block observers are retained by `NotificationCenter` until they are
        /// removed by token, so a coordinator that just goes away leaves its
        /// ten registrations behind for the life of the process — still firing,
        /// still holding their captures. The removal branch in `subscribe` does
        /// not cover this: `MarkdownEditorView.body` gives the representable an
        /// `.id` per document, so a coordinator is bound 1:1 to an
        /// `EditorDocument` and is never asked to re-subscribe under a second
        /// id. It is asked to disappear, which is what this answers. AppKit's
        /// coordinator has had the same `deinit` since it was written.
        deinit {
            for token in busTokens { NotificationCenter.default.removeObserver(token) }
        }

        /// Observe formatting and find commands addressed to `documentId`.
        func subscribe(documentId: String?, view: MarkdownUITextView) {
            busView = view
            guard busDocumentId != documentId else { return }
            for token in busTokens { NotificationCenter.default.removeObserver(token) }
            busTokens.removeAll()
            busDocumentId = documentId
            guard let documentId, !documentId.isEmpty else { return }

            let center = NotificationCenter.default
            let formats: [(String, EditorFormatCommand)] = [
                ("bold", .bold), ("italic", .italic), ("strikethrough", .strikethrough),
                ("highlight", .highlight), ("inlineCode", .inlineCode),
                ("blockquote", .blockquote), ("unorderedList", .unorderedList),
                ("orderedList", .orderedList),
            ]
            for (kind, command) in formats {
                busTokens.append(center.addObserver(
                    forName: Notification.Name("hnEditorFormat.\(kind).\(documentId)"),
                    object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.busView?.apply(command) }
                })
            }
            busTokens.append(center.addObserver(
                forName: Notification.Name("hnEditorFormat.heading.\(documentId)"),
                object: nil, queue: .main
            ) { [weak self] note in
                let level = note.userInfo?["level"] as? Int ?? 1
                MainActor.assumeIsolated { [level] in self?.busView?.apply(.heading(level)) }
            })
            // Undo, redo and "put the keyboard away" — the three things the
            // format bar offers that are not formatting.
            //
            // They travel the same bus as everything else because the bar that
            // sends them is now the *app's* chrome rather than this view's
            // `inputAccessoryView`, and app chrome has no reference to a text
            // view. Undo in particular could not simply be left to the
            // responder chain: UIKit resolves `undoManager` up that chain, so a
            // button living outside the editor would find the window's stack,
            // not the document's.
            busTokens.append(center.addObserver(
                forName: Notification.Name("hnEditorUndo.\(documentId)"),
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.busView?.undoManager?.undo() }
            })
            busTokens.append(center.addObserver(
                forName: Notification.Name("hnEditorRedo.\(documentId)"),
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.busView?.undoManager?.redo() }
            })
            busTokens.append(center.addObserver(
                forName: Notification.Name("hnEditorEndEditing.\(documentId)"),
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.busView?.resignFirstResponder() }
            })
            // ⌘F. The system find bar is the text view's own, so the only thing
            // a menu item needs is a way to reach the view that owns it.
            busTokens.append(center.addObserver(
                forName: Notification.Name("hnEditorFind.\(documentId)"),
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let view = self?.busView else { return }
                    view.becomeFirstResponder()
                    // `showingReplace: true` — the system find bar does
                    // replace as well, on any editable text view, so the Mac's
                    // Find & Replace needs no iOS counterpart written. It was
                    // passing `false` and offering half the feature.
                    view.findInteraction?.presentFindNavigator(showingReplace: true)
                }
            })
            // The app's own find bar, and every jump to a heading. These four
            // are the AppKit view's, and they had no listener here — see
            // `showMatch(of:index:)`.
            busTokens.append(center.addObserver(
                forName: Notification.Name("hn.editor.findQuery"),
                object: nil, queue: .main
            ) { [weak self] note in
                let query = note.userInfo?["query"] as? String ?? ""
                let index = note.userInfo?["currentIndex"] as? Int
                MainActor.assumeIsolated { [query, index] in
                    guard let self, let textView = self.busView, textView.window != nil else { return }
                    if query != self.findQuery { self.findIndex = 0 }
                    self.findQuery = query
                    if let index { self.findIndex = index }
                    let count = textView.showMatch(of: query, index: self.findIndex)
                    NotificationCenter.default.post(
                        name: Notification.Name("hn.editor.findResults"),
                        object: nil, userInfo: ["count": count])
                }
            })
            busTokens.append(center.addObserver(
                forName: Notification.Name("hn.editor.replaceCurrent"),
                object: nil, queue: .main
            ) { [weak self] note in
                let replacement = note.userInfo?["replacement"] as? String
                MainActor.assumeIsolated { [replacement] in
                    guard let self, let textView = self.busView, textView.window != nil,
                          let replacement else { return }
                    let sel = textView.selectedRange
                    if sel.length > 0 { textView.performEdit(replacing: sel, with: replacement) }
                    _ = textView.showMatch(of: self.findQuery, index: self.findIndex)
                }
            })
            busTokens.append(center.addObserver(
                forName: Notification.Name("hn.editor.replaceAll"),
                object: nil, queue: .main
            ) { [weak self] note in
                let replacement = note.userInfo?["replacement"] as? String
                MainActor.assumeIsolated { [replacement] in
                    guard let self, let textView = self.busView, textView.window != nil,
                          let replacement, !self.findQuery.isEmpty,
                          let document = textView.document else { return }
                    // Back to front, so earlier ranges stay valid.
                    for range in document.findMatches(of: self.findQuery).reversed() {
                        textView.performEdit(replacing: range, with: replacement)
                    }
                }
            })
            busTokens.append(center.addObserver(
                forName: Notification.Name("hn.editor.clearHighlights"),
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let textView = self.busView, textView.window != nil else { return }
                    self.findQuery = ""
                    self.findIndex = 0
                    textView.selectedRange = NSRange(location: textView.selectedRange.location, length: 0)
                }
            })
        }

        public func textView(_ textView: UITextView,
                             editMenuForTextIn range: NSRange,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0 else { return nil }
            let selected = (textView.text as NSString).substring(with: range)
            let items = selectionMenuItems?(selected) ?? []

            // Rewrite is offered on its own terms, ahead of the vault actions,
            // and only when the host wired it *and* the text is editable —
            // exactly the three conditions `MarkdownTextView.menu(for:)` checks.
            var rewrite: [UIMenuElement] = []
            if let view = textView as? MarkdownUITextView,
               let onRewrite = view.onRewriteSelection, view.isEditable {
                rewrite.append(UIAction(title: String(localized: "Rewrite with AI…"),
                                        image: UIImage(systemName: "sparkles")) { _ in
                    onRewrite(range)
                })
            }
            guard !items.isEmpty || !rewrite.isEmpty else { return nil }

            let actions: [UIMenuElement] = rewrite + items.map { item in
                UIAction(title: item.title,
                         image: item.systemImage.flatMap(UIImage.init(systemName:))) { _ in
                    guard let replacement = item.perform(selected) else { return }
                    // Through `UITextInput`, not the storage: that is the path
                    // typing takes, so the edit lands in the undo stack and the
                    // document's change notifications fire as usual.
                    guard let textRange = textView.selectedTextRange else { return }
                    textView.replace(textRange, withText: replacement)
                }
            }
            // Ours first, then everything the system offered — Writing Tools
            // included. Ours are the vault-aware ones and cannot be reached any
            // other way; the system's are one submenu away wherever they sit.
            return UIMenu(children: actions + suggestedActions)
        }

        // MARK: Writing Tools session lifecycle

        /// Pause our restyling for the duration of a Writing Tools session, so
        /// our attributes never fight the session's own decorations (the
        /// proofreading underlines, the rewrite animation) as it streams text
        /// in; the document collects the damage and restyles once at the end.
        ///
        /// The Mac has bracketed sessions since Writing Tools landed. iOS never
        /// called either half, so `externalSessionDepth` sat at 0 and every
        /// edit the session made was restyled underneath it.
        public func textViewWritingToolsWillBegin(_ textView: UITextView) {
            document.beginExternalTextSession()
        }

        public func textViewWritingToolsDidEnd(_ textView: UITextView) {
            document.endExternalTextSession()
        }

        public func textViewDidChangeSelection(_ textView: UITextView) {
            document.selectionDidChange(textView.selectedRange)
            // Reveal flips which markers conceal / which chrome shows.
            (textView as? MarkdownUITextView)?.refreshChrome()
            (textView as? MarkdownUITextView)?.reportInlineContext()
            // Moving the caret is not typing, so this clears without asking for
            // a new one — a suggestion that followed the caret around would be
            // answering a question nobody asked.
            (textView as? MarkdownUITextView)?.clearInlineSuggestion()
        }

        public func textViewDidChange(_ textView: UITextView) {
            (textView as? MarkdownUITextView)?.refreshChrome()
            // From here too, not only from the selection callback: UIKit fires
            // `didChangeSelection` *before* `didChange` for an insertion, so on
            // the keystroke that completes `[[` the parse the context is read
            // from is still one edit behind.
            (textView as? MarkdownUITextView)?.reportInlineContext()
            let tv = textView as? MarkdownUITextView
            tv?.clearInlineSuggestion()
            // Next runloop turn on purpose: `performEdit` notifies the delegate
            // *before* it moves the caret, so asking now would describe the
            // caret's old position and the host's reply would be refused as
            // stale. The host debounces anyway, so the hop is free.
            // `[weak self]`, as the AppKit twin has always had. Capturing the
            // text view strongly here retains it — and through it the whole
            // TextKit 2 stack and its `EditorDocument` — past the point SwiftUI
            // tears it down, once per keystroke. A detached view then answers
            // an inline-completion request describing the note you just left,
            // through the shared proxy that now points at the new one.
            DispatchQueue.main.async { [weak tv] in tv?.requestInlineCompletion() }
        }

        public func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView as? MarkdownUITextView)?.ensureVisibleRangeStyled()
            // The caret rect is reported in viewport coordinates, so scrolling
            // moves it even though the caret itself has not budged.
            (scrollView as? MarkdownUITextView)?.reportInlineContext()
        }
    }
}

// MARK: - Formatting

#endif
