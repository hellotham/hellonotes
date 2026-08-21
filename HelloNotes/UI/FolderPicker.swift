//
//  FolderPicker.swift
//  HelloNotes
//
//  Lifted out of `iOSContentView` so anything that needs a folder can ask for
//  one. `NewRepositoryView` and `CloneRepositoryView` were `#if os(macOS)`
//  largely because they reached for `NSOpenPanel`; this is the iOS answer, and
//  it already existed a few hundred lines away.
//

import SwiftUI
#if os(iOS)
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

#else
import AppKit

/// The Mac's folder picker.
///
/// An `NSOpenPanel` run when the view appears, rather than a representable:
/// AppKit's panel is a window of its own, not a view to embed. Presented the
/// same way as the iOS picker — in a sheet — so a caller asks for a folder
/// identically on both platforms instead of choosing between a view here and a
/// method on `Library` there.
struct FolderPicker: View {
    let startingAt: URL?
    let onPick: ([URL]) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Nothing to draw: the panel is the UI. A zero-size view keeps the
        // sheet from flashing a blank card behind it.
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = true
                panel.prompt = "Open"
                panel.directoryURL = startingAt
                let urls = panel.runModal() == .OK ? panel.urls : []
                dismiss()
                // After the dismiss, so the caller's sheet is already down when
                // whatever it opens wants to present something of its own.
                if !urls.isEmpty { onPick(urls) }
            }
    }
}
#endif
