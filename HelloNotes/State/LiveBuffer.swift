//
//  LiveBuffer.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  What the editor currently holds, published so another scene can read it.
//
//  A second window cannot see the main window's `EditorTabs`: tabs are the
//  scene's `@State`, which is exactly right — two windows may hold different
//  notes open. But some auxiliary surfaces are *about* the note you are typing
//  in, and reading its file gives them the last saved version.
//
//  That was the mind map. On the Mac it was a window and read the file, so it
//  drew the note as it stood at the last autosave; on iPad it was a sheet in
//  the same scene and was handed the live buffer, so it drew what you were
//  typing. Making both a window would have settled the difference by taking the
//  worse of the two, which is not what settling it means.
//
//  Published on a debounce, not per keystroke. Nothing here needs to track the
//  caret, and an `@Observable` write on every character would invalidate every
//  observer of this object on the typing path — the cost the plan's Tier 3 is
//  about. A beat behind the text is indistinguishable from live for a map.
//

import Foundation

@MainActor
@Observable
final class LiveBuffer {
    /// The note whose text this is, and the text.
    private(set) var url: URL?
    private(set) var text = ""

    @ObservationIgnored private var pending: Task<Void, Never>?

    /// The live text for `url`, or `nil` if the editor is not holding that note
    /// — in which case the caller should read the file.
    func text(for url: URL) -> String? {
        self.url == url ? text : nil
    }

    /// Publish the editor's buffer, coalesced.
    func publish(url: URL?, text: String) {
        pending?.cancel()
        // A note *change* lands immediately: it is not typing, and a map that
        // waited would spend the delay showing the previous note.
        guard url == self.url else {
            self.url = url
            self.text = text
            return
        }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.url = url
            self?.text = text
        }
    }
}
