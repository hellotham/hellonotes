//
//  AuxiliarySurface.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  Graph, Ask Library, Assistant, Mind Map — the surfaces
//  that sit beside the notes rather than inside them.
//
//  The Mac opened a `Window` for each; the iPad presented a sheet. Two lists,
//  independently maintained, either of which could gain a surface the other
//  never heard about — the same structural defect as the two sidebar menus, and
//  it had already produced a behaviour difference: the Mac's mind-map window
//  read the note's *file*, so it showed the last saved version, while the
//  iPad's sheet was handed the live buffer and showed what you were typing.
//
//  There is no capability reason for the split. The app already opens windows
//  on iPad — `openWindow(value: NoteRef(…))` for a note, `openWindow(id:
//  "main")` for New Window — so the iPad can hold a second scene; these
//  surfaces simply were not given one. SwiftUI's singleton `Window` scene is
//  macOS-only, but `WindowGroup(id:)` is on both, and that is what they use.
//
//  What decides window-or-sheet is **not the OS**. It is the same axis of
//  abundance `AdaptiveShell` uses: a canvas wide enough to show a second
//  surface beside the notes gets a window; one that is not gets a sheet, which
//  is what a second scene would look like there anyway. A Mac window dragged
//  narrow and an iPhone reach the same answer, which is the whole rule.
//

import SwiftUI

/// A surface that opens beside the notes.
enum AuxiliarySurface: Identifiable, Hashable {
    case graph
    case askLibrary
    case assistant
    /// The mind map of one note. Value-carrying, so its scene is a
    /// `WindowGroup(for:)` rather than an id — the same shape a note window has.
    case mindMap(URL)

    var id: String { windowID }

    /// The scene id `openWindow(id:)` names. `mindMap` opens by value, so it
    /// never uses this to open a window — it still needs a distinct identity as
    /// a sheet item.
    var windowID: String {
        switch self {
        case .graph: "graph"
        case .askLibrary: "askLibrary"
        case .assistant: "assistant"
        case .mindMap(let url): "mindMap:" + url.path
        }
    }

    var title: String {
        switch self {
        case .graph: "Graph"
        case .askLibrary: "Ask Library"
        case .assistant: "Assistant"
        case .mindMap: "Mind Map"
        }
    }

    var symbol: String {
        switch self {
        case .graph: "point.3.connected.trianglepath.dotted"
        case .askLibrary: "sparkles.rectangle.stack"
        case .assistant: "sparkles"
        case .mindMap: "point.topleft.down.curvedto.point.bottomright.up"
        }
    }

    var defaultSize: CGSize {
        switch self {
        case .graph: CGSize(width: 760, height: 560)
        case .askLibrary: CGSize(width: 560, height: 640)
        case .assistant: CGSize(width: 560, height: 680)
        case .mindMap: CGSize(width: 720, height: 540)
        }
    }
}

/// Whether a second scene can usefully sit beside the notes here.
///
/// Keyed on the canvas, never on the platform. On a compact width a second
/// scene *is* the screen — iOS shows one at a time and offers no way back but
/// the app switcher — so a sheet is both the honest presentation and the one
/// the user can dismiss. Above that, a window.
///
/// The threshold is `ShellMetrics.compactMax` — the same number `AdaptiveShell`
/// uses to choose the compact shell — so this cannot drift from the shell's own
/// idea of when there is room for another surface.
enum AuxiliaryPresentation {
    static func prefersWindow(width: CGFloat) -> Bool {
        width > ShellMetrics.compactMax
    }
}

/// Opening an auxiliary surface — one decision, both shells.
///
/// The window and the sheet show the *same view*: `GraphWindowView` and the
/// rest ask `Library.requestOpen` to open a note, which both shells honour, so
/// the view does not need to know which presentation it is in. That is what
/// removes the last reason for two of everything here — the iPad's sheet used
/// to be handed an `onOpenNote` closure and the Mac's window used the request
/// channel, which is two behaviours for "click a node".
@MainActor
struct AuxiliaryOpener {
    let openWindow: OpenWindowAction
    /// The shell's own width — the canvas the surface would open beside.
    let width: CGFloat
    /// Present as a sheet instead, when there is no room for a window.
    let present: (AuxiliarySurface?) -> Void

    func open(_ surface: AuxiliarySurface) {
        guard AuxiliaryPresentation.prefersWindow(width: width) else {
            present(surface)
            return
        }
        // The mind map's scene is keyed on the note it maps, so it opens by
        // value — the same shape a note window has, and already a singleton per
        // note for the same reason.
        if case .mindMap(let url) = surface {
            openWindow(value: MindMapRef(url))
        } else {
            // Everything else is one window per scene, and *stays* one: these
            // used to be macOS-only `Window` scenes, which `openWindow(id:)`
            // refocuses. `WindowGroup(id:)` — needed because `Window` does not
            // exist on iOS — makes a *new* window on every call instead, so
            // clicking Graph three times gave three Graph windows. Passing the
            // scene's own id as the presentation value restores the singleton:
            // SwiftUI brings the existing window forward when one is already
            // open with the same value.
            openWindow(id: surface.windowID, value: AuxiliaryRef(surface.windowID))
        }
    }
}

/// The presentation value that makes an id-named auxiliary scene a singleton.
///
/// One value per scene, so "already open with this value" and "this scene is
/// already open" are the same question — which is what `Window` used to answer
/// on the Mac and nothing answered after the merge.
struct AuxiliaryRef: Hashable, Codable {
    let id: String
    init(_ id: String) { self.id = id }
}

/// The content of an auxiliary surface, wherever it is presented.
struct AuxiliarySurfaceView: View {
    let surface: AuxiliarySurface

    var body: some View {
        switch surface {
        case .graph: GraphWindowView()
        case .askLibrary: LibraryChatWindowView()
        case .assistant: AssistantWindowView()
        case .mindMap(let url): MindMapWindowView(rootURL: url)
        }
    }
}

/// An auxiliary surface presented as a sheet, where the canvas has no room for
/// a window.
///
/// The title and the way out are drawn here because a sheet has no chrome of
/// its own — the same reason `GitSettingsView` draws them on the Mac. Shared,
/// so a surface presented this way says the same thing on both platforms; the
/// iPad's three sheets each spelled their own `NavigationStack` and `Done`.
struct AuxiliarySheet: View {
    let surface: AuxiliarySurface
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AuxiliarySurfaceView(surface: surface)
                .navigationTitle(surface.title)
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
