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
//  Where the text comes from differs and should: a window has no editor, so it
//  reads the file; a sheet is over the open note and uses the live buffer, which
//  is what makes the map reflect unsaved edits. So the text is a parameter.
//

import SwiftUI

/// The mind map itself.
struct MindMapPane: View {
    let rootURL: URL
    /// The note's Markdown. The caller decides where it comes from.
    let text: String?

    /// Open a note — a window asks the main one, a sheet selects directly.
    var onOpenNote: (URL) -> Void
    /// Jump to a section of the root note. iPad never supplied this.
    var onShowSection: (String?) -> Void

    @Environment(Library.self) private var library
    @Environment(AppearanceSettings.self) private var appearance

    private var collection: Collection? { library.collection(containing: rootURL) }

    private var rootTitle: String {
        collection?.notes.first { $0.fileURL == rootURL }?.title
            ?? rootURL.deletingPathExtension().lastPathComponent
    }

    var body: some View {
        Group {
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
                ContentUnavailableView("Note Unavailable", systemImage: "brain",
                                       description: Text("This note's collection is no longer open."))
            }
        }
        .navigationTitle("Mind Map — \(rootTitle)")
    }
}
