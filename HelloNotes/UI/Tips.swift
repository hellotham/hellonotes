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

struct OpenQuicklyTip: Tip {
    var title: Text { Text("Open Quickly") }
    var message: Text? { Text("Press ⌘O to jump to any note by name, alias, or heading.") }
    var image: Image? { Image(systemName: "magnifyingglass") }
}

struct WikiLinkTip: Tip {
    var title: Text { Text("Link notes") }
    var message: Text? { Text("Type `[[` to autocomplete a link to another note.") }
    var image: Image? { Image(systemName: "link") }
}

struct TransclusionTip: Tip {
    var title: Text { Text("Embed a note") }
    var message: Text? { Text("Use `![[Note]]` to embed another note inline as a card.") }
    var image: Image? { Image(systemName: "doc.on.doc") }
}

/// The one tip aimed at a *disappearance*: the Intelligence panel is gone and
/// its actions moved next to what they act on, so the first time a note has
/// somewhere to link to, say where linking now lives.
struct SuggestLinksTip: Tip {
    var title: Text { Text("Let the model find links") }
    var message: Text? { Text("Suggest proposes notes worth linking to. Accept one and it becomes an outgoing link below.") }
    var image: Image? { Image(systemName: "link.badge.plus") }
}

struct GraphTip: Tip {
    var title: Text { Text("See the graph") }
    var message: Text? { Text("Open the Graph to explore how your notes link together.") }
    var image: Image? { Image(systemName: "point.3.connected.trianglepath.dotted") }
}

struct RescanTip: Tip {
    var title: Text { Text("Rescan the vault") }
    var message: Text? { Text("Changed files outside HelloNotes? Rescan to pick them up.") }
    var image: Image? { Image(systemName: "arrow.clockwise") }
}

enum HelloNotesTips {
    /// Configure the TipKit datastore once, at launch.
    static func configure() {
        try? Tips.configure([
            .displayFrequency(.immediate),
            .datastoreLocation(.applicationDefault),
        ])
    }
}
