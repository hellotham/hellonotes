//
//  MindMapPane.swift
//  HelloNotes
//
//  The open note as a mind map — one view, both platforms.
//
//  It was `MindMapWindowView`, gated to macOS, with the iPad drawing its own
//  `mindMapSheet` beside it. Same `MindMapView` underneath, and one parameter
//  different: the Mac passed `onShowSection` and iPad did not. That parameter
//  defaults to a no-op, so **tapping a heading node did nothing on iPad** while
//  on the Mac it opened the note and scrolled to that section. A silently
//  defaulted closure is the quietest way for two call sites to disagree — there
//  is no error, no warning, and nothing on screen except a tap that does not
//  work.
//
//  The text came from different places too, and on purpose: the Mac's window
//  had no editor, so it read the file and drew the note as of the last
//  autosave, while the iPad's sheet sat over the open note and was handed the
//  live buffer. Both hosts are gone — the map is a view of the right panel on
//  both platforms, beside the editor — and so is the difference: `MindMapPanel`
//  hands over the live buffer while the editor holds the note, which is what
//  makes the map reflect unsaved edits, and reads the file only when it does
//  not. The text stays a parameter so that choice stays with the panel; this
//  view draws what it is handed and reads no file.
//

import SwiftUI

/// The mind map itself.
struct MindMapPane: View {
    let rootURL: URL
    /// The note's Markdown. The caller decides where it comes from.
    let text: String?

    /// Open a linked note. Supplied, like the graph's `onOpen`, because where a
    /// note opens is the host's business and this is only the map:
    /// `MindMapPanel` passes `Library.requestOpen`, as the graph and Ask
    /// Library do.
    var onOpenNote: (URL) -> Void
    /// Jump to a section of the root note (`nil`: just open it). No default,
    /// unlike `MindMapView`'s: a caller that leaves it out does not compile,
    /// where the iPad's sheet left it out and shipped heading taps that did
    /// nothing.
    var onShowSection: (String?) -> Void

    @Environment(Library.self) private var library
    @Environment(AppearanceSettings.self) private var appearance

    private var collection: Collection? { library.collection(containing: rootURL) }

    private var rootTitle: String {
        collection?.notes.first { $0.fileURL == rootURL }?.title
            ?? rootURL.deletingPathExtension().lastPathComponent
    }

    // No `navigationTitle`: the panel's header says "Mind Map", the map's
    // own header names the note, and there is no platform bar to title.
    var body: some View {
        if let c = collection, let text {
            MindMapView(
                rootTitle: rootTitle,
                rootURL: rootURL,
                text: text,
                resolveLink: { target in
                    guard let url = c.linkGraph.resolve(target),
                          let note = c.notes.first(where: { $0.fileURL == url }) else { return nil }
                    return (url, note.title)
                },
                accent: appearance.resolvedAccent,
                onOpenNote: onOpenNote,
                onShowSection: onShowSection
            )
        } else if collection != nil {
            ProgressView()   // text still loading
        } else {
            ChromeEmptyState("Note Unavailable", systemImage: "brain",
                             description: Text("This note's collection is no longer open."))
        }
    }
}
