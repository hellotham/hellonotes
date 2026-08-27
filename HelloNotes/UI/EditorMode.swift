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

    /// Where the mode is persisted.
    ///
    /// A constant because the literal was spelled in four files, and that is
    /// how it came to be spelled *two different ways*: `editorViewMode` in the
    /// shared editor and the Mac's shell, `iosEditorViewMode` in the iPad's,
    /// so the iPad's View menu wrote one key while the editor it controls read
    /// the other. A key named once cannot fork.
    static let storageKey = "editorViewMode"

    /// The stored raw value, as a mode. Unknown values fall back to editing,
    /// which is the mode a note is most useful in.
    static func mode(_ raw: String) -> EditorMode { EditorMode(rawValue: raw) ?? .edit }

    /// What a note opens in when nothing else is open yet.
    ///
    /// The Mac opens in ``edit``: a keyboard and a pointer are already there and
    /// the window is wide enough for the live editor to be the useful view. iOS
    /// opens in ``preview`` — a note reached by tapping is usually one you meant
    /// to *read*, and starting in an editor puts a keyboard over half the screen
    /// answering a question nobody asked.
    ///
    /// This applies **only to the first note**. Once anything is open, that
    /// mode is the answer for the next one: switching modes under a reader who
    /// deliberately picked one is worse than either default could be right.
    static var platformDefault: EditorMode {
        #if os(macOS)
        .edit
        #else
        .preview
        #endif
    }

    /// The stored raw value as a mode binding, for a picker.
    static func binding(_ raw: Binding<String>) -> Binding<EditorMode> {
        Binding(get: { mode(raw.wrappedValue) }, set: { raw.wrappedValue = $0.rawValue })
    }

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
