//
//  ReadingPositionTests.swift
//  MarkdownEditorTests
//
//  A note comes back where it was left (`ReadingPosition.swift`). The iOS
//  view is made new for each document and opened at the top; the Mac's is
//  bound to the next note and kept the last one's offset. The document keeps
//  the character at the top of the view, and a view showing it again puts
//  that character back at the top.
//

import Foundation
import Testing
@testable import MarkdownEditor

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@MainActor
@Suite struct ReadingPositionTests {

    /// Sixty one-line paragraphs: several screens of a long note.
    static func note(_ word: String = "Paragraph") -> String {
        (0..<60).map { "\(word) \($0), one line of a long note." }.joined(separator: "\n\n")
    }
    static let size = CGSize(width: 600, height: 626)

    private func offset(of needle: String, in text: String) -> Int {
        (text as NSString).range(of: needle).location
    }

    /// Make the paragraph holding `needle` taller, as a restyle does — a
    /// heading given its size, a table drawn — and say so, as the document does.
    private func grow(_ needle: String, in document: EditorDocument, text: String) {
        let range = (text as NSString).paragraphRange(for: NSRange(location: offset(of: needle, in: text), length: 0))
        #if canImport(AppKit)
        let font = NSFont.systemFont(ofSize: 72)
        #else
        let font = UIFont.systemFont(ofSize: 72)
        #endif
        document.storage.addAttribute(.font, value: font, range: range)
        document.onRestyle?(range)
    }

    #if !canImport(AppKit)

    /// A view for `document` in a window of its own, laid out.
    private func view(for document: EditorDocument) -> (MarkdownUITextView, UIWindow) {
        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.size))
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        let textView = MarkdownUITextView.make(document: document)
        textView.frame = controller.view.bounds
        controller.view.addSubview(textView)
        controller.view.layoutIfNeeded()
        textView.layoutIfNeeded()
        return (textView, window)
    }

    /// Scroll so the line starting at `location` stands at the top, as the
    /// view itself does when it puts a place back.
    private func place(_ location: Int, atTopOf textView: MarkdownUITextView) {
        textView.standAtTop(location)
        textView.layoutIfNeeded()
    }

    @Test func aViewMadeForTheDocumentAgainPutsItsPlaceBack() throws {
        let text = Self.note()
        let document = EditorDocument(text: text)
        let thirtieth = offset(of: "Paragraph 30", in: text)

        let (first, firstWindow) = view(for: document)
        place(thirtieth, atTopOf: first)
        #expect(first.topVisibleCharacter == thirtieth, "the view does not stand where it was put")
        first.removeFromSuperview()          // going keeps the place
        firstWindow.isHidden = true
        #expect(document.readingPosition == thirtieth)

        let (second, secondWindow) = view(for: document)
        defer { secondWindow.isHidden = true }
        #expect(second.topVisibleCharacter == thirtieth,
                "a new view for the document opened at \(second.topVisibleCharacter ?? 0), not \(thirtieth)")
    }

    /// **A place put back stays put while what is above it changes.** A note
    /// is styled in batches after it is shown, and its tables and diagrams are
    /// drawn as they arrive: held at its offset, the place drifted ten lines in
    /// the iPhone simulator, and the drifted place was the one kept
    /// (implemented.md §51.69). Until the reader moves. The control: once the
    /// reader has taken over, the same change moves what is at the top.
    @Test func aPlacePutBackStaysWhileWhatIsAboveItChanges() throws {
        let standing = growAbovePlace(afterTakingOver: false)
        #expect(standing.top == standing.place,
                "the place moved when the text above it grew: top \(standing.top ?? 0), not \(standing.place)")
        #expect(standing.kept == standing.place, "a record while the place stood kept another")
        let moved = growAbovePlace(afterTakingOver: true)
        #expect(moved.top != moved.place, "the control: a change above moved nothing, so this test cannot see a drift")
    }

    /// The fortieth paragraph put back at the top of a new view, the reader
    /// taking over or not, then the fifth — above it — grown as a restyle
    /// grows it: what is at the top afterwards, what a record keeps, and the
    /// place.
    private func growAbovePlace(afterTakingOver takingOver: Bool) -> (top: Int?, kept: Int?, place: Int) {
        let text = Self.note()
        let document = EditorDocument(text: text)
        let place = offset(of: "Paragraph 40", in: text)
        document.readingPosition = place
        let (textView, window) = view(for: document)
        defer { window.isHidden = true }
        #expect(textView.topVisibleCharacter == place, "the place was not put back")
        if takingOver { textView.readerTookOver() }
        grow("Paragraph 5,", in: document, text: text)
        textView.layoutIfNeeded()
        let top = textView.topVisibleCharacter
        textView.recordReadingPosition()
        return (top, document.readingPosition, place)
    }

    /// **A range asked to be shown ends the standing place** — a match the find
    /// navigator found, the caret — or the next restyle would scroll away from
    /// it. The control: put back, the place stands.
    @Test func aRangeShownEndsTheStandingPlace() throws {
        let text = Self.note()
        let document = EditorDocument(text: text)
        document.readingPosition = offset(of: "Paragraph 40", in: text)
        let (textView, window) = view(for: document)
        defer { window.isHidden = true }
        #expect(textView.standingReadingPosition != nil, "the control: the place put back is not standing")
        textView.scrollRangeToVisible(NSRange(location: offset(of: "Paragraph 55", in: text), length: 0))
        #expect(textView.standingReadingPosition == nil, "the place still stood after a range was shown")
    }

    /// A view never laid out stands at the top: going, it must not say the
    /// reader was there.
    @Test func aViewNeverLaidOutLeavesThePlaceAlone() throws {
        let text = Self.note()
        let document = EditorDocument(text: text)
        document.readingPosition = offset(of: "Paragraph 30", in: text)
        let textView = MarkdownUITextView.make(document: document)
        textView.recordReadingPosition()
        #expect(document.readingPosition == offset(of: "Paragraph 30", in: text))
    }

    /// The outline's jump, a link to a heading: asked for, so it wins over a
    /// place still waiting to be put back.
    @Test func anExplicitScrollWinsOverAPlaceWaiting() throws {
        let text = Self.note()
        let document = EditorDocument(text: text)
        document.readingPosition = offset(of: "Paragraph 30", in: text)
        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.size))
        window.rootViewController = UIViewController()
        window.isHidden = false
        defer { window.isHidden = true }
        let textView = MarkdownUITextView.make(document: document)
        textView.frame = window.bounds
        window.rootViewController?.view.addSubview(textView)
        textView.reliablyScroll(to: NSRange(location: offset(of: "Paragraph 55", in: text), length: 0))
        textView.layoutIfNeeded()
        let top = try #require(textView.topVisibleCharacter)
        #expect(top > offset(of: "Paragraph 40", in: text),
                "the place waiting was put back over the scroll asked for: top \(top)")
    }

    /// **A heading jump wins over a place put back** — the outline, a link to
    /// a heading. The jump scrolled without saying so, and the next layout
    /// stood the old place back over it (implemented.md §51.72); a restyle
    /// above asks for that layout, as the note's styling does.
    @Test func aHeadingJumpWinsOverAPlacePutBack() throws {
        let text = Self.note()
        let document = EditorDocument(text: text)
        document.readingPosition = offset(of: "Paragraph 40", in: text)
        let (textView, window) = view(for: document)
        defer { window.isHidden = true }
        let heading = offset(of: "Paragraph 10,", in: text)
        textView.showHeading(at: heading)
        grow("Paragraph 2,", in: document, text: text)
        textView.layoutIfNeeded()
        #expect(textView.topVisibleCharacter == heading,
                "the place put back was stood over the jump: top \(textView.topVisibleCharacter ?? 0)")
    }

    /// **A heading jump asked for before the first layout is where the view
    /// opens** — a link to a heading in a note with a place kept.
    @Test func aHeadingJumpBeforeTheFirstLayoutIsWhereItOpens() throws {
        let text = Self.note()
        let document = EditorDocument(text: text)
        document.readingPosition = offset(of: "Paragraph 30", in: text)
        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.size))
        window.rootViewController = UIViewController()
        window.isHidden = false
        defer { window.isHidden = true }
        let textView = MarkdownUITextView.make(document: document)
        textView.frame = window.bounds
        window.rootViewController?.view.addSubview(textView)
        let heading = offset(of: "Paragraph 50,", in: text)
        textView.showHeading(at: heading)
        textView.layoutIfNeeded()
        #expect(textView.topVisibleCharacter == heading,
                "the view opened at \(textView.topVisibleCharacter ?? 0), not the heading asked for")
    }

    /// **A scroll the view did not make ends the standing place** — iOS's
    /// view: VoiceOver's three-finger scroll, a scroll to an element it
    /// focused. Re-applied at the next layout, they were taken back
    /// (implemented.md §51.72). The control: the view standing its own place
    /// keeps it standing.
    @Test func aScrollTheViewDidNotMakeEndsTheStandingPlace() throws {
        let text = Self.note()
        let document = EditorDocument(text: text)
        document.readingPosition = offset(of: "Paragraph 40", in: text)
        let (textView, window) = view(for: document)
        defer { window.isHidden = true }
        #expect(textView.standingReadingPosition != nil, "the place put back is not standing")
        textView.keepStandingIfPutBack()
        textView.offsetMoved()   // as the scroll view's delegate hears every scroll
        #expect(textView.standingReadingPosition != nil, "the control: the view's own standing ended it")
        let away = textView.contentOffset.y + 240
        textView.setContentOffset(CGPoint(x: 0, y: away), animated: false)
        textView.offsetMoved()
        textView.layoutIfNeeded()
        #expect(textView.standingReadingPosition == nil, "the place still stood after someone else scrolled")
        #expect(abs(textView.contentOffset.y - away) < 1, "the scroll was taken back to the place")
    }

    /// **A place past the end of a note shortened since stands at its last
    /// line** — another device, an edit outside the app, a pull. Past the end
    /// it was never stood, the view stayed where it was, and the place was
    /// kept again (implemented.md §51.72).
    @Test func aPlacePastTheEndStandsAtTheLastLine() throws {
        let text = Self.note()
        let document = EditorDocument(text: text)
        let length = (text as NSString).length
        document.readingPosition = length + 5_000
        let (textView, window) = view(for: document)
        defer { window.isHidden = true }
        let top = try #require(textView.topVisibleCharacter, "the view stayed at the top")
        #expect(top > offset(of: "Paragraph 40", in: text), "the view did not go to the note's end: top \(top)")
        textView.recordReadingPosition()
        #expect((document.readingPosition ?? 0) < length, "the place past the end was kept again")
    }

    #else

    /// A scrollable editor for `document` in a window of its own, laid out.
    private func editor(for document: EditorDocument) -> (MarkdownTextView, NSScrollView, NSWindow) {
        let (scrollView, textView) = MarkdownTextView.scrollableEditor(document: document)
        scrollView.frame = NSRect(origin: .zero, size: Self.size)
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(scrollView)
        window.contentView?.layoutSubtreeIfNeeded()
        textView.layoutSubtreeIfNeeded()
        return (textView, scrollView, window)
    }

    /// Scroll so the line starting at `location` stands at the top, as the
    /// view itself does when it puts a place back.
    private func place(_ location: Int, atTopOf textView: MarkdownTextView, in scrollView: NSScrollView) {
        textView.standAtTop(location)
    }

    /// Lay the view out after a rebind, as the next pass does.
    private func layOut(_ textView: MarkdownTextView, in window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        textView.layoutSubtreeIfNeeded()
    }

    /// **The view is bound to the next note and back, and each comes back
    /// where it was left** — the arriving one at the top when it has no place:
    /// the scroll view kept the last note's offset.
    @Test func eachNoteComesBackWhereItWasLeft() throws {
        let firstText = Self.note("First")
        let secondText = Self.note("Second")
        let first = EditorDocument(text: firstText)
        let second = EditorDocument(text: secondText)
        let (textView, scrollView, window) = editor(for: first)
        defer { window.contentView = nil }

        let thirtieth = offset(of: "First 30", in: firstText)
        place(thirtieth, atTopOf: textView, in: scrollView)
        #expect(textView.topVisibleCharacter == thirtieth, "the view does not stand where it was put")

        textView.bind(to: second)
        layOut(textView, in: window)
        #expect(first.readingPosition == thirtieth, "the note left did not keep its place")
        #expect(textView.topVisibleCharacter == nil,
                "a note with no place opened at \(textView.topVisibleCharacter ?? 0), where the last one was")

        let fortieth = offset(of: "Second 40", in: secondText)
        place(fortieth, atTopOf: textView, in: scrollView)
        textView.bind(to: first)
        layOut(textView, in: window)
        #expect(second.readingPosition == fortieth)
        #expect(textView.topVisibleCharacter == thirtieth,
                "the first note came back at \(textView.topVisibleCharacter ?? 0), not \(thirtieth)")
    }

    /// The outline's jump, a link to a heading: asked for, so it wins over a
    /// place still waiting to be put back — and, asked before the view has
    /// been laid out, it is the place put back.
    @Test func anExplicitScrollWinsOverAPlaceWaiting() throws {
        let text = Self.note()
        let document = EditorDocument(text: text)
        document.readingPosition = offset(of: "Paragraph 30", in: text)
        let (scrollView, textView) = MarkdownTextView.scrollableEditor(document: document)
        textView.reliablyScroll(to: NSRange(location: offset(of: "Paragraph 55", in: text), length: 0))
        scrollView.frame = NSRect(origin: .zero, size: Self.size)
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(scrollView)
        defer { window.contentView = nil }
        layOut(textView, in: window)
        let top = try #require(textView.topVisibleCharacter, "the view stayed at the top")
        #expect(top > offset(of: "Paragraph 40", in: text),
                "the place waiting was put back over the scroll asked for: top \(top)")
    }

    /// **A place put back stays put while what is above it changes** — the
    /// Mac's view, the same rule. The control: once the reader has taken over,
    /// the same change moves what is at the top.
    @Test func aPlacePutBackStaysWhileWhatIsAboveItChanges() throws {
        let standing = growAbovePlace(afterTakingOver: false)
        #expect(standing.top == standing.place,
                "the place moved when the text above it grew: top \(standing.top ?? 0), not \(standing.place)")
        #expect(standing.kept == standing.place, "a record while the place stood kept another")
        let moved = growAbovePlace(afterTakingOver: true)
        #expect(moved.top != moved.place, "the control: a change above moved nothing, so this test cannot see a drift")
    }

    /// The fortieth paragraph put back at the top of a new view, the reader
    /// taking over or not, then the fifth — above it — grown as a restyle
    /// grows it: what is at the top afterwards, what a record keeps, and the
    /// place.
    private func growAbovePlace(afterTakingOver takingOver: Bool) -> (top: Int?, kept: Int?, place: Int) {
        let text = Self.note()
        let document = EditorDocument(text: text)
        let place = offset(of: "Paragraph 40", in: text)
        document.readingPosition = place
        let (textView, _, window) = editor(for: document)
        defer { window.contentView = nil }
        #expect(textView.topVisibleCharacter == place, "the place was not put back")
        if takingOver { textView.readerTookOver() }
        grow("Paragraph 5,", in: document, text: text)
        layOut(textView, in: window)
        let top = textView.topVisibleCharacter
        textView.recordReadingPosition()
        return (top, document.readingPosition, place)
    }

    /// **A range asked to be shown ends the standing place** — the Mac's view:
    /// the find bar's match, the caret. The control: put back, the place
    /// stands.
    @Test func aRangeShownEndsTheStandingPlace() throws {
        let text = Self.note()
        let document = EditorDocument(text: text)
        document.readingPosition = offset(of: "Paragraph 40", in: text)
        let (textView, _, window) = editor(for: document)
        defer { window.contentView = nil }
        #expect(textView.standingReadingPosition != nil, "the control: the place put back is not standing")
        textView.scrollRangeToVisible(NSRange(location: offset(of: "Paragraph 55", in: text), length: 0))
        #expect(textView.standingReadingPosition == nil, "the place still stood after a range was shown")
    }

    /// **A scroll the view did not make ends the standing place** — the Mac's
    /// wheel, trackpad, scroller and keys all move the clip view, and none of
    /// them is heard any other way: overriding the wheel turned responsive
    /// scrolling off (implemented.md §51.69). The control: the view standing
    /// its own place again keeps it standing.
    @Test func aScrollTheViewDidNotMakeEndsTheStandingPlace() throws {
        let text = Self.note()
        let document = EditorDocument(text: text)
        document.readingPosition = offset(of: "Paragraph 40", in: text)
        let (textView, scrollView, window) = editor(for: document)
        defer { window.contentView = nil }
        #expect(textView.standingReadingPosition != nil, "the place put back is not standing")
        textView.keepStandingIfPutBack()
        #expect(textView.standingReadingPosition != nil, "the control: the view's own standing ended it")
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + 240))
        scrollView.reflectScrolledClipView(clip)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        #expect(textView.standingReadingPosition == nil, "the place still stood after someone else scrolled")
    }

    /// A place kept between launches, set on the document before any view
    /// shows it, is where a new view opens.
    @Test func aPlaceSetBeforeTheViewIsWhereItOpens() throws {
        let text = Self.note()
        let document = EditorDocument(text: text)
        let fiftieth = offset(of: "Paragraph 50", in: text)
        document.readingPosition = fiftieth
        let (textView, _, window) = editor(for: document)
        defer { window.contentView = nil }
        #expect(textView.topVisibleCharacter == fiftieth,
                "the view opened at \(textView.topVisibleCharacter ?? 0), not \(fiftieth)")
    }

    /// **A heading jump wins over a place put back** — the Mac's view, the
    /// same rule (implemented.md §51.72).
    @Test func aHeadingJumpWinsOverAPlacePutBack() throws {
        let text = Self.note()
        let document = EditorDocument(text: text)
        document.readingPosition = offset(of: "Paragraph 40", in: text)
        let (textView, _, window) = editor(for: document)
        defer { window.contentView = nil }
        let heading = offset(of: "Paragraph 10,", in: text)
        textView.showHeading(at: heading)
        grow("Paragraph 2,", in: document, text: text)
        layOut(textView, in: window)
        #expect(textView.topVisibleCharacter == heading,
                "the place put back was stood over the jump: top \(textView.topVisibleCharacter ?? 0)")
    }

    /// **A heading jump asked for before the first layout is where the view
    /// opens** — on the Mac the put-back of the place kept took it back.
    @Test func aHeadingJumpBeforeTheFirstLayoutIsWhereItOpens() throws {
        let text = Self.note()
        let document = EditorDocument(text: text)
        document.readingPosition = offset(of: "Paragraph 30", in: text)
        let (scrollView, textView) = MarkdownTextView.scrollableEditor(document: document)
        let heading = offset(of: "Paragraph 50,", in: text)
        textView.showHeading(at: heading)
        scrollView.frame = NSRect(origin: .zero, size: Self.size)
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(scrollView)
        defer { window.contentView = nil }
        layOut(textView, in: window)
        #expect(textView.topVisibleCharacter == heading,
                "the view opened at \(textView.topVisibleCharacter ?? 0), not the heading asked for")
    }

    /// **A place past the end of a note shortened since stands at its last
    /// line** — the Mac's view, which kept the last note's offset instead
    /// (implemented.md §51.72).
    @Test func aPlacePastTheEndStandsAtTheLastLine() throws {
        let text = Self.note()
        let document = EditorDocument(text: text)
        let length = (text as NSString).length
        document.readingPosition = length + 5_000
        let (textView, _, window) = editor(for: document)
        defer { window.contentView = nil }
        let top = try #require(textView.topVisibleCharacter, "the view stayed at the top")
        #expect(top > offset(of: "Paragraph 40", in: text), "the view did not go to the note's end: top \(top)")
        textView.recordReadingPosition()
        #expect((document.readingPosition ?? 0) < length, "the place past the end was kept again")
    }

    #endif
}
