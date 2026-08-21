//
//  EditorMenuItem.swift
//  MarkdownEditor
//
//  A host-supplied action offered on a text selection — on both platforms.
//
//  It lived inside `MarkdownUITextView.swift`, which is gated to UIKit, so the
//  vault actions (Link to…, Find Related, Ask Your Library) could only ever be
//  offered on iOS. macOS grew a floating `SelectionActionBar` instead: a second
//  implementation of the same three commands, positioned by a second hook
//  (`onSelectionChange`) that iOS did not have, drifting independently.
//
//  Both platforms already have a menu that appears on a selection — iOS floats
//  the system edit menu, macOS opens the context menu — and both already
//  receive "Rewrite with AI…" through it. So the items go there on both, this
//  type moves out of the UIKit half, and the floating bar and its hook are
//  deleted.
//

import Foundation

/// A host-supplied action offered on a text selection.
///
/// Delivered into the **system** edit menu rather than a bar of our own. iOS
/// already floats a menu over a selection, and a second one competing for the
/// same few hundred points is the kind of thing that reads as a bug: the OS's
/// menu is where a reader's hand already goes.
public struct EditorMenuItem {
    public let title: String
    public let systemImage: String?
    /// Given the selected text, return replacement text — or `nil` to act
    /// without touching the document (search, ask, anything read-only).
    public let perform: (String) -> String?

    public init(title: String, systemImage: String? = nil,
                perform: @escaping (String) -> String?) {
        self.title = title
        self.systemImage = systemImage
        self.perform = perform
    }
}
