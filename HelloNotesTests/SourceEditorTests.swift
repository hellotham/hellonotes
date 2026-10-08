//
//  SourceEditorTests.swift
//  HelloNotesTests
//
//  Markdown mode must not rewrite what you type — on either platform.
//
//  A silent corruption, which is why it wants a test rather than a comment.
//  Markdown mode shows the note's literal source; the system's typographic
//  substitutions turn `---` under a table header into an em dash and `"` into a
//  curly quote, and the file on disk then holds characters no Markdown parser
//  recognises. The table stops being a table and nothing says so.
//
//  iOS found it and fixed its own copy of the view. macOS kept SwiftUI's
//  `TextEditor`, whose `NSTextView` follows the user's system settings — the
//  same corruption, on the platform where a hand-written table is most likely to
//  live. `makeSourceOnly` is the fix, named so it can be asserted rather than
//  read.
//

import Testing
import SwiftUI
@testable import HelloNotes
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@MainActor
struct SourceEditorTests {

    @Test func theSourceEditorNeverSubstitutesTypography() {
        #if canImport(AppKit)
        // A text view configured the way the *system* would leave it, so the
        // test fails if `makeSourceOnly` stops being applied rather than
        // passing on a view that happened to default correctly.
        let view = NSTextView()
        view.isAutomaticDashSubstitutionEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = true
        view.isAutomaticTextReplacementEnabled = true
        view.isAutomaticSpellingCorrectionEnabled = true
        view.isRichText = true

        SourceEditor.makeSourceOnly(view)

        #expect(view.isAutomaticDashSubstitutionEnabled == false,
                "`---` under a table header becomes an em dash")
        #expect(view.isAutomaticQuoteSubstitutionEnabled == false,
                "a curly quote stops closing a fence")
        #expect(view.isAutomaticTextReplacementEnabled == false)
        #expect(view.isAutomaticSpellingCorrectionEnabled == false)
        #expect(view.isContinuousSpellCheckingEnabled == false)
        #expect(view.isRichText == false, "source is plain text or it is not source")
        #else
        let view = UITextView()
        view.smartDashesType = .yes
        view.smartQuotesType = .yes
        view.smartInsertDeleteType = .yes
        view.autocorrectionType = .yes

        SourceEditor.makeSourceOnly(view)

        #expect(view.smartDashesType == .no,
                "`---` under a table header becomes an em dash")
        #expect(view.smartQuotesType == .no,
                "a curly quote stops closing a fence")
        #expect(view.smartInsertDeleteType == .no)
        #expect(view.autocorrectionType == .no)
        #expect(view.spellCheckingType == .no)
        #endif
    }

    /// Markdown mode writes the buffer on every keystroke, and each one comes
    /// straight back through the binding. The pane knows that echo without
    /// reading its view — which was a copy of the note and a comparison of two
    /// bridged strings, per keystroke — and still sees a change made elsewhere.
    @Test func theEchoOfAKeystrokeIsKnownWithoutReadingTheView() {
        var buffer = "# Log\n\nAs it was.\n"
        let coordinator = SourceEditor.Coordinator(text: Binding(get: { buffer }, set: { buffer = $0 }))
        let view = CountingTextView()
        Self.show(buffer, in: view)
        coordinator.shown = buffer

        // A keystroke: the view hands its text over, reading itself once.
        Self.show("# Log\n\nAs it was. Typed.\n", in: view)
        view.reads = 0
        Self.type(in: view, to: coordinator)
        #expect(view.reads == 1 && buffer == "# Log\n\nAs it was. Typed.\n")

        // It comes back through the binding: the same string, known as such.
        #expect(!coordinator.differs(from: buffer, in: view), "its own keystroke read as a change")
        #expect(view.reads == 1, "recognising the echo read the view")

        // A change made elsewhere — a tag, a property — is still a change.
        buffer = "# Log\n\nChanged elsewhere.\n"
        #expect(coordinator.differs(from: buffer, in: view), "a change from outside went unseen")

        // The control: with nothing known, the answer comes from the view, and
        // the count sees it — so the reads above were counted, not missed.
        coordinator.shown = nil
        #expect(coordinator.differs(from: buffer, in: view))
        #expect(view.reads == 2, "a read of the view went uncounted, so the counts above prove nothing")
    }

    #if canImport(AppKit)
    /// A source view that counts reads of its text.
    private final class CountingTextView: NSTextView {
        var reads = 0
        override var string: String {
            get { reads += 1; return super.string }
            set { super.string = newValue }
        }
    }

    private static func show(_ text: String, in view: CountingTextView) { view.string = text }

    private static func type(in view: CountingTextView, to coordinator: SourceEditor.Coordinator) {
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
    }
    #else
    /// A source view that counts reads of its text.
    private final class CountingTextView: UITextView {
        var reads = 0
        override var text: String! {
            get { reads += 1; return super.text }
            set { super.text = newValue }
        }
    }

    private static func show(_ text: String, in view: CountingTextView) { view.text = text }

    private static func type(in view: CountingTextView, to coordinator: SourceEditor.Coordinator) {
        coordinator.textViewDidChange(view)
    }
    #endif
}
