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
    static var barTrailing: ToolbarItemPlacement {
        #if os(macOS)
        .primaryAction
        #else
        .topBarTrailing
        #endif
    }
}

extension View {
    /// The library search field, attached to the panel it searches (D9).
    ///
    /// Both platforms get a native `.searchable`; only the *placement* has two
    /// spellings. `.navigationBarDrawer(.always)` is how iOS says "must not
    /// vanish at the width it is most needed"; `.sidebar` is where macOS puts a
    /// field that belongs to column one, which is the leading position the
    /// chrome contract asks for.
    ///
    /// The Mac used to hand-build this field and place it in the shell's
    /// toolbar, on the reading that `.searchable` collapses to a glyph and
    /// claims the trailing end. Those are behaviours of a field placed
    /// `.automatic` in a window toolbar, not of one placed in the sidebar — and
    /// a hand-built field is a second search implementation, which is how the
    /// two platforms came to focus, clear and reveal it differently.
    func librarySearchable(text: Binding<String>, focused: FocusState<Bool>.Binding) -> some View {
        #if os(macOS)
        return searchable(text: text, placement: .sidebar,
                          prompt: "Search all collections")
            .searchFocused(focused)
        #else
        return searchable(text: text,
                          placement: .navigationBarDrawer(displayMode: .always),
                          prompt: "Search all collections")
            .searchFocused(focused)
        #endif
    }
}
