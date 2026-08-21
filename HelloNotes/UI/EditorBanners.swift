//
//  EditorBanners.swift
//  HelloNotes
//
//  The two things the *buffer* has to say, wherever it is shown: the note
//  changed on disk under you, and the last save failed.
//
//  Standalone views rather than computed properties on one screen, because the
//  iPad now shows a note in two places (the main window and a standalone note
//  window) and both have to say it. They were private to `iOSContentView` and,
//  before that, presented only by the macOS `NoteEditorView` — which is how
//  `resolveConflictReloading()` and `resolveConflictKeepingMine()` came to have
//  no iOS caller at all, and a conflict on iPad was detected and then silently
//  overwritten by the next autosave.
//

#if os(iOS)
import SwiftUI

/// The note changed on disk under an open editor.
///
/// `EditorModel.hasConflict` is raised on both platforms and presented by
/// `NoteEditorView` alone, so `resolveConflictReloading()` and
/// `resolveConflictKeepingMine()` had **no iOS caller whatsoever**: a
/// conflict was detected on iPad and then silently overwritten by the next
/// autosave, which is the one outcome the conflict check exists to prevent.
struct ConflictBanner: View {
    @Bindable var editor: EditorModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("This note changed on disk while you were editing.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Reload") { editor.resolveConflictReloading() }
            Button("Keep Mine") { Task { await editor.resolveConflictKeepingMine() } }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(10)
        .background(.orange.opacity(0.15))
    }
}

/// A failed write, stated where the typing is happening.
///
/// A banner rather than an alert, for the Mac's reason: a failing autosave
/// retries on its own, and a re-appearing alert would spam. `saveError` was
/// read only by `NoteEditorView`, so an iPad whose collection folder had
/// gone away went on accepting typing that was never written, with nothing
/// on screen to say so — this file even *builds* the blocked-save sentence
/// itself, in `iOSContentView.wireTabs`, and then nothing read it back.
struct SaveErrorBanner: View {
    @Bindable var editor: EditorModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("This note couldn’t be saved.")
                    .font(.callout.weight(.medium))
                if let error = editor.saveError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button("Retry") { Task { await editor.save() } }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(10)
        .background(.red.opacity(0.15))
    }
}
#endif
