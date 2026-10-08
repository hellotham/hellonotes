//
//  ComposeRun.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  Starting a compose or research run, and linking an unlinked mention — two
//  small flows that were written twice, identically enough that the copies read
//  as a transcription and different enough to matter.
//
//  `runCompose` differed only in which collection it wrote into: the Mac's
//  `focused`, the iPad's `railCollection ?? focused`. Both spell "the collection
//  the user is working in" in their own shell's vocabulary, so the scope stays a
//  parameter and the decision — write vs research, and what a research run needs
//  in its `ToolContext` — moves here.
//
//  `linkMention` differed by one identifier (`selectedNote` against
//  `editor.note`) and was otherwise byte-for-byte the same twenty lines,
//  including the comment explaining why both the read and the write go off the
//  main actor. Twenty duplicated lines with a coordinated file write in them is
//  the kind of copy that eventually diverges in the half nobody is looking at.
//

import Foundation

@MainActor
enum ComposeRun {

    /// Start a compose or research run in `collection`.
    static func start(prompt: String,
                      mode: NoteComposer.Mode,
                      depth: Int,
                      in collection: Collection,
                      composer: NoteComposer,
                      permissions: PermissionBroker,
                      settings: IntelligenceSettings) {
        switch mode {
        case .write:
            composer.compose(prompt: prompt, in: collection, settings: settings)
        case .research:
            composer.research(
                question: prompt, depth: depth,
                context: ToolContext(collection: collection,
                                     search: collection.search,
                                     git: collection.git,
                                     permissions: permissions,
                                     settings: settings),
                settings: settings)
        }
    }
}

@MainActor
enum MentionLinker {

    /// Turn the first unlinked mention of `title` inside `note` into a
    /// `[[wiki link]]`.
    ///
    /// The read **and** the write go off the main actor: both are coordinated,
    /// and a coordinated call against a File Provider blocks for as long as the
    /// provider takes. This runs from a button in the inspector, so the window
    /// would freeze with it.
    static func linkFirstMention(of title: String,
                                 in note: Note,
                                 collection: Collection) async {
        // **Open in an editor: made there**, to what is on screen, and written
        // by its own save (`applyEdit`) — as the Assistant's edits are. Written
        // to the file and told to no editor, it met the note's tab as a change
        // made elsewhere, and asked the person to choose (implemented.md §51.36).
        if let editor = EditorModel.editors(holding: note.fileURL).first(where: { $0.isLoaded && !$0.hasConflict }) {
            editor.applyEdit { MentionScanner.linkingFirstMention(of: title, in: $0) }
            return
        }
        // Otherwise the file — and only over the text the link was found in.
        let updated = await offMain { () -> String? in
            guard let text = try? FileIO.readString(at: note.fileURL),
                  let updated = MentionScanner.linkingFirstMention(of: title, in: text),
                  (try? FileIO.replace(updated, at: note.fileURL, ifContentsEqual: text)) == true
            else { return nil }
            return updated
        }
        guard let updated else { return }
        // The note *set* is unchanged (one note's content), so no re-scan:
        // patch the index incrementally and suppress the watcher for our write
        // — and tell the open editors, which the watcher then will not.
        collection.noteDidSave(note.fileURL, text: updated)
        collection.noteChangedOutsideEditor()
    }
}
