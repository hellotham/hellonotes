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
//  It also carries the *column* across the seam. Arrowing up a column is meant
//  to keep your place in that column; landing at the end of the title (or at
//  the start of the body on the way back down) is exactly the behaviour AppKit
//  works to avoid inside a single text view, and the seam must not undo it.
//  Because the title is set in the document's H1 and the body is not, a column
//  is a *distance* in points from the first glyph, never a character count.
//

import SwiftUI
import MarkdownEditor   // PlatformFont
#if os(macOS)
import AppKit
#endif

#if os(macOS)

struct InlineTitleField: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    /// Commit the edit (rename).
    var onCommit: (String) -> Void
    /// The caret is leaving downward — the host focuses the note body, at the
    /// horizontal offset given (points from the first glyph), or `nil` when
    /// there is no column to keep (Return and Tab commit rather than navigate).
    var onEnterBody: (CGFloat?) -> Void
    /// Set by the host to pull focus here. Carries where the caret should land.
    var focusRequest: CaretHandoff

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
        if context.coordinator.lastFocusRequest != focusRequest.token {
            context.coordinator.lastFocusRequest = focusRequest.token
            context.coordinator.takeFocus(landingAt: focusRequest.x)
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

        /// Focus with the caret placed deliberately, rather than the whole
        /// title selected. AppKit selects all when a field becomes first
        /// responder, which is right when you tab into a form and wrong when a
        /// caret has just arrived from the text below.
        ///
        /// `x` is the column to keep (points from the first glyph); `nil` means
        /// the caret walked backwards off the start of the body, where there is
        /// no column and the end of the title is where it belongs.
        func takeFocus(landingAt x: CGFloat?) {
            guard let field, let window = field.window else { return }
            window.makeFirstResponder(field)
            guard let editor = field.currentEditor() else { return }
            let text = field.stringValue as NSString
            let location = x.map { Self.index(nearestTo: $0, in: text, font: parent.font) }
                ?? text.length
            editor.selectedRange = NSRange(location: location, length: 0)
        }

        /// The caret's distance from the first glyph, for the body to land on.
        ///
        /// Measured by laying out the prefix rather than asking the field
        /// editor's layout manager: the title is one unwrapped line, so the
        /// prefix width *is* the offset, and it stays right when the caret sits
        /// past the last glyph (where a zero-length glyph range has no rect).
        var caretXOffset: CGFloat {
            guard let field, let editor = field.currentEditor() else { return 0 }
            let prefix = (field.stringValue as NSString).substring(to: min(
                editor.selectedRange.location, (field.stringValue as NSString).length))
            return (prefix as NSString).size(withAttributes: [.font: parent.font]).width
        }

        /// The character index whose prefix width is nearest `x`. Linear in the
        /// title's length, which is a filename — the exact answer is cheaper
        /// here than an approximation.
        static func index(nearestTo x: CGFloat, in text: NSString, font: NSFont) -> Int {
            var best = 0
            var bestDelta = CGFloat.greatestFiniteMagnitude
            for i in 0...text.length {
                let width = (text.substring(to: i) as NSString)
                    .size(withAttributes: [.font: font]).width
                let delta = abs(width - x)
                if delta < bestDelta { bestDelta = delta; best = i }
                // Widths are monotonic, so once we start getting worse we're done.
                if width > x { break }
            }
            return best
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
            case #selector(NSResponder.moveDown(_:)):
                // Arrowing down keeps the column.
                let x = caretXOffset
                parent.onCommit(control.stringValue)
                parent.onEnterBody(x)
                return true
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertTab(_:)):
                // Return and Tab are "I'm done here", not navigation, so the
                // body gets the caret at its start.
                parent.onCommit(control.stringValue)
                parent.onEnterBody(nil)
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

#else
/// The iOS title field.
///
/// SwiftUI's `TextField` is exactly right here, and the two boundary behaviours
/// the Mac's `NSTextField` exists to correct do not arise the same way: UIKit
/// does not select-all on programmatic focus, and there is no field editor whose
/// caret timer needs restarting.
///
/// One thing is genuinely not carried across the seam: the *column*. SwiftUI has
/// no way to place a caret at an x offset in a `TextField`, so the whole field
/// takes focus and `onEnterBody` reports no column. The Mac keeps it through its
/// own representable. That is a platform capability, not a decision — and it is
/// why this type exists on both sides rather than the caller choosing between
/// two different views.
struct InlineTitleField: View {
    @Binding var text: String
    let font: PlatformFont
    var onCommit: (String) -> Void
    var onEnterBody: (CGFloat?) -> Void
    var focusRequest: CaretHandoff

    @FocusState private var focused: Bool

    var body: some View {
        TextField("Untitled", text: $text)
            .textFieldStyle(.plain)
            .font(Font(font))
            .submitLabel(.done)
            .autocorrectionDisabled()
            .focused($focused)
            // The caret arrived from the note below. The Mac's field has taken
            // this since the inline title shipped; iOS's ignored it, so ↑ from
            // the first line of a note on an iPad keyboard did nothing.
            .onChange(of: focusRequest) { _, _ in focused = true }
            .onSubmit {
                onCommit(text)
                // Return commits and hands the caret back down, with no column
                // to keep — the same contract the Mac's field reports.
                onEnterBody(nil)
            }
    }
}
#endif
