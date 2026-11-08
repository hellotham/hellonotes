//
//  ReadingPosition.swift
//  MarkdownEditor
//
//  Where in a note the reader was, kept as the character at the top of the
//  view — the one measure a different width, text size or platform leaves
//  meaning the same thing — and put back when a view shows the note again.
//
//  Neither view kept it. The iOS view is made new for every document and
//  opened at the top; the Mac's is bound to the next note and kept whatever
//  offset the last one had. And nothing outlived the process (the person,
//  2026-11-07: "The iOS version doesn't seem to remember position in document
//  in between use"). The document carries it now (`readingPosition`), each
//  view keeps it as scrolling stops and as the view goes, and puts it back
//  once it has a size to put it back in; an explicit scroll — the outline, a
//  link to a heading — wins over a position still waiting to be put back.
//
//  **And a place put back stands until the reader moves.** A note is styled in
//  batches after it is shown, and its tables and diagrams are drawn when they
//  arrive, each changing the height of what is above the place; held at its
//  offset, the place drifted — ten lines in the iPhone simulator — and the
//  drifted place was what the next record kept (implemented.md §51.69). So
//  the view stands the place at the top again at each layout
//  (`keepStandingIfPutBack`), and a record while it stands keeps it, until
//  the reader drags, clicks, types, or asks for a scroll (`readerTookOver`).
//

import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The TextKit 2 half both views share: which character starts the line at a
/// height in the text container, and at what height a character's line
/// starts.
enum ReadingPositionLayout {

    /// The first character of the line at `y`, in text-container coordinates
    /// — asked a point inside that line, not at its edge: a place put back
    /// stands the line's top exactly at `y`, where the paragraph above ends.
    @MainActor
    static func character(atY y: CGFloat, in layoutManager: NSTextLayoutManager) -> Int? {
        let probe = y + 1
        guard let content = layoutManager.textContentManager,
              let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: probe)) else { return nil }
        let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        let inside = probe - fragment.layoutFragmentFrame.minY
        let line = fragment.textLineFragments.first { $0.typographicBounds.maxY > inside }
            ?? fragment.textLineFragments.last
        return start + (line?.characterRange.location ?? 0)
    }

    /// Where the line holding `location` starts, in text-container
    /// coordinates — laid out first, because TextKit 2 estimates the heights
    /// of what it has not laid out, and a position taken from a guess lands
    /// short of a long note's middle.
    @MainActor
    static func top(ofCharacter location: Int, in layoutManager: NSTextLayoutManager) -> CGFloat? {
        guard let content = layoutManager.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: location) else { return nil }
        let end = content.location(start, offsetBy: 1) ?? start
        layoutManager.ensureLayout(for: NSTextRange(location: start, end: end) ?? NSTextRange(location: start))
        guard let fragment = layoutManager.textLayoutFragment(for: start) else { return nil }
        let paragraph = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        let within = location - paragraph
        let line = fragment.textLineFragments.last { $0.characterRange.location <= within }
            ?? fragment.textLineFragments.first
        return fragment.layoutFragmentFrame.minY + (line?.typographicBounds.minY ?? 0)
    }
}

#if !canImport(AppKit)

extension MarkdownUITextView {

    /// The character at the top of what is on screen — `nil` while the note is
    /// at its top.
    public var topVisibleCharacter: Int? {
        guard let layoutManager = textLayoutManager else { return nil }
        let y = contentOffset.y + adjustedContentInset.top - textContainerInset.top
        guard y > 1 else { return nil }
        return ReadingPositionLayout.character(atY: y, in: layoutManager)
    }

    /// Keep where the reader is, in the document. Not while a position is
    /// still waiting to be put back: a view never laid out stands at the top,
    /// and would say the reader was there.
    public func recordReadingPosition() {
        guard pendingReadingPosition == nil, bounds.height > 0, let document else { return }
        // Standing at a place put back, that is the place, whatever a layout
        // in between has made of the offset.
        document.readingPosition = standingReadingPosition ?? topVisibleCharacter
    }

    /// Scrolled: keep the position once scrolling has stopped for a moment —
    /// a drag, a fling, the outline's jump alike.
    func readingPositionMayHaveChanged() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(recordReadingPositionAfterScrolling),
                                               object: nil)
        perform(#selector(recordReadingPositionAfterScrolling), with: nil, afterDelay: 0.3)
    }

    @objc private func recordReadingPositionAfterScrolling() { recordReadingPosition() }

    /// Put the document's position back, once the view has a size to put it
    /// back in — from `layoutSubviews`, once.
    func putBackReadingPositionIfPending() {
        guard let pending = pendingReadingPosition, bounds.width > 0, bounds.height > 0 else { return }
        pendingReadingPosition = nil
        let place = clampedPlace(pending)
        guard place > 0 else { return }
        standingReadingPosition = place
        standAtTop(place)
    }

    /// Stand the place put back at the top again — from `layoutSubviews`, and
    /// asked for by a restyle — while the reader has not moved.
    func keepStandingIfPutBack() {
        guard let standing = standingReadingPosition, bounds.width > 0, bounds.height > 0 else { return }
        standAtTop(standing)
    }

    /// Show the line holding `location` at the top — an explicit scroll: the
    /// outline, a link to a heading. It wins over a place waiting to be put
    /// back and over one standing, and stands as the place until the reader
    /// moves, since the styling still to come moves what is above it as much
    /// as it moves a place put back. Jumps went through `setContentOffset`,
    /// which told neither, so the next layout put the old place back over the
    /// jump (implemented.md §51.72). A view not laid out yet shows it at its
    /// first layout.
    public func showAtTop(_ location: Int) {
        guard hasLaidOut, bounds.width > 0, bounds.height > 0 else {
            pendingReadingPosition = location
            setNeedsLayout()
            return
        }
        pendingReadingPosition = nil
        let place = clampedPlace(location)
        standingReadingPosition = place > 0 ? place : nil
        standAtTop(place)
    }

    /// The reader moved — dragged, tapped the status bar, began editing — or
    /// asked for a scroll: a place put back stands no longer.
    public func readerTookOver() {
        standingReadingPosition = nil
    }

    /// The view scrolled. Not by this view standing a place, so someone did —
    /// VoiceOver's three-finger scroll, a scroll to an element it focused, a
    /// key — and a place put back stands no longer: re-applied at the next
    /// layout, those scrolls were taken back. The counterpart of the Mac's
    /// `clipMoved` (implemented.md §51.72).
    func offsetMoved() {
        guard standingReadingPosition != nil, !isStandingAtPlace else { return }
        if let expected = standingOrigin, abs(contentOffset.y - expected) <= 0.5 { return }
        readerTookOver()
    }

    /// `location`, or the start of the last line for a place past the end of
    /// a note shortened since it was kept — another device, an edit outside
    /// the app, a pull. Past the end, the place was never stood, the view
    /// stayed where it was, and the bad place was kept again.
    func clampedPlace(_ location: Int) -> Int {
        min(max(0, location), max(0, textStorage.length - 1))
    }

    /// Stand the line holding `location` at the top of what is on screen.
    /// TextKit 2 places what it has not laid out by estimated heights, and
    /// laying out what comes on screen moves the line from where the estimate
    /// put it — six paragraphs short, measured in a sixty-paragraph note — so
    /// it is measured again and corrected until it stays. Only what comes on
    /// screen is laid out, never the note above it.
    func standAtTop(_ location: Int) {
        guard let layoutManager = textLayoutManager else { return }
        isStandingAtPlace = true
        defer {
            isStandingAtPlace = false
            standingOrigin = contentOffset.y
        }
        for _ in 0..<4 {
            guard let top = ReadingPositionLayout.top(ofCharacter: location, in: layoutManager) else { return }
            let y = max(-adjustedContentInset.top, top + textContainerInset.top - adjustedContentInset.top)
            guard abs(contentOffset.y - y) > 0.5 else { return }
            setContentOffset(CGPoint(x: contentOffset.x, y: y), animated: false)
            layoutManager.textViewportLayoutController.layoutViewport()
        }
    }
}

#else

extension MarkdownTextView {

    /// The character at the top of what is on screen — `nil` while the note is
    /// at its top. The top is below the toolbar a window's content runs under
    /// (`contentInsets`).
    public var topVisibleCharacter: Int? {
        guard let layoutManager = textLayoutManager, let scrollView = enclosingScrollView else { return nil }
        let y = scrollView.contentView.bounds.minY + scrollView.contentInsets.top - textContainerOrigin.y
        guard y > 1 else { return nil }
        return ReadingPositionLayout.character(atY: y, in: layoutManager)
    }

    /// Keep where the reader is, in the document. Not while a position is
    /// still waiting to be put back: the view would say the reader was
    /// wherever the last note left it.
    public func recordReadingPosition() {
        guard pendingReadingPosition == nil, let scrollView = enclosingScrollView,
              scrollView.contentView.bounds.height > 0, let document else { return }
        document.readingPosition = standingReadingPosition ?? topVisibleCharacter
    }

    /// Scrolled: keep the position once scrolling has stopped for a moment.
    func readingPositionMayHaveChanged() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(recordReadingPositionAfterScrolling),
                                               object: nil)
        perform(#selector(recordReadingPositionAfterScrolling), with: nil, afterDelay: 0.3)
    }

    @objc private func recordReadingPositionAfterScrolling() { recordReadingPosition() }

    /// Put the document's position back — or the top, for a note with none,
    /// since the scroll view outlives the note it last showed — once the view
    /// has a size to put it back in. From `layout()`, once.
    func putBackReadingPositionIfPending() {
        guard let pending = pendingReadingPosition, let scrollView = enclosingScrollView,
              scrollView.contentView.bounds.height > 0, bounds.width > 0 else { return }
        pendingReadingPosition = nil
        let place = clampedPlace(pending)
        standingReadingPosition = place > 0 ? place : nil
        standAtTop(place)
    }

    /// Show the line holding `location` at the top — an explicit scroll: the
    /// outline, a link to a heading. It wins over a place waiting to be put
    /// back and over one standing, and stands as the place until the reader
    /// moves (iOS's `showAtTop` says why). The jump scrolled the clip view
    /// through the TextKit 1 layout manager before, which a TextKit 2 view
    /// should never be asked for (implemented.md §51.72). A view not laid
    /// out yet shows it at its first layout.
    public func showAtTop(_ location: Int) {
        guard hasLaidOut, let clip = enclosingScrollView?.contentView, clip.bounds.height > 0,
              bounds.width > 0 else {
            pendingReadingPosition = location
            needsLayout = true
            return
        }
        pendingReadingPosition = nil
        let place = clampedPlace(location)
        standingReadingPosition = place > 0 ? place : nil
        standAtTop(place)
    }

    /// `location`, or the start of the last line for a place past the end of
    /// a note shortened since it was kept (iOS's `clampedPlace` says why).
    func clampedPlace(_ location: Int) -> Int {
        min(max(0, location), max(0, (textStorage?.length ?? 0) - 1))
    }

    /// Stand the place put back at the top again — from `layout()`, and asked
    /// for by a restyle — while the reader has not moved.
    func keepStandingIfPutBack() {
        guard let standing = standingReadingPosition, let scrollView = enclosingScrollView,
              scrollView.contentView.bounds.height > 0, bounds.width > 0 else { return }
        standAtTop(standing)
    }

    /// The reader moved — a click, a key — or asked for a scroll: a place put
    /// back stands no longer.
    public func readerTookOver() {
        standingReadingPosition = nil
    }

    /// The clip view moved. Not by this view standing a place, so someone
    /// scrolled — a wheel, a trackpad, the scroller, a key, a find — and a
    /// place put back stands no longer.
    ///
    /// Asked of the clip view, never of the wheel: overriding the text view's
    /// `scrollWheel(with:)` to hear it turned AppKit's responsive scrolling
    /// off for the document view, and a wheel then stopped where TextKit 2's
    /// estimate of the note ended, thousands of points short of the room past
    /// it (`EditorScrollingTests`, implemented.md §51.69).
    func clipMoved() {
        guard standingReadingPosition != nil, !isStandingAtPlace,
              let clip = enclosingScrollView?.contentView else { return }
        if let expected = standingOrigin, abs(clip.bounds.minY - expected) <= 0.5 { return }
        readerTookOver()
    }

    /// Stand the line holding `location` at the top of what is on screen — the
    /// note's top for 0. Measured again and corrected until it stays, as on
    /// iOS: laying out what comes on screen moves a line TextKit 2 had placed
    /// by estimated heights.
    func standAtTop(_ location: Int) {
        guard let layoutManager = textLayoutManager, let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        isStandingAtPlace = true
        defer {
            isStandingAtPlace = false
            standingOrigin = clip.bounds.minY
        }
        for _ in 0..<4 {
            let y: CGFloat
            if location > 0 {
                guard let top = ReadingPositionLayout.top(ofCharacter: location, in: layoutManager) else { return }
                y = top + textContainerOrigin.y - scrollView.contentInsets.top
            } else {
                y = -scrollView.contentInsets.top
            }
            guard abs(clip.bounds.minY - y) > 0.5 else { return }
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            scrollView.reflectScrolledClipView(clip)
            layoutManager.textViewportLayoutController.layoutViewport()
        }
    }
}

#endif
