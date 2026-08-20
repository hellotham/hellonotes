//
//  FolderPicker.swift
//  HelloNotes
//
//  Lifted out of `iOSContentView` so anything that needs a folder can ask for
//  one. `NewRepositoryView` and `CloneRepositoryView` were `#if os(macOS)`
//  largely because they reached for `NSOpenPanel`; this is the iOS answer, and
//  it already existed a few hundred lines away.
//

#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The system folder picker, opened at a chosen directory.
///
/// SwiftUI's `.fileImporter` cannot do that, which is the whole reason this
/// exists. Folders only, multiple selection allowed, and the picked URLs stay
/// security-scoped for the caller to open.
struct FolderPicker: UIViewControllerRepresentable {
    let startingAt: URL?
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // `.folder` *and* `.directory`: providers differ in which of the two they
        // vend, and a provider whose folders match neither leaves them
        // unselectable — you can browse in but never choose. `.directory` is
        // the broader of the pair, so accepting both costs nothing and admits
        // providers that only declare the base type.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder, .directory],
                                                    asCopy: false)
        picker.allowsMultipleSelection = true
        // A hint the picker resolves out of process; harmless if it cannot.
        picker.directoryURL = startingAt
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick([])
        }
    }
}
#endif
