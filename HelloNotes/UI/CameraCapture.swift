//
//  CameraCapture.swift
//  HelloNotes
//
//  The camera, for Insert Image ▸ Take Photo… (`EditorImageSource.camera`):
//  a photo taken is saved into the collection beside the note, as a chosen
//  picture is, and its link put at the caret.
//

import SwiftUI

/// A photo taken, as the bytes to write — made when asked, off the main
/// actor (`EditorHost.insertNew`): encoding a twelve-megapixel photo as JPEG
/// takes 50 to 200 milliseconds, and made in the camera's delegate, on the
/// main thread, the camera hung on Use Photo for as long.
typealias PhotoBytes = @Sendable () -> Data?

#if os(iOS)
import UIKit

/// The system camera, full screen. A photo taken is handed back as its bytes
/// to be made (`PhotoBytes`) — `jpegData`, which keeps how the device was
/// held — and Cancel hands back nothing. `UIImagePickerController`, because
/// SwiftUI has no camera of its own.
struct CameraCapture: UIViewControllerRepresentable {
    var onFinish: (PhotoBytes?) -> Void

    /// Whether this device has a camera to take one with — not the
    /// simulator, and not a Mac running the iPad app.
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (PhotoBytes?) -> Void
        init(onFinish: @escaping (PhotoBytes?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let photo = info[.originalImage] as? UIImage
            onFinish(photo.map { photo -> PhotoBytes in { photo.jpegData(compressionQuality: 0.85) } })
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onFinish(nil) }
    }
}
#else
/// The Mac takes a photo with an iPhone or iPad near it — Continuity Camera,
/// in the editor's context menu (`MarkdownTextView.validRequestor`) — and has
/// no camera sheet of its own.
enum CameraCapture {
    static var isAvailable: Bool { false }
}
#endif
