//
//  TextPlacement.swift
//  MarkdownEditor
//
//  Where a scrolling text view puts its text: in the pane's column
//  (`TextColumn`), with room below the last line to bring it up to the middle
//  of the view. One piece, used by Edit's text view and the Markdown pane's
//  alike, on both platforms — the Markdown pane had neither.
//
//  Both live in the text container's inset, so both are part of the document:
//  the view fills its pane (its scroller at the pane's edge, a wheel over the
//  margin scrolling the note), and the room is page, not a limit some way of
//  scrolling might not ask about (`EditorClipView`).
//

import Foundation
import CoreGraphics
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The room below the last line a view `viewport` points tall gives a note
/// `content` points tall: half the viewport, once the note is long enough to
/// scroll — a short note in a tall window gains nothing from a screenful of
/// emptiness under it. Whole points, so the frame stays on them.
nonisolated func roomPastEnd(content: CGFloat, viewport: CGFloat) -> CGFloat {
    viewport > 0 && content > viewport ? (viewport / 2).rounded() : 0
}

#if canImport(AppKit)

/// A text view whose clip view reports its height changing
/// (`EditorClipView`) — the viewport its room past the end is half of.
@MainActor public protocol ViewportFollowing: AnyObject {
    func viewportDidChange()
}

/// The clip view of a scroll view whose text has room past its end. It tells
/// the text view when the viewport's height changes, which decides the room —
/// something the text view is not otherwise told: its frame follows the clip
/// view's width, never its height.
///
/// It used to *be* the room: `constrainBoundsRect` let the clip view scroll
/// half a viewport past the end of a document that ended at its last line.
/// A wheel honours that, and every test did; using the note on a trackpad, the
/// scroll stopped at the last line all the same (build 28), and that last line,
/// at the bottom edge, was drawn cut through its middle where the text view's
/// frame ended under it. The room is in the document now, where no way of
/// scrolling can miss it.
public final class EditorClipView: NSClipView {
    public override func setFrameSize(_ newSize: NSSize) {
        let height = frame.height
        super.setFrameSize(newSize)
        if newSize.height != height { (documentView as? ViewportFollowing)?.viewportDidChange() }
    }
}

/// Where an AppKit text view's text sits. The view keeps one and answers
/// `textContainerOrigin` with `origin`.
///
/// AppKit's inset is one size for both sides, so it carries the *sum* of each
/// pair — the column's two margins on the width, the room on the height — and
/// the origin puts the text where it belongs: the leading margin on the left,
/// every point of the extra height at the bottom. AppKit draws, hit-tests and
/// places the caret from `textContainerOrigin` — probed under TextKit 2: an
/// origin moved 100pt moved the ink, and the character a click found, by
/// exactly that.
@MainActor public struct TextPlacement {
    /// The view's own inset, before any column or room.
    public let base: CGSize
    /// The pane's column, laid out at the view's width.
    public var column: TextColumn = .full
    /// The column's distance from the view's leading edge.
    public private(set) var leading: CGFloat = 0
    /// The room below the last line.
    public private(set) var room: CGFloat = 0

    public init(base: CGSize) { self.base = base }

    /// What `textContainerOrigin` returns: pinned at the top, whatever the
    /// bottom holds.
    public var origin: NSPoint { NSPoint(x: base.width + leading, y: base.height) }

    /// Bring `textView`'s inset up to date with its width, its height and its
    /// clip view's. Cheap when nothing changed — it runs on every layout.
    ///
    /// Static, over the view's own stored placement, and in two steps — the
    /// new placement is *stored* before the view is touched — because touching
    /// it resizes it, and AppKit reads `textContainerOrigin` in the middle of
    /// that: a `mutating` method on the stored property still held it, and the
    /// read was an exclusivity violation, which aborts.
    public static func update<View: NSTextView>(_ textView: View, _ placement: ReferenceWritableKeyPath<View, TextPlacement>) {
        guard let (next, inset) = textView[keyPath: placement].updated(for: textView) else { return }
        textView[keyPath: placement] = next
        textView.textContainerInset = inset
        textView.invalidateTextContainerOrigin()
        // A new inset does not resize the view by itself.
        textView.sizeToFit()
    }

    /// The placement `textView` wants now, and the inset that carries it —
    /// `nil` when nothing changes.
    func updated(for textView: NSTextView) -> (TextPlacement, NSSize)? {
        let margins = column.margins(in: textView.bounds.width)
        // The note's own height, without the room it has now: the room never
        // decides itself.
        let content = textView.frame.height - 2 * (textView.textContainerInset.height - base.height)
        var viewport: CGFloat = 0
        if let clip = textView.enclosingScrollView?.contentView {
            viewport = clip.bounds.height - clip.contentInsets.top - clip.contentInsets.bottom
        }
        let room = roomPastEnd(content: content, viewport: viewport)
        let inset = NSSize(width: base.width + (margins.leading + margins.trailing) / 2,
                           height: base.height + room / 2)
        guard inset != textView.textContainerInset || margins.leading != leading else { return nil }
        var next = self
        next.leading = margins.leading
        next.room = room
        return (next, inset)
    }
}

#else

/// Where a UIKit text view's text sits: UIKit's inset has four sides, so the
/// column's margins go on the left and right and the room on the bottom.
@MainActor public struct TextPlacement {
    /// The view's own inset, before any column or room.
    public let base: CGSize
    /// The pane's column, laid out at the view's width.
    public var column: TextColumn = .full

    public init(base: CGSize) { self.base = base }

    /// The room below the last line, as the view has it now.
    public func room(of textView: UITextView) -> CGFloat {
        max(0, textView.textContainerInset.bottom - base.height)
    }

    /// Bring `textView`'s inset up to date with its size. Cheap when nothing
    /// changed — it runs on every layout.
    ///
    /// **Room to scroll into, never a covered band.** It is the bottom of the
    /// text container's inset — part of the content — and not a content inset.
    /// A scroll view keeps what it scrolls to inside its bounds *less* its
    /// insets, so as a content inset half the editor counted as hidden: a tap on
    /// a line in the lower half scrolled it up to the middle, and with the
    /// software keyboard's inset on top — 313pt of ours and 407pt of the
    /// keyboard's against a 626pt view — the band UIKit keeps the caret in had
    /// negative height, and its own scroll-to-the-caret put the tapped line
    /// 94pt above the top edge (`ScrollPastEndTests`, docs/implemented.md).
    public func apply(to textView: UITextView) {
        let viewport = textView.bounds.height - textView.adjustedContentInset.top
        let content = textView.contentSize.height - room(of: textView)
        let room = roomPastEnd(content: content, viewport: viewport)
        let margins = column.margins(in: textView.bounds.width)
        let inset = UIEdgeInsets(top: base.height, left: base.width + margins.leading,
                                 bottom: base.height + room, right: base.width + margins.trailing)
        guard abs(textView.textContainerInset.bottom - inset.bottom) > 0.5
                || textView.textContainerInset.left != inset.left
                || textView.textContainerInset.right != inset.right
                || textView.textContainerInset.top != inset.top
        else { return }
        textView.textContainerInset = inset
    }
}

#endif
