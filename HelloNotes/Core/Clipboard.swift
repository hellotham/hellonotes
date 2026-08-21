//
//  Clipboard.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  One "copy this text". Four call sites built the same wiki link — two with
//  `NSPasteboard`, two with `UIPasteboard` — and each spelled the link itself
//  inline, so the format lived in four places on two platforms. That is a
//  string one of them can be changed without.
//

import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@MainActor
enum Clipboard {
    static func copy(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

extension Note {
    /// How this note is referred to from another note. Written once so the
    /// "Copy Wiki Link" command cannot mean two things.
    var wikiLink: String { "[[\(title)]]" }
}
