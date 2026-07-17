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
    private let blockLayoutDelegate = RenderedBlockLayoutDelegate()
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
        tv.autocorrectionType = .default
        tv.autocapitalizationType = .sentences
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
        return tv
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
        _ = document.ensureStyled(charactersIn: range)
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
        // Style the whole document once up front (edits then restyle
        // incrementally via the shared storage delegate).
        document.styleEverythingNow()
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
        }

        public func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView as? MarkdownUITextView)?.ensureVisibleRangeStyled()
        }
    }
}
#endif
