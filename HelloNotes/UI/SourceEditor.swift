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
import MarkdownCore
import MarkdownEditor

#if canImport(AppKit)
/// Plain, unstyled, substitution-free source editing.
/// A plain `NSTextView` the formatting commands can act on — the Mac half of
/// the same promise: the bar is shown in every editable mode, so every editable
/// mode has to honour it. See `SourceTextView` in the UIKit branch.
final class SourceTextView: NSTextView, MarkdownFormatting {

    /// No parsed model here — this view shows raw Markdown and highlights it.
    /// The jump falls back to a line scan off the main actor.
    var formattingBlocks: [Block]? { nil }
    var formattingText: String { string }
    func formattingSelection() -> NSRange { selectedRange() }
    func setFormattingSelection(_ range: NSRange) { setSelectedRange(range) }

    /// The View diagram buttons on this view's diagrams, placed again whenever
    /// it lays out. Owned by the coordinator.
    weak var diagramButtons: SourceDiagramButtons?

    override func layout() {
        super.layout()
        diagramButtons?.place()
    }

    /// Heading jumps addressed to this pane's editor: shown when the view is in
    /// a window — at once, or when it gets there (`HeadingJumpListener`).
    lazy var headingJumps = HeadingJumpListener(
        isReady: { [weak self] in self?.window != nil },
        show: { [weak self] jump in self?.scanToHeading(ordinal: jump.ordinal) })

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        headingJumps.surfaceBecameReady()
    }

    @discardableResult
    func performEdit(replacing range: NSRange, with replacement: String) -> Bool {
        // `shouldChangeText` / `didChangeText` is the pair that registers undo
        // and tells the delegate, which is what carries the edit back into the
        // note's binding. Writing the storage directly would do neither.
        guard shouldChangeText(in: range, replacementString: replacement) else { return false }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + (replacement as NSString).length,
                                 length: 0))
        return true
    }
}

struct SourceEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    /// The editor this pane belongs to (`EditorModel.editorID`), so commands
    /// addressed to it on the bus — and only those — reach this view.
    var editorID: String
    /// A diagram's View diagram button was pressed (`SourceDiagramButtons`).
    var onDiagramZoom: (DiagramZoom) -> Void = { _ in }
    /// Editing stopped — the text view gave up first responder: a click in
    /// the sidebar, another pane, the title. The save signal, as the live
    /// editor's `onEndEditing` is in Edit mode.
    var onEndEditing: () -> Void = {}

    /// S1: report the size offered, never the size contained — a text view's
    /// `fittingSize` is the whole document, which inflates every ancestor until
    /// the top of the note sits above the window.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView,
                      context: Context) -> CGSize? {
        viewportSizeThatFits(proposal)
    }

    /// The scroll view and source text view, built as the pane shows them —
    /// one place, so a test holds the same view the app does.
    static func scrollableSourceView(fontSize: CGFloat) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        // Swap in our own text view so it can conform to `MarkdownFormatting`.
        // `scrollableTextView()` builds the whole stack correctly — container,
        // layout manager, autoresizing — so the cheapest correct move is to
        // take its text view's container and hand it to ours.
        if let stock = scroll.documentView as? NSTextView,
           let container = stock.textContainer {
            let ours = SourceTextView(frame: stock.frame, textContainer: container)
            ours.autoresizingMask = stock.autoresizingMask
            ours.minSize = stock.minSize
            ours.maxSize = stock.maxSize
            ours.isVerticallyResizable = stock.isVerticallyResizable
            ours.isHorizontallyResizable = stock.isHorizontallyResizable
            ours.isEditable = true
            ours.allowsUndo = true
            scroll.documentView = ours
        }
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.drawsBackground = false
        scroll.drawsBackground = false
        tv.textContainerInset = NSSize(width: 4, height: 8)
        Self.makeSourceOnly(tv)
        tv.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return scroll
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = Self.scrollableSourceView(fontSize: fontSize)
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.string = text
        context.coordinator.shown = text
        context.coordinator.onEndEditing = onEndEditing
        let buttons = SourceDiagramButtons(textView: tv)
        buttons.onPress = onDiagramZoom
        context.coordinator.diagramButtons = buttons
        (tv as? SourceTextView)?.diagramButtons = buttons
        buttons.textDidChange()
        // Scrolling changes which diagrams are in the viewport, and on AppKit it
        // is not a layout of the text view.
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.placeButtonsOnScroll(of: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let tv = scroll.documentView as? SourceTextView {
            context.coordinator.subscribe(editorID: editorID, view: tv)
        }
        // The coordinator is made once per view *identity*, and this view's
        // identity does not change when the active tab does — nothing between
        // `ContentView` and here carries an `.id(…)`. The binding, however, is
        // rebuilt every body pass around whichever `EditorModel` is active, so
        // a coordinator holding the one it was born with writes the visible
        // note's text into the previously active note's model, and the debounce
        // saves it over that note's file. Re-seat it, exactly as
        // `InlineTitleField` does.
        context.coordinator.text = $text
        context.coordinator.onEndEditing = onEndEditing
        context.coordinator.diagramButtons?.onPress = onDiagramZoom
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.font?.pointSize != fontSize {
            tv.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        // Only when it actually differs: assigning `string` resets the
        // selection, so echoing the user's own keystroke back would move the
        // caret to the end of the document on every character. Found out
        // without reading the view — see `Coordinator.differs`.
        if context.coordinator.differs(from: text, in: tv) {
            let selection = tv.selectedRange()
            tv.string = text
            let length = (text as NSString).length
            tv.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            context.coordinator.diagramButtons?.textDidChange()
        }
        context.coordinator.shown = text
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
        /// Re-seated by `updateNSView` on every body pass — see the note there.
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        /// The text the view shows, as the string the binding last saw — kept
        /// by typing (`textDidChange`) and by `updateNSView` replacing it.
        var shown: String?

        /// Whether `text` is not what the view shows.
        ///
        /// It asked `tv.string != text`: a copy of the note and a comparison of
        /// two bridged strings, on the main actor, on every keystroke — the
        /// binding writes through, so each character comes straight back here.
        /// That echo is the very string the view handed over, which `!=`
        /// answers from the two strings' storage without reading a character.
        func differs(from text: String, in view: NSTextView) -> Bool {
            guard let shown else { return view.string != text }
            return shown != text
        }

        /// The View diagram buttons on this view's diagrams.
        var diagramButtons: SourceDiagramButtons?
        private var scrollToken: NSObjectProtocol?

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let typed = tv.string
            shown = typed
            text.wrappedValue = typed
            diagramButtons?.textDidChange()
        }

        /// Re-seated by `updateNSView` with `text`, for the same reason.
        var onEndEditing: () -> Void = {}

        /// The pane's half of the save signal: editing stopped. A keystroke
        /// writes nothing (`EditorModel.scheduleSave`), so without this what
        /// was typed here waited for the next flush.
        func textDidEndEditing(_ notification: Notification) {
            onEndEditing()
        }

        /// Place the buttons again after `clip` scrolls — on the next turn,
        /// once TextKit has laid out the viewport it scrolled to.
        func placeButtonsOnScroll(of clip: NSClipView) {
            scrollToken = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.diagramButtons?.place() }
                }
            }
        }

        // MARK: - The formatting bus

        private var busEditorID: String?
        private var busTokens: [NSObjectProtocol] = []
        private weak var busView: SourceTextView?

        /// The same subscriptions the live editor's coordinator makes, so the
        /// Format menu and the toolbar work in Markdown and Split too.
        func subscribe(editorID: String, view: SourceTextView) {
            busView = view
            // Heading jumps are the view's own to answer, because only the
            // view knows when it can (`HeadingJumpListener`). Markdown and
            // Split had no listener at all once, which is why the outline did
            // nothing in either.
            view.headingJumps.editorID = editorID
            guard busEditorID != editorID else { return }
            let centre = NotificationCenter.default
            for token in busTokens { centre.removeObserver(token) }
            busTokens.removeAll()
            busEditorID = editorID

            let formats: [(String, EditorFormatCommand)] = [
                ("bold", .bold), ("italic", .italic), ("strikethrough", .strikethrough),
                ("highlight", .highlight), ("inlineCode", .inlineCode),
                ("blockquote", .blockquote), ("unorderedList", .unorderedList),
                ("orderedList", .orderedList),
            ]
            for (kind, command) in formats {
                busTokens.append(centre.addObserver(
                    forName: EditorBus.format(kind, editor: editorID),
                    object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.busView?.apply(command) }
                })
            }
            busTokens.append(centre.addObserver(
                forName: EditorBus.format("heading", editor: editorID),
                object: nil, queue: .main
            ) { [weak self] note in
                let level = note.userInfo?["level"] as? Int ?? 1
                MainActor.assumeIsolated { [level] in self?.busView?.apply(.heading(level)) }
            })
        }

        deinit {
            let centre = NotificationCenter.default
            for token in busTokens { centre.removeObserver(token) }
            if let scrollToken { centre.removeObserver(scrollToken) }
        }
    }
}
#else
/// Plain, unstyled, substitution-free source editing.
/// A plain `UITextView` that the formatting commands can act on.
///
/// The bar is app chrome now and it is shown in **every editable mode** —
/// Edit, Markdown and Split — because all three are editing. That makes a
/// promise this type has to keep: a visible button that does nothing is worse
/// than no button. `MarkdownFormatting` needs only the text, the selection and
/// an undoable replace, so the raw-source editor can honour exactly the same
/// commands as the live one, with one implementation of what "toggle a
/// heading" means.
final class SourceTextView: UITextView, MarkdownFormatting {

    /// No parsed model here — this view shows raw Markdown and highlights it.
    /// The jump falls back to a line scan off the main actor.
    var formattingBlocks: [Block]? { nil }
    var formattingText: String { text ?? "" }
    func formattingSelection() -> NSRange { selectedRange }
    func setFormattingSelection(_ range: NSRange) { selectedRange = range }

    /// The View diagram buttons on this view's diagrams, placed again whenever
    /// it lays out — which a scroll view does on every scroll. Owned by the
    /// coordinator.
    weak var diagramButtons: SourceDiagramButtons?

    /// Heading jumps addressed to this pane's editor: shown when the view is in
    /// a window — at once, or when it gets there (`HeadingJumpListener`).
    lazy var headingJumps = HeadingJumpListener(
        isReady: { [weak self] in self?.window != nil },
        show: { [weak self] jump in self?.scanToHeading(ordinal: jump.ordinal) })

    override func didMoveToWindow() {
        super.didMoveToWindow()
        headingJumps.surfaceBecameReady()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        diagramButtons?.place()
    }

    @discardableResult
    func performEdit(replacing range: NSRange, with replacement: String) -> Bool {
        // Through `UITextInput`, not `textStorage`: this is the path a
        // keystroke takes, so it registers undo with the view's own manager and
        // notifies the delegate — which is what pushes the change back into the
        // note's binding. Writing storage directly would edit the text and lose
        // both.
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let target = textRange(from: start, to: end) else { return false }
        replace(target, withText: replacement)
        return true
    }
}

struct SourceEditor: UIViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    /// The editor this pane belongs to (`EditorModel.editorID`), so commands
    /// addressed to it on the shared bus reach this view — the same address the
    /// live editor answers to, never the note's: two editors can show one note.
    var editorID: String
    /// A diagram's View diagram button was pressed (`SourceDiagramButtons`).
    var onDiagramZoom: (DiagramZoom) -> Void = { _ in }
    /// Editing stopped — the text view gave up first responder: the keyboard
    /// dismissed, a tap in the sidebar or another pane. The save signal, as
    /// the live editor's `onEndEditing` is in Edit mode.
    var onEndEditing: () -> Void = {}

    /// S1: report the size offered, never the size contained. A `UITextView`'s
    /// `fittingSize` is the whole document, which inflates every ancestor until
    /// the top of the note sits above the window. See docs/layout-architecture.md.
    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: SourceTextView,
                      context: Context) -> CGSize? {
        viewportSizeThatFits(proposal)
    }

    /// The source text view, built as the pane shows it — one place, so a
    /// test holds the same view the app does.
    static func sourceTextView(fontSize: CGFloat) -> SourceTextView {
        let tv = SourceTextView()
        tv.backgroundColor = .clear
        tv.alwaysBounceVertical = true
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        SourceEditor.makeSourceOnly(tv)
        tv.keyboardDismissMode = .interactive
        // The same formatting affordances the live editor installs, so the
        // shortcuts bar is the same in Markdown and Split as it is in Edit.
        tv.installFormattingAssistant()
        tv.isFindInteractionEnabled = true
        tv.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return tv
    }

    func makeUIView(context: Context) -> SourceTextView {
        let tv = Self.sourceTextView(fontSize: fontSize)
        tv.delegate = context.coordinator
        tv.text = text
        context.coordinator.shown = text
        context.coordinator.onEndEditing = onEndEditing
        let buttons = SourceDiagramButtons(textView: tv)
        buttons.onPress = onDiagramZoom
        context.coordinator.diagramButtons = buttons
        tv.diagramButtons = buttons
        buttons.textDidChange()
        return tv
    }

    func updateUIView(_ tv: SourceTextView, context: Context) {
        context.coordinator.subscribe(editorID: editorID, view: tv)
        // The coordinator is made once per view *identity*, and this view's
        // identity does not change when the active tab does — nothing between
        // `ContentView` and here carries an `.id(…)`. The binding, however, is
        // rebuilt every body pass around whichever `EditorModel` is active, so
        // a coordinator holding the one it was born with writes the visible
        // note's text into the previously active note's model, and the debounce
        // saves it over that note's file. Re-seat it, exactly as
        // `InlineTitleField` does.
        context.coordinator.text = $text
        context.coordinator.onEndEditing = onEndEditing
        context.coordinator.diagramButtons?.onPress = onDiagramZoom
        if tv.font?.pointSize != fontSize {
            tv.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        // Only when it actually differs: assigning `text` resets the selection,
        // so echoing the user's own keystroke back would move the caret to the
        // end of the document on every character. Found out without reading
        // the view — see `Coordinator.differs`.
        if context.coordinator.differs(from: text, in: tv) {
            let selection = tv.selectedRange
            tv.text = text
            tv.selectedRange = NSRange(location: min(selection.location, (text as NSString).length),
                                       length: 0)
            context.coordinator.diagramButtons?.textDidChange()
        }
        context.coordinator.shown = text
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
        /// Re-seated by `updateUIView` on every body pass — see the note there.
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        /// The text the view shows, as the string the binding last saw — kept
        /// by typing (`textViewDidChange`) and by `updateUIView` replacing it.
        var shown: String?

        /// Whether `text` is not what the view shows.
        ///
        /// It asked `tv.text != text`: a copy of the note and a comparison of
        /// two bridged strings, on the main actor, on every keystroke — the
        /// binding writes through, so each character comes straight back here.
        /// That echo is the very string the view handed over, which `!=`
        /// answers from the two strings' storage without reading a character.
        func differs(from text: String, in view: UITextView) -> Bool {
            guard let shown else { return view.text != text }
            return shown != text
        }

        /// The View diagram buttons on this view's diagrams.
        var diagramButtons: SourceDiagramButtons?

        func textViewDidChange(_ textView: UITextView) {
            let typed: String = textView.text
            shown = typed
            text.wrappedValue = typed
            diagramButtons?.textDidChange()
        }

        /// Re-seated by `updateUIView` with `text`, for the same reason.
        var onEndEditing: () -> Void = {}

        /// The pane's half of the save signal: editing stopped. A keystroke
        /// writes nothing (`EditorModel.scheduleSave`), so without this what
        /// was typed here waited for the next flush.
        func textViewDidEndEditing(_ textView: UITextView) {
            onEndEditing()
        }

        // MARK: - The formatting bus

        private var busEditorID: String?
        private var busTokens: [NSObjectProtocol] = []
        private weak var busView: SourceTextView?

        /// Listen for formatting sent from outside this view — the Mac's
        /// Format menu, and anything else on the bus. The shortcuts-bar buttons
        /// call `apply` directly (they are installed on this very text view),
        /// so this is the *other* half: commands addressed to the editor rather
        /// than to a view.
        func subscribe(editorID: String, view: SourceTextView) {
            busView = view
            // Heading jumps are the view's own to answer, because only the
            // view knows when it can (`HeadingJumpListener`). Markdown and
            // Split had no listener at all once, which is why the outline did
            // nothing in either.
            view.headingJumps.editorID = editorID
            guard busEditorID != editorID else { return }
            let centre = NotificationCenter.default
            for token in busTokens { centre.removeObserver(token) }
            busTokens.removeAll()
            busEditorID = editorID

            let formats: [(String, EditorFormatCommand)] = [
                ("bold", .bold), ("italic", .italic), ("strikethrough", .strikethrough),
                ("highlight", .highlight), ("inlineCode", .inlineCode),
                ("blockquote", .blockquote), ("unorderedList", .unorderedList),
                ("orderedList", .orderedList),
            ]
            for (kind, command) in formats {
                busTokens.append(centre.addObserver(
                    forName: EditorBus.format(kind, editor: editorID),
                    object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.busView?.apply(command) }
                })
            }
            busTokens.append(centre.addObserver(
                forName: EditorBus.format("heading", editor: editorID),
                object: nil, queue: .main
            ) { [weak self] note in
                let level = note.userInfo?["level"] as? Int ?? 1
                MainActor.assumeIsolated { [level] in self?.busView?.apply(.heading(level)) }
            })
            busTokens.append(centre.addObserver(
                forName: EditorBus.undo(editor: editorID),
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.busView?.undoManager?.undo() }
            })
            busTokens.append(centre.addObserver(
                forName: EditorBus.redo(editor: editorID),
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.busView?.undoManager?.redo() }
            })
            busTokens.append(centre.addObserver(
                forName: EditorBus.endEditing(editor: editorID),
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.busView?.resignFirstResponder() }
            })
        }

        deinit {
            let centre = NotificationCenter.default
            for token in busTokens { centre.removeObserver(token) }
        }
    }
}
#endif

extension SourceTextView {
    /// Go to the `ordinal`-th heading of what this pane shows.
    ///
    /// **The scan is off the main actor.** This pane keeps no parse, so finding
    /// the n-th heading means reading the text — one pass, on an explicit jump,
    /// never while typing, and never on this actor. The offset is true of the
    /// text it was measured from, so it is used only if that is still the text.
    func scanToHeading(ordinal: Int) {
        let text = formattingText
        Task {
            let offset = await offMain { SourceHeadingScan.offset(ofHeading: ordinal, in: text) }
            guard let offset else { return }
            await MainActor.run { [weak self] in
                guard let self, self.window != nil, self.formattingText == text else { return }
                self.showHeading(at: offset)
            }
        }
    }
}
