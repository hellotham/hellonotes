//
//  EditorMetrics.swift
//  MarkdownEditor
//
//  The geometry a host needs in order to sit flush with the editor's text.
//
//  Chrome that renders as part of the document — the inline note title above
//  the body — has to start exactly where the first glyph starts, or it reads as
//  misaligned no matter how well it is styled. That distance is the sum of the
//  text container's inset and its line-fragment padding, neither of which the
//  host can see. Publishing them here is what stops the two from drifting: the
//  text views are configured *from* these values, so there is one number.
//

import Foundation
import CoreGraphics

public enum EditorMetrics {
    #if canImport(AppKit)
    /// Inset from the text view's edges to its text container.
    public static let textContainerInset = CGSize(width: 16, height: 12)
    #else
    public static let textContainerInset = CGSize(width: 12, height: 12)
    #endif

    /// Padding inside the text container, before the first glyph on a line.
    public static let lineFragmentPadding: CGFloat = 5

    /// Distance from the editor view's leading edge to the first character —
    /// what a host must match to align with the text.
    public static var textLeadingInset: CGFloat {
        textContainerInset.width + lineFragmentPadding
    }
}
