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
    /// A UIKit `inputAccessoryView`, not a SwiftUI `ToolbarItemGroup(placement:
    /// .keyboard)`. The SwiftUI form was tried first and simply never appeared:
    /// SwiftUI hangs a keyboard toolbar off the responder *it* manages, and the
    /// first responder here is a `UITextView` inside a `UIViewRepresentable`,
    /// which it does not. The bar is owned by the view whose keyboard it sits
    /// on, so it also needs no bus to reach the text.
    ///
    /// `lazy`, like the other view-owned properties here — see `chromeOverlay`.
    private lazy var formatAccessory: UIView = makeFormatAccessory()

    private func makeFormatAccessory() -> UIView {
        let bar = FormatAccessoryView(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.autoresizingMask = .flexibleWidth
        bar.configure(
            commands: [
                ("bold", "Bold", .bold),
                ("italic", "Italic", .italic),
                ("strikethrough", "Strikethrough", .strikethrough),
                ("highlighter", "Highlight", .highlight),
                ("chevron.left.forwardslash.chevron.right", "Code", .inlineCode),
                ("text.quote", "Blockquote", .blockquote),
                ("list.bullet", "Bulleted List", .unorderedList),
                ("list.number", "Numbered List", .orderedList),
                ("1.square", "Heading 1", .heading(1)),
                ("2.square", "Heading 2", .heading(2)),
                ("3.square", "Heading 3", .heading(3)),
            ],
            apply: { [weak self] command in self?.apply(command) },
            undo: { [weak self] in self?.undoManager?.undo() },
            redo: { [weak self] in self?.undoManager?.redo() },
            dismiss: { [weak self] in self?.resignFirstResponder() })
        bar.sizeToFit()
        return bar
    }

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
        contentStorage.textStorage = document.storage
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.textContainer = container

        let tv = MarkdownUITextView(frame: .zero, textContainer: container)
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
        tv.spellCheckingType = .default
        tv.keyboardDismissMode = .interactive
        tv.inputAccessoryView = tv.formatAccessory

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
        if width > 0 { document.renderMaxWidth = min(width, 900) }
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

    private var caretIsAtStart: Bool {
        selectedRange.length == 0 && selectedRange.location == 0
    }

    private var caretIsOnFirstLine: Bool {
        guard selectedRange.length == 0 else { return false }
        if selectedRange.location == 0 { return true }
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
        guard let position = position(from: beginningOfDocument, offset: selectedRange.location)
        else { return false }
        let here = caretRect(for: position)
        let start = caretRect(for: beginningOfDocument)
        guard here.minY.isFinite, start.minY.isFinite else { return false }
        return abs(here.minY - start.minY) < 0.5
    }

    /// Where the caret sits horizontally, in points from the text's left edge —
    /// so the column survives the different inset and font above the seam.
    private var caretXOffset: CGFloat {
        guard let position = position(from: beginningOfDocument, offset: selectedRange.location)
        else { return 0 }
        return caretRect(for: position).minX - textContainerInset.left - textContainer.lineFragmentPadding
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
        let firstLineY = tv.caretRect(for: tv.beginningOfDocument).midY
        let point = CGPoint(x: inset + max(0, x), y: firstLineY)
        let location = tv.closestPosition(to: point).map {
            tv.offset(from: tv.beginningOfDocument, to: $0)
        } ?? 0
        let range = NSRange(location: location, length: 0)
        tv.selectedRange = range
        tv.document?.selectionDidChange(range)
        tv.scrollRangeToVisible(range)
    }

    /// The caret arrived from above with no column to honour.
    public func focusStart() { focusFirstLine(atX: 0) }

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
}


/// The formatting bar above the keyboard.
///
/// A scrolling row of evenly weighted buttons, not a `UIToolbar`. The toolbar
/// version spread seven items across the width with a flexible space, so the
/// spacing changed with the device, nothing was grouped, and there was no room
/// for a twelfth command without crowding the rest. Scrolling decouples the
/// number of commands from the width of the screen, which is the property that
/// makes a bar like this work on a phone and an iPad alike.
///
/// Undo, redo and dismiss are pinned outside the scroll view: they are the
/// controls you reach for without looking, so they must not move.
final class FormatAccessoryView: UIView {

    private let scroller = UIScrollView()
    private let row = UIStackView()
    private let fixed = UIStackView()

    func configure(commands: [(String, String, EditorFormatCommand)],
                   apply: @escaping (EditorFormatCommand) -> Void,
                   undo: @escaping () -> Void,
                   redo: @escaping () -> Void,
                   dismiss: @escaping () -> Void) {
        backgroundColor = .secondarySystemBackground

        func button(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> UIButton {
            var config = UIButton.Configuration.plain()
            config.image = UIImage(systemName: symbol,
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 17,
                                                                                  weight: .regular))
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
            let b = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
            b.accessibilityLabel = label
            b.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            return b
        }

        row.axis = .horizontal
        for (symbol, label, command) in commands {
            row.addArrangedSubview(button(symbol, label) { apply(command) })
        }

        scroller.showsHorizontalScrollIndicator = false
        scroller.addSubview(row)

        fixed.axis = .horizontal
        fixed.addArrangedSubview(button("arrow.uturn.backward", "Undo", undo))
        fixed.addArrangedSubview(button("arrow.uturn.forward", "Redo", redo))
        fixed.addArrangedSubview(button("keyboard.chevron.compact.down", "Hide Keyboard", dismiss))

        for v in [scroller, row, fixed] { v.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(scroller)
        addSubview(fixed)

        NSLayoutConstraint.activate([
            scroller.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroller.topAnchor.constraint(equalTo: topAnchor),
            scroller.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroller.trailingAnchor.constraint(equalTo: fixed.leadingAnchor),

            row.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor),

            fixed.trailingAnchor.constraint(equalTo: trailingAnchor),
            fixed.topAnchor.constraint(equalTo: topAnchor),
            fixed.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 44)
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
            DispatchQueue.main.async { tv?.requestInlineCompletion() }
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

extension MarkdownUITextView: MarkdownFormatting {

    public var formattingText: String { text ?? "" }
    public func formattingSelection() -> NSRange { selectedRange }
    public func setFormattingSelection(_ range: NSRange) { selectedRange = range }

    /// Replace `range` with `text`, undoably.
    ///
    /// `replace(_:withText:)` rather than poking `textStorage`: it is the
    /// `UITextInput` path, so it registers undo, notifies the delegate, and
    /// therefore reaches the document's incremental reparse — the same route a
    /// keystroke takes. Writing to the storage directly would format the text
    /// and leave the parse, the undo stack and the delegate all behind.
    @discardableResult
    public func performEdit(replacing range: NSRange, with text: String) -> Bool {
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let textRange = textRange(from: start, to: end)
        else { return false }
        replace(textRange, withText: text)
        selectedRange = NSRange(location: range.location + (text as NSString).length, length: 0)
        return true
    }
}


#endif
