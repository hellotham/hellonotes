//
//  MarkdownUITextView.swift
//  MarkdownEditor
//
//  The iOS editor view: a TextKit 2 UITextView bound to the same EditorDocument
//  as the macOS NSTextView. The document, parser, style spec, style applier and
//  the (now cross-platform) block-render fragment are shared; only the view
//  shell differs. Live inline styling, caret-driven concealment, list bullets,
//  callouts, heading rules and checkboxes all come from the shared layers.
//

#if canImport(UIKit) && !canImport(AppKit)
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
    /// Draws the fragment chrome (bullets, callout bands, checkboxes, gutter
    /// bars, heading rules) — UITextView doesn't invoke custom fragments' draw.
    private lazy var chromeOverlay = ChromeOverlayView()
    var onLinkTap: ((EditorLinkTap) -> Void)?

    public static func make(document: EditorDocument) -> MarkdownUITextView {
        let tv = MarkdownUITextView(usingTextLayoutManager: true)
        tv.bind(to: document)
        tv.isEditable = true
        tv.isScrollEnabled = true
        tv.alwaysBounceVertical = true
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        tv.textContainer.lineFragmentPadding = 5
        // Markdown is source text: typographic substitutions corrupt syntax.
        // Autocorrect/autocapitalization can rewrite source (e.g. inside code
        // spans or link targets), so disable them, matching the macOS view.
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartDashesType = .no
        tv.smartQuotesType = .no
        tv.smartInsertDeleteType = .no
        tv.spellCheckingType = .default
        tv.keyboardDismissMode = .interactive

        // Tap-to-navigate wiki links / URLs (an editable text view otherwise
        // just moves the caret).
        let tap = UITapGestureRecognizer(target: tv, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        tv.addGestureRecognizer(tap)

        // Overlay that paints the fragment chrome over the text (scrolls with
        // the content as a subview of the scroll view).
        tv.chromeOverlay.textView = tv
        tv.chromeOverlay.isUserInteractionEnabled = false
        tv.chromeOverlay.backgroundColor = .clear
        tv.chromeOverlay.contentMode = .redraw
        tv.addSubview(tv.chromeOverlay)
        return tv
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
    public override func paste(_ sender: Any?) {
        if let string = UIPasteboard.general.string {
            insertText(string)
        }
        // No plain-text representation (e.g. an image-only pasteboard): drop it
        // rather than let UITextView insert a foreign attachment into storage.
    }

    private func bind(to document: EditorDocument) {
        self.document = document
        // Default typing attributes MUST be set before the storage is attached,
        // mirroring the macOS view (setting `font` applies it to the whole
        // storage, clobbering per-run concealed fonts otherwise).
        font = document.theme.body
        typingAttributes = [
            .font: document.theme.body,
            .foregroundColor: document.theme.text,
        ]
        if let contentStorage = textLayoutManager?.textContentManager as? NSTextContentStorage {
            contentStorage.textStorage = document.storage
        }
        // Set the fragment-vending delegate AFTER attaching storage — attaching a
        // new text storage can re-seat the layout manager on iOS.
        textLayoutManager?.delegate = blockLayoutDelegate
        syncRenderMetrics()
    }

    func syncRenderMetrics() {
        guard let document else { return }
        let padding = textContainer.lineFragmentPadding * 2
        let width = bounds.width - padding - textContainerInset.left - textContainerInset.right
        if width > 0 { document.renderMaxWidth = min(width, 900) }
        document.isDarkAppearance = traitCollection.userInterfaceStyle == .dark
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        syncRenderMetrics()
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
            let frame = fragment.layoutFragmentFrame
            let top = inset.top + frame.origin.y
            if top > rect.maxY { return false }   // below the dirty rect; done
            if let chrome = fragment as? RenderedBlockFragment,
               top + frame.height >= rect.minY {   // intersects vertically
                chrome.drawChromeOnly(at: CGPoint(x: inset.left + frame.origin.x, y: top), in: context)
            }
            return true
        }
    }
}

/// SwiftUI host for the iOS Markdown editor. Same public surface (`init`,
/// `editable`, `onLinkTap`) as the macOS `MarkdownEditorView`.
public struct MarkdownEditorView: UIViewRepresentable {
    private let document: EditorDocument
    private var isEditable = true
    private var onLinkTap: ((EditorLinkTap) -> Void)?

    public init(document: EditorDocument) { self.document = document }

    public func editable(_ flag: Bool) -> Self {
        var copy = self; copy.isEditable = flag; return copy
    }

    public func onLinkTap(_ handler: @escaping (EditorLinkTap) -> Void) -> Self {
        var copy = self; copy.onLinkTap = handler; return copy
    }

    public func makeUIView(context: Context) -> MarkdownUITextView {
        let tv = MarkdownUITextView.make(document: document)
        tv.isEditable = isEditable
        tv.onLinkTap = onLinkTap
        tv.delegate = context.coordinator
        // Small/medium notes: style the whole document once up front (proven
        // path). Large notes: rely on the document's synchronous prefix styling
        // (done in init) plus its idle background pass, so opening never blocks
        // the main thread on the entire document. The visible range is styled
        // (and its layout invalidated) via `ensureVisibleRangeStyled` on scroll.
        if document.storage.length <= 200_000 {
            document.styleEverythingNow()
        }
        return tv
    }

    public func updateUIView(_ tv: MarkdownUITextView, context: Context) {
        tv.isEditable = isEditable
        tv.onLinkTap = onLinkTap
    }

    public func makeCoordinator() -> Coordinator { Coordinator(document: document) }

    public final class Coordinator: NSObject, UITextViewDelegate {
        let document: EditorDocument
        init(document: EditorDocument) { self.document = document }

        public func textViewDidChangeSelection(_ textView: UITextView) {
            document.selectionDidChange(textView.selectedRange)
            // Reveal flips which markers conceal / which chrome shows.
            (textView as? MarkdownUITextView)?.refreshChrome()
        }

        public func textViewDidChange(_ textView: UITextView) {
            (textView as? MarkdownUITextView)?.refreshChrome()
        }

        public func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView as? MarkdownUITextView)?.ensureVisibleRangeStyled()
        }
    }
}
#endif
