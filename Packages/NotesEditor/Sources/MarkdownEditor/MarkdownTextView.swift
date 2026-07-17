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

#if canImport(AppKit)
import AppKit
import SwiftUI
import MarkdownCore

/// What the user tapped, resolved for the host app.
public enum EditorLinkTap {
    case wiki(target: String)
    case url(URL)
}

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

    /// Build the full scroll-view + TextKit 2 text-view assembly.
    static func scrollableEditor(document: EditorDocument) -> (NSScrollView, MarkdownTextView) {
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
        // System inline predictive completion (ghost text) while typing.
        if #available(macOS 15.0, *) {
            textView.inlinePredictionType = .yes
        }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView

        // Progressive styling: as content scrolls into view, make sure its
        // blocks are styled (idempotent; free once the initial pass ends).
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView, queue: .main
        ) { [weak textView] _ in
            MainActor.assumeIsolated {
                textView?.ensureVisibleRangeStyled()
            }
        }
        return (scrollView, textView)
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
        document.ensureStyled(charactersIn: range)
    }

    private(set) weak var document: EditorDocument?

    func bind(to document: EditorDocument) {
        self.document = document
        // Attach the document's storage to this view's TextKit 2 stack.
        if let contentStorage = textContentStorage {
            contentStorage.textStorage = document.storage
        }
        font = document.theme.body
        typingAttributes = [
            .font: document.theme.body,
            .foregroundColor: document.theme.text,
        ]
    }

    /// Pasteboard intents, injected by the host: return the Markdown to
    /// insert (image saved to the vault, HTML converted, …) or nil to fall
    /// through to the default plain paste.
    var onPasteMarkdown: ((NSPasteboard) -> String?)?

    /// Reports the caret's autocomplete context (`[[link` / `#tag`) and its
    /// rect in this view's enclosing scroll-view coordinates, or nil.
    var onInlineContextChange: ((EditorDocument.InlineContext?, CGRect) -> Void)?

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

    public override func paste(_ sender: Any?) {
        if let onPasteMarkdown, let markdown = onPasteMarkdown(NSPasteboard.general) {
            performEdit(replacing: selectedRange(), with: markdown)
            return
        }
        pasteAsPlainText(sender)   // never import rich text into Markdown
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
                forName: Notification.Name("hnEditorFindQuery"),
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
                        name: Notification.Name("hnEditorFindResults"),
                        object: nil, userInfo: ["count": count])
                }
            })
            busTokens.append(center.addObserver(
                forName: Notification.Name("hnEditorReplaceCurrent"),
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
                forName: Notification.Name("hnEditorReplaceAll"),
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
                forName: Notification.Name("hnEditorClearHighlights"),
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
#endif
