//
//  iOSFileViewer.swift
//  HelloNotes
//
//  Previewing the non-note files that live in a collection — PDFs, images,
//  spreadsheets, anything else sitting beside the Markdown.
//
//  The Mac has `FileViewerView`, built on PDFKit and QuickLookUI, and it is
//  `#if os(macOS)` end to end. iPad listed those files, greyed them out, and
//  said so in a comment — "not selectable as notes" — which is true and was
//  never the point: they are not notes, they are *files*, and a knowledge base
//  whose attachments cannot be opened is a knowledge base with holes in it.
//
//  `QLPreviewController` rather than a per-format viewer: Quick Look already
//  renders PDF, RTF, images, audio, video, Keynote/Pages/Numbers, and the
//  Office formats, and it will keep gaining types without this file changing.
//

#if os(iOS)
import SwiftUI
import QuickLook
import UniformTypeIdentifiers

/// Quick Look, hosted in the detail column.
struct iOSFileViewer: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        Self.materialise(url)
        return controller
    }

    /// A file kept online-only previews as a blank page — Quick Look reads the
    /// placeholder, not the document. Asking for the download is cheap, returns
    /// immediately, and is a no-op for a file that is already local or is not a
    /// cloud item at all. The user's own vault has undownloaded attachments in
    /// it, so this is the common case rather than the edge one.
    private static func materialise(_ url: URL) {
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ])
        guard values?.isUbiquitousItem == true,
              values?.ubiquitousItemDownloadingStatus != .current else { return }
        try? FileIO.download(at: url)
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        Self.materialise(url)
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
#endif
