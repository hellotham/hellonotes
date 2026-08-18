//
//  FormatAction.swift
//  HelloNotes
//
//  Created by Chris Tham on 18/8/2026.
//
//  Formatting commands, and the bus that carries them to whichever editor is
//  focused.
//
//  **Cross-platform on purpose.** This lived inside `AppCommands.swift`, which
//  is `#if os(macOS)` in its entirety, so an iPad had no way to express "make
//  this bold" at all — no Format menu, and no keyboard bar either, because the
//  vocabulary itself was Mac-only. Moving it here is what lets the iOS
//  accessory bar post the very commands the Mac's Format menu posts.
//

import Foundation

/// A Markdown formatting command a menu or toolbar can send to the focused
/// editor (routed to the editor through its notification bus).
enum FormatAction {
    case bold, italic, strikethrough, highlight, inlineCode
    case blockquote, unorderedList, orderedList
    case heading(Int)
}

extension Notification.Name {
    /// The bus a formatting command travels on, addressed to one document.
    static func hnFormat(_ kind: String, documentId: String) -> Notification.Name {
        Notification.Name("hnEditorFormat.\(kind).\(documentId)")
    }
}

extension FormatAction {
    /// The bus-name suffix and optional userInfo for this action.
    var kind: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .strikethrough: "strikethrough"
        case .highlight: "highlight"
        case .inlineCode: "inlineCode"
        case .blockquote: "blockquote"
        case .unorderedList: "unorderedList"
        case .orderedList: "orderedList"
        case .heading: "heading"
        }
    }

    var userInfo: [String: Any]? {
        if case .heading(let level) = self { return ["level": level] }
        return nil
    }
}
