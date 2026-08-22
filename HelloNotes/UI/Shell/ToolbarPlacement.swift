//
//  ToolbarPlacement.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  The two ends of the title bar, named once.
//
//  `.topBarLeading` and `.topBarTrailing` are iOS spellings with no macOS
//  counterpart, and they were the last thing keeping the two shells in separate
//  files: everything else in `iOSContentView` compiled on macOS. A placement
//  that exists on one platform is not a *position* that exists on one platform
//  — both title bars have a leading end and a trailing end, and both toolbars
//  can put something there.
//

import SwiftUI

extension ToolbarItemPlacement {
    /// The leading end of the title bar.
    static var barLeading: ToolbarItemPlacement {
        #if os(macOS)
        .navigation
        #else
        .topBarLeading
        #endif
    }

    /// The trailing end of the title bar.
    ///
    /// `.automatic` on macOS, not `.primaryAction`: Apple documents
    /// `.primaryAction` as the toolbar's *leading* edge there, so an inspector
    /// toggle asking for the trailing end landed on the wrong side. `.automatic`
    /// appends in declaration order, which — after `.navigation` and
    /// `.principal` — is the trailing end, and is exactly what the Mac's own
    /// `editorToolbar` already does for the five inspector tabs
    /// (`shell-chrome.md` Part 5, measured in ChromeLab).
    static var barTrailing: ToolbarItemPlacement {
        #if os(macOS)
        .automatic
        #else
        .topBarTrailing
        #endif
    }
}
