//
//  FileOperationAlerts.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//

import SwiftUI

/// Presents `Collection.lastError` (a failed file operation) as an alert and
/// clears it on dismiss.
///
/// A `ViewModifier` rather than an `.alert` in the shell body: that chain is
/// already long enough to defeat the type-checker, which it did the first time
/// these were added.
struct FileOperationErrorAlert: ViewModifier {
    var collection: Collection?
    func body(content: Content) -> some View {
        content.alert(
            "Couldn't complete that",
            isPresented: Binding(
                get: { collection?.lastError != nil },
                set: { if !$0 { collection?.lastError = nil } }
            ),
            presenting: collection?.lastError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0) }
    }
}

/// Confirms a folder "Move to Trash", which trashes everything inside it. A tap
/// that can take a hundred notes with it asks first — on both platforms, from
/// one implementation, because two copies of a destructive confirmation is two
/// chances for one of them to lose its warning.
struct FolderDeleteConfirmation: ViewModifier {
    @Binding var folder: URL?
    var onConfirm: (URL) -> Void
    func body(content: Content) -> some View {
        content.confirmationDialog(
            folder.map { "Move “\($0.lastPathComponent)” and its contents to the Trash?" } ?? "",
            isPresented: Binding(get: { folder != nil }, set: { if !$0 { folder = nil } }),
            titleVisibility: .visible,
            presenting: folder
        ) { f in
            Button("Move to Trash", role: .destructive) { onConfirm(f) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Everything inside the folder will be moved to the Trash. You can recover it from there.")
        }
    }
}
