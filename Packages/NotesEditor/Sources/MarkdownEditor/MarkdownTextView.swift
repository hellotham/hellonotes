//
//  MarkdownTextView.swift
//  MarkdownEditor
//
//  The macOS editor view: a TextKit 2 NSTextView bound to an
//  EditorDocument's storage. Deliberately boring — no scroll-view
//  subclasses, no overlay reconciliation, no layout tricks. Standard
//  AppKit machinery (caret autoscroll included) works because nothing
//  fights it. (The UITextView sibling lands in M5 on the same document.)
//

import Foundation

/// What the user tapped, resolved for the host app. (Cross-platform.)
public enum EditorLinkTap {
    case wiki(target: String)
    case url(URL)
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
        textView.textContainerInset = NSSize(width: 16, height: 12)
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

    func bind(to document: EditorDocument) {
        self.document = document
        // Default font/typing attributes MUST be set before the storage is
        // attached: setting `font` applies it to the entire text storage,
        // which would clobber the per-run concealed (0.1pt) fonts already in
        // the document's storage — leaving concealed markers invisible but
        // still occupying their full width.
        font = document.theme.body
        typingAttributes = [
            .font: document.theme.body,
            .foregroundColor: document.theme.text,
        ]
        // Custom fragments draw inline-rendered block embeds (images…).
        textLayoutManager?.delegate = blockLayoutDelegate
        // Attach the document's storage to this view's TextKit 2 stack.
        if let contentStorage = textContentStorage {
            contentStorage.textStorage = document.storage
        }
        syncRenderMetrics()
    }

    /// Feed the document the current usable width + appearance for sizing
    /// rendered block images.
    func syncRenderMetrics() {
        guard let document else { return }
        let padding = (textContainer?.lineFragmentPadding ?? 0) * 2
        let width = (textContainer?.size.width ?? bounds.width) - padding - textContainerInset.width * 2
        if width > 0 { document.renderMaxWidth = min(width, 900) }
        document.isDarkAppearance = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    public override func layout() {
        super.layout()
        syncRenderMetrics()
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
    var onPasteMarkdown: ((NSPasteboard) -> String?)?

    /// Reports the caret's autocomplete context (`[[link` / `#tag`) and its
    /// rect in this view's enclosing scroll-view coordinates, or nil.
    var onInlineContextChange: ((EditorDocument.InlineContext?, CGRect) -> Void)?

    /// Host AI hook: when set (and the view is editable), the selection's
    /// context menu offers "Rewrite with AI…", delivering the selected range.
    var onRewriteSelection: ((NSRange) -> Void)?

    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        if onRewriteSelection != nil, isEditable, selectedRange().length > 0 {
            let item = NSMenuItem(title: String(localized: "Rewrite with AI…"),
                                  action: #selector(rewriteSelectionFromMenu(_:)),
                                  keyEquivalent: "")
            item.target = self
            menu?.insertItem(item, at: 0)
            menu?.insertItem(.separator(), at: 1)
        }
        return menu
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
        if let onPasteMarkdown, let markdown = onPasteMarkdown(NSPasteboard.general) {
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
    private var onPasteMarkdown: ((NSPasteboard) -> String?)?
    private var onInlineContext: ((EditorDocument.InlineContext?, CGRect) -> Void)?
    private var onRewriteSelectionHandler: ((NSRange) -> Void)?
    private var busDocumentId: String?
    private var editorProxy: EditorProxy?

    public init(document: EditorDocument) {
        self.document = document
    }

    public func editable(_ flag: Bool) -> Self {
        var copy = self; copy.isEditable = flag; return copy
    }

    public func onLinkTap(_ handler: @escaping (EditorLinkTap) -> Void) -> Self {
        var copy = self; copy.onLinkTap = handler; return copy
    }

    /// Host paste hook: return Markdown to insert, or nil for plain paste.
    public func onPasteMarkdown(_ handler: @escaping (NSPasteboard) -> String?) -> Self {
        var copy = self; copy.onPasteMarkdown = handler; return copy
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
        if textView.document !== document {
            textView.bind(to: document)
        }
        context.coordinator.onLinkTap = onLinkTap
        textView.onPasteMarkdown = onPasteMarkdown
        textView.onInlineContextChange = onInlineContext
        textView.onRewriteSelection = onRewriteSelectionHandler
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

        func subscribeToBus(documentId: String?) {
            guard let documentId, busTokens.isEmpty else { return }
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
        let headings = document?.headings() ?? []
        guard !headings.isEmpty else { return nil }
        let forward = searchParameters.searchDirection == .next
        let target: (level: Int, title: String, range: NSRange)?
        if let current = searchParameters.currentItem?.targetRange {
            target = forward
                ? headings.first { $0.range.location > current.location }
                : headings.last { $0.range.location < current.location }
        } else {
            target = forward ? headings.first : headings.last
        }
        guard let heading = target else { return nil }
        let result = NSAccessibilityCustomRotor.ItemResult(targetElement: self)
        result.targetRange = heading.range
        result.customLabel = heading.title
        return result
    }
}
#endif
