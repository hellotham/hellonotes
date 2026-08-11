//
//  ViewportSizing.swift
//  MarkdownEditor
//
//  The app-wide answer to one bug class: a representable that wraps a
//  scrolling or content-sized platform view (NSScrollView, UITextView,
//  WKWebView, PDFView, QLPreviewView, NSOutlineView…) and lets SwiftUI derive
//  its size from `fittingSize`.
//
//  `fittingSize` on such a view is the size of its CONTENT — the whole note,
//  the whole vault's note list, the whole PDF. Reported as an *ideal* size it
//  propagates up through every ancestor: measured once at 3433pt for a 76-line
//  note, which inflated the detail column to 1477.5pt and the entire
//  NavigationSplitView past its 923pt window, offsetting it to y = -251 so the
//  top of every note sat above the window and could not be scrolled to.
//
//  A viewport is by definition a window onto content larger than itself. It
//  must report the size it is OFFERED, never the size of what it contains.
//
//  See docs/layout-architecture.md (invariant S1).
//

import SwiftUI

/// The size a viewport-style representable should report.
///
/// SwiftUI probes a view with three kinds of proposal, and each must answer
/// without ever consulting the wrapped view's content size:
///
/// - a **concrete** proposal → take exactly what is offered;
/// - **zero** (the minimum probe) → collapse; a viewport can be made small;
/// - **infinity** (the maximum probe) → grow; a viewport can be made large;
/// - **unspecified** (`nil`, the ideal probe) → a modest default, NOT the
///   content height. This is the case that caused the bug: returning `nil`
///   from `sizeThatFits` falls back to `fittingSize`, re-arming it.
///
/// - Parameter ideal: what to report when SwiftUI asks for an ideal size with
///   no proposal. Small and content-independent by design.
public func viewportSizeThatFits(
    _ proposal: ProposedViewSize,
    ideal: CGSize = CGSize(width: 320, height: 240)
) -> CGSize {
    CGSize(width: proposal.width ?? ideal.width,
           height: proposal.height ?? ideal.height)
}
