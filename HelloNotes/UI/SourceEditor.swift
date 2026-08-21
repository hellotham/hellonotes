//
//  SourceEditor.swift
//  HelloNotes
//
//  Markdown mode's source editor — plain, unstyled, and substitution-free on
//  both platforms.
//
//  It was `iOSSourceEditor`, and it exists for one reason: **SwiftUI's
//  `TextEditor` has no way to turn typographic substitution off.** Markdown
//  mode shows the note's literal source, and the system rewrites what you type
//  in it — `---` under a table header becomes an em dash, `"` becomes a curly
//  quote, `--` becomes an en dash. The file on disk then holds characters no
//  Markdown parser recognises, so a table silently stops being a table.
//
//  The live editor has said this since it shipped ("Markdown is source text:
//  typographic substitutions corrupt syntax"). iOS fixed Markdown mode when the
//  bug was found there. **macOS was still on `TextEditor`** — the same
//  `NSTextView` defaults, the same corruption, on the platform where a vault is
//  most likely to hold a hand-written table. Fixing one platform and leaving the
//  other is the pattern this whole audit is about, so the editor is one type now
//  and the substitutions are off on both.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import MarkdownEditor

#if canImport(AppKit)
/// Plain, unstyled, substitution-free source editing.
struct SourceEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat

    /// S1: report the size offered, never the size contained — a text view's
    /// `fittingSize` is the whole document, which inflates every ancestor until
    /// the top of the note sits above the window.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView,
                      context: Context) -> CGSize? {
        viewportSizeThatFits(proposal)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.drawsBackground = false
        scroll.drawsBackground = false
        tv.textContainerInset = NSSize(width: 4, height: 8)
        Self.makeSourceOnly(tv)
        tv.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.font?.pointSize != fontSize {
            tv.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        // Only when it actually differs: assigning `string` resets the
        // selection, so echoing the user's own keystroke back would move the
        // caret to the end of the document on every character.
        if tv.string != text {
            let selection = tv.selectedRange()
            tv.string = text
            let length = (text as NSString).length
            tv.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }
    }

    /// Turn off everything that rewrites what was typed.
    ///
    /// Named and separate so it can be asserted directly — this is the whole
    /// reason the type exists, and it is a silent corruption when it regresses.
    /// AppKit defaults these to the user's system settings, which is right for
    /// prose and wrong for source.
    static func makeSourceOnly(_ tv: NSTextView) {
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isRichText = false
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
        }
    }
}
#else
/// Plain, unstyled, substitution-free source editing.
struct SourceEditor: UIViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat

    /// S1: report the size offered, never the size contained. A `UITextView`'s
    /// `fittingSize` is the whole document, which inflates every ancestor until
    /// the top of the note sits above the window. See docs/layout-architecture.md.
    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: UITextView,
                      context: Context) -> CGSize? {
        viewportSizeThatFits(proposal)
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.alwaysBounceVertical = true
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        SourceEditor.makeSourceOnly(tv)
        tv.keyboardDismissMode = .interactive
        tv.isFindInteractionEnabled = true
        tv.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.text = text
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        if tv.font?.pointSize != fontSize {
            tv.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        // Only when it actually differs: assigning `text` resets the selection,
        // so echoing the user's own keystroke back would move the caret to the
        // end of the document on every character.
        if tv.text != text {
            let selection = tv.selectedRange
            tv.text = text
            tv.selectedRange = NSRange(location: min(selection.location, (text as NSString).length),
                                       length: 0)
        }
    }

    /// Turn off everything that rewrites what was typed. Named and separate so
    /// it can be asserted directly — this is the whole reason the type exists.
    static func makeSourceOnly(_ tv: UITextView) {
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartDashesType = .no
        tv.smartQuotesType = .no
        tv.smartInsertDeleteType = .no
        tv.spellCheckingType = .no
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }
    }
}
#endif
