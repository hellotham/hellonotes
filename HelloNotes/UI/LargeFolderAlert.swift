//
//  LargeFolderAlert.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  "That's a big folder — sure?" — asked the same way on both platforms.
//
//  It was an `NSAlert` inside `Library`, in a `#if os(macOS)` block, so **iPad
//  had no warning at all**: picking a 2,000-note vault there opened it with no
//  word said and no way to narrow the choice, on the platform where the wait is
//  longest and the picker most likely to land on a whole iCloud Drive folder.
//
//  A model cannot present an alert, which is what made the Mac's version live
//  inside one — `NSAlert.runModal()` blocks and returns a button. So `Library`
//  publishes the question and this presents it, and the answer travels back
//  through the continuation `openChecking` is waiting on.
//
//  Adding a huge folder is never *blocked*. It is the user's folder and their
//  call; the warning exists so the wait is not a surprise, and so the far more
//  common intent — "I meant my Notes subfolder" — has somewhere to go.
//

import SwiftUI

struct LargeFolderAlert: ViewModifier {
    @Bindable var library: Library

    func body(content: Content) -> some View {
        content.alert(
            "“\(library.pendingLargeFolder?.url.lastPathComponent ?? "")” is a large folder",
            isPresented: Binding(
                get: { library.pendingLargeFolder != nil },
                // A dismissal that is not a button is a cancel: the flow is
                // waiting on a continuation and must not be left holding it.
                set: { if !$0 { library.resolveLargeFolder(.cancel) } }
            ),
            presenting: library.pendingLargeFolder
        ) { _ in
            Button("Add Anyway") { library.resolveLargeFolder(.addAnyway) }
            Button("Choose a Subfolder…") { library.resolveLargeFolder(.chooseSubfolder) }
            Button("Cancel", role: .cancel) { library.resolveLargeFolder(.cancel) }
        } message: { prompt in
            Text(Self.explanation(prompt.estimate))
        }
    }

    /// What the one-second probe actually saw, rather than a guess dressed as a
    /// total. It stopped early, so "at least" is the only honest quantifier.
    static func explanation(_ estimate: Library.FolderSizeEstimate) -> String {
        let items = estimate.itemsSeen.formatted()
        let folders = estimate.directoriesRemaining
        var text = "A quick look found at least \(items) items"
        if folders > 0 {
            text += " and hadn't finished \(folders.formatted()) more folder"
            text += folders == 1 ? "" : "s"
        }
        text += ". Indexing it will take a while, and every scan afterwards too."
        return text
    }
}

extension View {
    /// Present the library's large-folder question, wherever the shell is.
    func largeFolderAlert(_ library: Library) -> some View {
        modifier(LargeFolderAlert(library: library))
    }
}
