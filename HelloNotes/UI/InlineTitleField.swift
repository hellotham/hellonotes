//
//  InlineTitleField.swift
//  HelloNotes
//
//  An AppKit-backed title field, because SwiftUI's TextField gets the two
//  boundary behaviours wrong and gives no hook to correct them:
//
//  - Programmatic focus makes AppKit's field editor **select all**, so arrowing
//    up from the note's first character highlighted the whole title instead of
//    putting a caret at its end.
//  - Handing focus *away* left the text view first responder without a visible
//    insertion point, because the caret blink timer is only restarted when
//    AppKit itself moves focus.
//
//  Owning the NSTextField lets both be fixed at the source: place the caret
//  explicitly on focus, and restart the insertion point when handing over.
//

#if os(macOS)
import SwiftUI
import AppKit

struct InlineTitleField: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    /// Commit the edit (rename).
    var onCommit: (String) -> Void
    /// The caret is leaving downward — the host focuses the note body.
    var onEnterBody: () -> Void
    /// Set by the host to pull focus here, with the caret at the end.
    var focusRequest: Int

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.font = font
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderString = "Untitled"
        field.delegate = context.coordinator
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.font != font { field.font = font }
        // Never fight the user's own typing.
        if field.stringValue != text, field.currentEditor() == nil {
            field.stringValue = text
        }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            context.coordinator.takeFocusPlacingCaretAtEnd()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320,
               height: nsView.intrinsicContentSize.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineTitleField
        weak var field: NSTextField?
        var lastFocusRequest = 0

        init(_ parent: InlineTitleField) { self.parent = parent }

        /// Focus with the caret at the end rather than the whole title
        /// selected. AppKit selects all when a field becomes first responder,
        /// which is right when you tab into a form and wrong when a caret has
        /// just arrived from the text below.
        func takeFocusPlacingCaretAtEnd() {
            guard let field, let window = field.window else { return }
            window.makeFirstResponder(field)
            if let editor = field.currentEditor() {
                let end = (field.stringValue as NSString).length
                editor.selectedRange = NSRange(location: end, length: 0)
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field else { return }
            // Correct illegal filename characters as they're typed, keeping the
            // caret where it was rather than jumping it to the end.
            let cleaned = InlineNoteTitle.sanitised(field.stringValue)
            if cleaned != field.stringValue {
                let caret = field.currentEditor()?.selectedRange
                field.stringValue = cleaned
                if let caret { field.currentEditor()?.selectedRange = caret }
            }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertTab(_:)),
                 #selector(NSResponder.moveDown(_:)):
                parent.onCommit(control.stringValue)
                parent.onEnterBody()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                control.stringValue = parent.text
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field else { return }
            parent.onCommit(field.stringValue)
        }
    }
}
#endif
