//
//  Tips.swift
//  HelloNotes
//
//  In-context TipKit tips for HelloNotes' less-discoverable features. Configured
//  once at launch (`HelloNotesApp`); attached to the relevant controls with
//  `.popoverTip(_:)`. Kept to a handful, event/parameter-ruled so they surface in
//  context rather than as a launch tour.
//

import TipKit

/// The one tip aimed at a *disappearance*: the Intelligence panel is gone and
/// its actions moved next to what they act on, so the first time a note has
/// somewhere to link to, say where linking now lives.
struct SuggestLinksTip: Tip {
    var title: Text { Text("Let the model find links") }
    var message: Text? { Text("Suggest proposes notes worth linking to. Accept one and it becomes an outgoing link below.") }
    var image: Image? { Image(systemName: "link.badge.plus") }
}

struct MindMapTip: Tip {
    var title: Text { Text("See how your notes connect") }
    var message: Text? { Text("The Mind Map draws the links across this collection. A note's own links in and out are its Graph, in the panel.") }
    var image: Image? { Image(systemName: "brain") }
}

enum HelloNotesTips {
    /// Configure the TipKit datastore once, at launch.
    static func configure() {
        try? Tips.configure([
            .displayFrequency(.immediate),
            .datastoreLocation(.applicationDefault),
        ])
        // The whole-window parity capture (`scripts/window-parity.sh`) compares
        // two pictures; a tip one device has dismissed and the other has not is
        // a difference in history, not in drawing.
        if ProcessInfo.processInfo.arguments.contains("-HNHideTips") {
            Tips.hideAllTipsForTesting()
        }
    }
}
