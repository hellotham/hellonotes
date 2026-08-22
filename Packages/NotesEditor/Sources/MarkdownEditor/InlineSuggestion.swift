//
//  InlineSuggestion.swift
//  MarkdownEditor
//
//  Ghost text: a completion drawn after the caret that is **not in the
//  document**.
//
//  The whole feature rests on that one sentence, and it is an architectural
//  claim rather than a careful one. The suggestion lives in a stored property
//  on the view and is painted in `draw(_:)`. It is never inserted into the text
//  storage, so it cannot reach a reparse, a style pass, an autosave, the search
//  index, the link graph, or a Git diff — not because each of those was checked,
//  but because there is no code path from a property the drawing code reads to
//  the storage those systems read. The only thing that ever writes it is
//  `acceptInlineSuggestion()`, and at that moment it is the user's text, typed
//  through the same undoable path as every other edit.
//
//  It is drawn only at the **end of a line**, and only as a single line. That
//  is a real restriction, taken deliberately: ghost text drawn in front of
//  existing characters has to reflow text it does not own, in a TextKit 2 view
//  whose layout this app has been burned by before (implemented.md §17). One
//  line at the end of one line needs no reflow at all — it paints into space
//  that is already empty. What does not fit is trimmed off the *suggestion*, at
//  a word boundary, so that what you see is exactly what accepting inserts. A
//  ghost that accepts more than it shows would be the same lie as an invented
//  link, told faster.
//

import Foundation

/// A completion offered after the caret. Display-only until accepted.
public struct InlineSuggestion: Equatable, Sendable {
    /// The caret offset this was computed for.
    ///
    /// Carried so acceptance can refuse a suggestion whose document moved
    /// underneath it. The request is asynchronous and the user keeps typing;
    /// without this, a late reply inserts a completion for a sentence that no
    /// longer exists at a caret that has moved on.
    public let location: Int
    public let text: String

    public init(location: Int, text: String) {
        self.location = location
        self.text = text
    }

    /// Normalise a model's reply into something drawable, or `nil` if there is
    /// nothing usable left.
    ///
    /// Models return continuations wrapped in quotes, prefixed with the words
    /// they were asked to continue, or spanning paragraphs. Only the first line
    /// is ever shown, so trimming to it here means the drawn text and the
    /// accepted text are the same string by construction rather than by two
    /// pieces of code agreeing.
    public static func sanitise(_ reply: String, maxCharacters: Int = 160) -> String? {
        var text = reply
        // A whole-reply quote is the model narrating; a leading fence is it
        // deciding this was a code question.
        if text.hasPrefix("```") { return nil }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first
        else { return nil }
        text = String(firstLine)
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        }
        // Trailing whitespace only: a completion legitimately *starts* with a
        // space, and eating it is how ghost text ends up glued to the word
        // before it.
        while let last = text.last, last.isWhitespace { text.removeLast() }
        guard !text.isEmpty else { return nil }
        return String(text.prefix(maxCharacters))
    }
}

/// What the host needs in order to complete: where the caret is, and enough
/// text on either side of it to write something that fits.
public struct InlineCompletionContext: Sendable, Equatable {
    public let location: Int
    /// Text immediately before the caret, bounded.
    public let prefix: String
    /// Text immediately after it, bounded — so a completion doesn't duplicate
    /// what the next paragraph already says.
    public let suffix: String
}

#if canImport(AppKit)
import AppKit

extension MarkdownTextView {

    // MARK: - Offering

    /// The suggestion, if one is genuinely live.
    ///
    /// Validated on read rather than invalidated on change, and that is the
    /// load-bearing decision in this file. Clearing on caret movement means
    /// finding *every* path that moves a caret — arrow keys, clicks, drags,
    /// find-bar jumps, programmatic selection, AppKit's own funnel points,
    /// which do not all pass through the one override you picked. Miss one and
    /// a stale suggestion is not merely drawn in the wrong place: it can be
    /// accepted, inserting a completion for a sentence the caret has left.
    /// Recomputing against the current caret cannot miss a path, because there
    /// is no path to miss.
    var inlineSuggestion: InlineSuggestion? {
        guard let stored = storedInlineSuggestion else { return nil }
        let selection = selectedRange()
        guard selection.length == 0, selection.location == stored.location else { return nil }
        return stored
    }

    /// Show `suggestion`, or clear it. Refused unless it describes the caret as
    /// it is right now, and a place ghost text can honestly be drawn.
    func showInlineSuggestion(_ suggestion: InlineSuggestion?) {
        let previous = storedInlineSuggestion
        guard previous != suggestion else { return }
        if let suggestion {
            let selection = selectedRange()
            guard selection.length == 0,
                  selection.location == suggestion.location,
                  isEditable,
                  canOfferSuggestion(at: selection.location)
            else {
                storedInlineSuggestion = nil
                if previous != nil { invalidateSuggestionArea(for: previous) }
                return
            }
        }
        storedInlineSuggestion = suggestion
        invalidateSuggestionArea(for: previous ?? suggestion)
    }

    func clearInlineSuggestion() {
        guard let previous = storedInlineSuggestion else { return }
        storedInlineSuggestion = nil
        invalidateSuggestionArea(for: previous)
    }

    /// Ghost text is offered only where it can be drawn honestly: an empty
    /// selection sitting at the end of a line, with no `[[link` or `#tag`
    /// autocomplete already open at the caret. Two completion UIs on the same
    /// character, competing for the same Escape and the same Tab, is one more
    /// than anybody wants.
    func canOfferSuggestion(at location: Int) -> Bool {
        let ns = string as NSString
        guard location >= 0, location <= ns.length else { return false }
        guard document?.inlineContext(at: location) == nil else { return false }
        guard location < ns.length else { return true }   // end of document
        return ns.character(at: location) == 10           // newline
    }

    /// Redraw generously — the caret line, full width. Ghost text is at most
    /// one line, and being exact here would trade a real class of stale-pixel
    /// bug for nothing measurable.
    private func invalidateSuggestionArea(for suggestion: InlineSuggestion?) {
        guard let suggestion else { needsDisplay = true; return }
        var rect = caretRectInView(at: suggestion.location)
        guard rect != .zero else { needsDisplay = true; return }
        rect.origin.x = 0
        rect.size.width = bounds.width
        setNeedsDisplay(rect.insetBy(dx: 0, dy: -4))
    }

    // MARK: - Drawing

    /// Paint the ghost. Called from `draw(_:)` after `super`.
    func drawInlineSuggestion() {
        guard let suggestion = inlineSuggestion, let document else { return }
        let caret = caretRectInView(at: suggestion.location)
        guard caret != .zero else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: document.theme.body,
            .foregroundColor: document.theme.text.withAlphaComponent(0.38),
        ]
        guard let drawn = drawableSuggestionText(suggestion, attributes: attributes) else { return }

        // Baseline-align with the caret's line rather than filling its rect:
        // the caret rect is the *line* height, and drawing at its origin sits
        // the ghost a couple of points above the text it continues.
        let string = NSAttributedString(string: drawn, attributes: attributes)
        let size = string.size()
        let y = caret.midY - size.height / 2
        string.draw(at: CGPoint(x: caret.maxX, y: y))
    }

    /// How much of `suggestion` actually fits on the caret's line — `nil` when
    /// none of it does.
    ///
    /// The single answer used by **both** drawing and accepting. It used to be
    /// computed only while drawing: `acceptInlineSuggestion` inserted
    /// `suggestion.text` whole, so a completion trimmed at a word boundary to
    /// the ~40 characters that fit inserted all 160 of them, and the two
    /// early-outs here (no room at all, first word too wide) returned without
    /// drawing while leaving the suggestion live — so a plain → at the end of a
    /// line inserted a completion that had never been on screen. This file's
    /// contract is that "the drawn text and the accepted text must be the same
    /// string"; one function is how that stays true.
    func drawableSuggestionText(_ suggestion: InlineSuggestion,
                                attributes: [NSAttributedString.Key: Any]) -> String? {
        let caret = caretRectInView(at: suggestion.location)
        // No geometry yet — an unlaid-out view, or a caret whose fragment TextKit
        // has not produced. Nothing can be *drawn*, but nothing has been hidden
        // from the user either, so accepting still means the whole suggestion.
        // Only a measured line can shorten it.
        guard caret != .zero, bounds.width > 0 else { return suggestion.text }
        let available = bounds.width - caret.maxX
            - textContainerInset.width - (textContainer?.lineFragmentPadding ?? 0)
        guard available > 12 else { return nil }
        let drawn = suggestion.text.fitting(width: available, attributes: attributes)
        return drawn.isEmpty ? nil : drawn
    }

    /// The text accepting would insert, given where the caret is now.
    var acceptableSuggestionText: String? {
        guard let suggestion = inlineSuggestion, let document else { return nil }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: document.theme.body,
            .foregroundColor: document.theme.text.withAlphaComponent(0.38),
        ]
        return drawableSuggestionText(suggestion, attributes: attributes)
    }

    /// The caret rect in this view's own coordinates.
    ///
    /// Distinct from the private `caretRect(at:)`, which converts into the
    /// enclosing scroll view for SwiftUI overlays. Drawing happens here, in
    /// view space, and converting twice is how ghost text ends up a scroll
    /// offset away from the caret.
    func caretRectInView(at location: Int) -> CGRect {
        guard let tlm = textLayoutManager,
              let contentManager = tlm.textContentManager,
              let start = contentManager.location(contentManager.documentRange.location,
                                                  offsetBy: location)
        else { return .zero }
        var rect = CGRect.zero
        tlm.enumerateTextSegments(in: NSTextRange(location: start),
                                  type: .selection, options: [.rangeNotRequired]) { _, frame, _, _ in
            rect = frame
            return false
        }
        guard rect != .zero else { return .zero }
        return rect.offsetBy(dx: textContainerInset.width, dy: textContainerInset.height)
    }

    // MARK: - Accepting

    /// Insert the suggestion at the caret. The **only** path from ghost text to
    /// the document, and it goes through `performEdit` — the same undoable
    /// route typing takes, so an accepted completion is undone with one ⌘Z and
    /// is indistinguishable from text the user wrote, because by then it is.
    @discardableResult
    public func acceptInlineSuggestion() -> Bool {
        // `inlineSuggestion` is nil unless it still matches the caret, so a
        // reply that arrived for a sentence the user has moved on from cannot
        // be accepted at all.
        guard let suggestion = inlineSuggestion,
              // Exactly what is on screen — never more, and nothing at all when
              // nothing was drawn. See `acceptableSuggestionText`.
              let text = acceptableSuggestionText else {
            clearInlineSuggestion()
            return false
        }
        clearInlineSuggestion()
        return performEdit(replacing: NSRange(location: suggestion.location, length: 0),
                           with: text)
    }

    // MARK: - Requesting

    /// Ask the host for a completion at the caret, if one could be shown here.
    func requestInlineCompletion() {
        guard isEditable, let onInlineCompletionRequest else { return }
        let selection = selectedRange()
        guard selection.length == 0, canOfferSuggestion(at: selection.location) else {
            clearInlineSuggestion()
            return
        }
        let ns = string as NSString
        let budget = 1_200
        let start = max(0, selection.location - budget)
        let after = min(ns.length - selection.location, 400)
        onInlineCompletionRequest(InlineCompletionContext(
            location: selection.location,
            prefix: ns.substring(with: NSRange(location: start, length: selection.location - start)),
            suffix: ns.substring(with: NSRange(location: selection.location, length: after))))
    }
}

private extension String {
    /// The longest prefix of this string that fits `width`, cut at a word
    /// boundary. Empty when even the first word doesn't fit.
    ///
    /// Truncating the *suggestion* rather than clipping the drawing is the
    /// point: the drawn text and the accepted text must be the same string.
    func fitting(width: CGFloat, attributes: [NSAttributedString.Key: Any]) -> String {
        guard width > 0 else { return "" }
        if (self as NSString).size(withAttributes: attributes).width <= width { return self }

        var candidate = ""
        var result = ""
        for piece in split(separator: " ", omittingEmptySubsequences: false) {
            candidate += (candidate.isEmpty ? "" : " ") + piece
            if (candidate as NSString).size(withAttributes: attributes).width > width { break }
            result = candidate
        }
        return result
    }
}
#else

// The other branch. Written as two one-sided gates facing opposite ways,
// which is the same defect wearing a disguise: nothing pairs them, so one
// can gain an operation the other never hears about.
import UIKit

//  The UIKit half.
//
//  Same invariant, same three operations, two differences that are not
//  cosmetic:
//
//  * **Drawing.** `UITextView` does not invoke a subclass's `draw(_:)` over its
//    own text the way `NSTextView` does, which is why every other piece of
//    chrome in this editor is painted by `ChromeOverlayView`. The ghost goes
//    there too, in the same content coordinate space the fragments use.
//  * **Acceptance.** ⌥⇥ / → / Esc are a hardware keyboard's answer, and an iPad
//    often has none. The gesture is therefore **a tap on the ghost itself**:
//    it is the only region on screen where a tap currently means nothing (the
//    caret is already at the end of that line, which is what a tap there would
//    otherwise ask for), so nothing is taken away to make room for it. ⌥⇥ and
//    Esc are still offered when a keyboard is attached, so an iPad with a Magic
//    Keyboard behaves exactly like the Mac.

extension MarkdownUITextView {

    // MARK: - Offering

    /// The suggestion, if one is genuinely live. Validated on read rather than
    /// invalidated on change — see the AppKit half above for why that is the
    /// load-bearing decision and not a stylistic one.
    var inlineSuggestion: InlineSuggestion? {
        guard let stored = storedInlineSuggestion else { return nil }
        let selection = selectedRange
        guard selection.length == 0, selection.location == stored.location else { return nil }
        return stored
    }

    func showInlineSuggestion(_ suggestion: InlineSuggestion?) {
        let previous = storedInlineSuggestion
        guard previous != suggestion else { return }
        if let suggestion {
            let selection = selectedRange
            guard selection.length == 0,
                  selection.location == suggestion.location,
                  isEditable,
                  canOfferSuggestion(at: selection.location)
            else {
                storedInlineSuggestion = nil
                if previous != nil { refreshChrome() }
                return
            }
        }
        storedInlineSuggestion = suggestion
        refreshChrome()
    }

    func clearInlineSuggestion() {
        guard storedInlineSuggestion != nil else { return }
        storedInlineSuggestion = nil
        refreshChrome()
    }

    /// Ghost text is offered only where it can be drawn honestly: an empty
    /// selection at the end of a line, with no `[[link` / `#tag` completion
    /// already open at the caret. Two completion UIs on one character, both
    /// wanting the same tap, is one more than anybody wants.
    func canOfferSuggestion(at location: Int) -> Bool {
        let ns = (text ?? "") as NSString
        guard location >= 0, location <= ns.length else { return false }
        guard document?.inlineContext(at: location) == nil else { return false }
        guard location < ns.length else { return true }   // end of document
        return ns.character(at: location) == 10           // newline
    }

    // MARK: - Drawing

    /// Where the ghost is painted, in the text view's content coordinates —
    /// which is also the chrome overlay's space, and the space a tap arrives in.
    /// One function answers both "where do I draw it" and "was that tap on it",
    /// so the two can never disagree about where the ghost is.
    func inlineSuggestionRect() -> CGRect? {
        guard let suggestion = inlineSuggestion, let document else { return nil }
        guard let position = position(from: beginningOfDocument, offset: suggestion.location)
        else { return nil }
        let caret = caretRect(for: position)
        guard caret.origin.x.isFinite, caret.origin.y.isFinite, caret.height > 0 else { return nil }

        let available = bounds.width - caret.maxX
            - textContainerInset.right - textContainer.lineFragmentPadding
        guard available > 12 else { return nil }

        let drawn = suggestion.text.fittingWidth(available, attributes: ghostAttributes(document))
        guard !drawn.isEmpty else { return nil }
        let size = (drawn as NSString).size(withAttributes: ghostAttributes(document))
        return CGRect(x: caret.maxX, y: caret.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    private func ghostAttributes(_ document: EditorDocument) -> [NSAttributedString.Key: Any] {
        [.font: document.theme.body,
         .foregroundColor: document.theme.text.withAlphaComponent(0.38)]
    }

    /// Paint the ghost. Called by `ChromeOverlayView.draw` after the fragments.
    func drawInlineSuggestion(in rect: CGRect) {
        guard let document else { return }
        guard let frame = inlineSuggestionRect(), frame.intersects(rect) else { return }
        guard let drawn = acceptableSuggestionText else { return }
        (drawn as NSString).draw(at: frame.origin, withAttributes: ghostAttributes(document))
    }

    /// The text accepting would insert, given where the caret is now — which is
    /// exactly what `drawInlineSuggestion` paints.
    ///
    /// Drawing already trimmed to what fits; accepting did not, and inserted
    /// `suggestion.text` whole. So a 160-character completion trimmed at a word
    /// boundary to the ~40 that fit inserted all 160 — and when
    /// `inlineSuggestionRect()` returned `nil` (no room on the line, or the
    /// first word too wide) nothing was drawn at all while the suggestion
    /// stayed live, so ⌥⇥ on an iPad keyboard inserted a completion that had
    /// never been on screen.
    var acceptableSuggestionText: String? {
        guard let suggestion = inlineSuggestion, let document else { return nil }
        guard let position = position(from: beginningOfDocument, offset: suggestion.location)
        else { return suggestion.text }
        let caret = caretRect(for: position)
        // No geometry yet — an unlaid-out view, or a caret rect UIKit will not
        // give up. Nothing can be *drawn*, but nothing has been hidden from the
        // user either, so accepting still means the whole suggestion. Only a
        // measured line can shorten it.
        guard caret.origin.x.isFinite, caret.origin.y.isFinite, caret.height > 0,
              bounds.width > 0
        else { return suggestion.text }
        let available = bounds.width - caret.maxX
            - textContainerInset.right - textContainer.lineFragmentPadding
        guard available > 12 else { return nil }
        let drawn = suggestion.text.fittingWidth(available, attributes: ghostAttributes(document))
        return drawn.isEmpty ? nil : drawn
    }

    // MARK: - Accepting

    /// Insert the suggestion at the caret. The **only** path from ghost text to
    /// the document, through `performEdit` — the same undoable route typing
    /// takes, so an accepted completion is indistinguishable from text the user
    /// wrote, because by then it is.
    @discardableResult
    public func acceptInlineSuggestion() -> Bool {
        guard let suggestion = inlineSuggestion,
              // Exactly what is on screen — never more, and nothing at all when
              // nothing was drawn. See `acceptableSuggestionText`.
              let text = acceptableSuggestionText else {
            clearInlineSuggestion()
            return false
        }
        clearInlineSuggestion()
        return performEdit(replacing: NSRange(location: suggestion.location, length: 0),
                           with: text)
    }

    /// A tap lands on the ghost: accept it, and report that the tap is spent so
    /// the caret is not moved as well.
    func acceptInlineSuggestion(ifTappedAt point: CGPoint) -> Bool {
        guard let frame = inlineSuggestionRect() else { return false }
        // Generously, vertically: the ghost is one line of text and a fingertip
        // is not.
        guard frame.insetBy(dx: -4, dy: -8).contains(point) else { return false }
        return acceptInlineSuggestion()
    }

    @objc func acceptInlineSuggestionCommand(_ sender: Any?) { acceptInlineSuggestion() }
    @objc func dismissInlineSuggestionCommand(_ sender: Any?) { clearInlineSuggestion() }

    // MARK: - Requesting

    /// Ask the host for a completion at the caret, if one could be shown here.
    func requestInlineCompletion() {
        guard isEditable, let onInlineCompletionRequest else { return }
        let selection = selectedRange
        guard selection.length == 0, canOfferSuggestion(at: selection.location) else {
            clearInlineSuggestion()
            return
        }
        let ns = (text ?? "") as NSString
        let budget = 1_200
        let start = max(0, selection.location - budget)
        let after = min(ns.length - selection.location, 400)
        onInlineCompletionRequest(InlineCompletionContext(
            location: selection.location,
            prefix: ns.substring(with: NSRange(location: start, length: selection.location - start)),
            suffix: ns.substring(with: NSRange(location: selection.location, length: after))))
    }
}

private extension String {
    /// The longest prefix of this string that fits `width`, cut at a word
    /// boundary. Empty when even the first word doesn't fit.
    func fittingWidth(_ width: CGFloat, attributes: [NSAttributedString.Key: Any]) -> String {
        guard width > 0 else { return "" }
        if (self as NSString).size(withAttributes: attributes).width <= width { return self }

        var candidate = ""
        var result = ""
        for piece in split(separator: " ", omittingEmptySubsequences: false) {
            candidate += (candidate.isEmpty ? "" : " ") + piece
            if (candidate as NSString).size(withAttributes: attributes).width > width { break }
            result = candidate
        }
        return result
    }
}
#endif
