//
//  EditorMode.swift
//  HelloNotes
//
//  Created by Chris Tham on 13/7/2026.
//

import SwiftUI

/// How the note editor presents the open note. Shared by both platforms, which
/// now offer the same four modes and start in the same one: `iOSLiveEditor`
/// gave iPad the live WYSIWYG ``edit`` mode the Mac has, and both platforms
/// default their stored mode to ``edit``.
enum EditorMode: String, CaseIterable, Identifiable {
    /// Live, editable WYSIWYG rendering.
    case edit
    /// Read-only rendering — the note as it reads, with no caret.
    case preview
    /// The raw Markdown source, editable in a plain monospaced editor.
    case markdown
    /// Source and preview together, side by side or stacked by aspect ratio.
    case split

    var id: String { rawValue }

    var label: String {
        switch self {
        case .edit: "Edit"
        case .preview: "Preview"
        case .markdown: "Markdown"
        case .split: "Split"
        }
    }

    var symbol: String {
        switch self {
        case .edit: "pencil.and.outline"
        case .preview: "eye"
        case .markdown: "chevron.left.forwardslash.chevron.right"
        case .split: "rectangle.split.2x1"
        }
    }

    /// The cases this platform offers, in the order every picker shows them.
    ///
    /// **One array, not two behind a `#if`.** There used to be `macCases` and
    /// `iOSCases`, byte-identical, with `platformCases` choosing between two
    /// equal values — a difference the code claimed and no longer had. Two
    /// lists that must stay equal, and a conditional that hides it when they
    /// stop being, is exactly how a mode comes to exist on one platform for a
    /// reason nobody wrote down: the shared surfaces (the View menu, the
    /// command palette) would silently offer the iPad whatever the Mac listed.
    static let platformCases: [EditorMode] = [.edit, .preview, .markdown, .split]
}
