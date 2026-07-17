//
//  EditorMode.swift
//  HelloNotes
//
//  Created by Chris Tham on 13/7/2026.
//

import SwiftUI

/// How the note editor presents the open note. Shared by both platforms,
/// though not every case is offered everywhere: macOS starts in ``edit`` (the
/// live WYSIWYG rendering), while iOS — which has no live editor — starts in
/// ``preview`` and offers only the render/source/split trio.
enum EditorMode: String, CaseIterable, Identifiable {
    /// Live, editable WYSIWYG rendering. macOS only.
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

    /// The cases offered on macOS (all four).
    static let macCases: [EditorMode] = [.edit, .preview, .markdown, .split]

    /// The cases offered on iOS — no live WYSIWYG editor there.
    static let iOSCases: [EditorMode] = [.edit, .preview, .markdown, .split]
}
