//
//  iOSSourceEditor.swift
//  HelloNotes
//
//  The Markdown-mode (and split-mode) source editor on iOS.
//
//  A `UITextView` rather than SwiftUI's `TextEditor`, for one reason:
//  **SwiftUI has no way to turn typographic substitution off.** Markdown mode
//  shows the note's literal source, and iOS rewrites what you type in it —
//  `---` under a table header becomes an em dash, `"` becomes a curly quote,
//  `--` becomes an en dash. The file on disk then contains characters no
//  Markdown parser recognises, so a table silently stops being a table.
//
//  The live editor has said this since it shipped ("Markdown is source text:
//  typographic substitutions corrupt syntax") and sets `smartDashesType`,
//  `smartQuotesType` and `smartInsertDeleteType` to `.no`. Markdown mode had
//  none of it, which is the surface where it matters most.
//

#if os(iOS)
import SwiftUI
import UIKit
import MarkdownEditor

/// Plain, unstyled, substitution-free source editing.
struct iOSSourceEditor: UIViewRepresentable {
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
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartDashesType = .no
        tv.smartQuotesType = .no
        tv.smartInsertDeleteType = .no
        tv.spellCheckingType = .no
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
