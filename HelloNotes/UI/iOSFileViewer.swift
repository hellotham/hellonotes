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
import MarkdownEditor
import QuickLook
import UniformTypeIdentifiers

/// Quick Look, hosted in the detail column, with the two pieces its Mac twin
/// has and this file used to be missing: something to look at while an
/// online-only file downloads, and a reload once the bytes land.
struct iOSFileViewer: View {
    let url: URL

    @State private var isDownloading = false
    /// Bumped after a download so the viewer re-reads a file whose bytes have
    /// just changed underneath it. Quick Look caches by URL, and the URL is
    /// exactly what did *not* change.
    @State private var contentRevision = 0

    var body: some View {
        Group {
            if isDownloading {
                // The file exists and has no content yet. Saying so beats
                // rendering a placeholder, which Quick Look draws as simply
                // nothing — indistinguishable from a document that failed to
                // open, and permanent, because nothing was ever going to
                // reload it.
                ContentUnavailableView {
                    Label("Downloading “\(url.lastPathComponent)”", systemImage: "arrow.down.circle")
                } description: {
                    Text("Fetching it from the cloud.")
                }
            } else if CollectionFileKind.of(url) == .csv {
                // Same dispatch the Mac makes, for the same reason: Quick Look
                // *can* open a .csv, and what it shows is the raw comma-
                // separated text. A spreadsheet whose columns are gone is not a
                // spreadsheet, so both platforms route it to the same table.
                CSVTableView(url: url).id(viewerIdentity)
            } else {
                QuickLookViewer(url: url).id(viewerIdentity)
            }
        }
        .task(id: url) { await materialise() }
    }

    /// URL *and* revision: the same file with different bytes is a different
    /// thing to render.
    private var viewerIdentity: String { "\(url.path)#\(contentRevision)" }

    /// Fetch an online-only file, say so while it happens, and force a reload
    /// when it lands.
    ///
    /// The old version fired `FileIO.download` and returned. That call is
    /// documented as returning without waiting, and the only reload here was
    /// gated on the URL changing — which is the one thing that does *not*
    /// change when a download completes. So an online-only attachment previewed
    /// as a blank page for as long as you looked at it, and only came right if
    /// you selected something else and came back.
    private func materialise() async {
        guard Self.isOnlineOnly(url) else {
            isDownloading = false
            return
        }
        isDownloading = true
        // Throws only for a non-ubiquitous item, which the guard above has
        // already excluded.
        try? FileIO.download(at: url)

        // No completion handler exists for `startDownloadingUbiquitousItem`, so
        // watch the item's own downloading status. The cap is there so a
        // provider that never finishes leaves the user with a preview attempt
        // rather than a spinner with no end.
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            // Throws on cancellation — the selection changed, and the task that
            // replaced this one owns the state now. Returning without touching
            // it is what keeps a cancelled download from clearing a live one's
            // progress view.
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            if !Self.isOnlineOnly(url) { break }
        }

        guard !Task.isCancelled else { return }
        isDownloading = false
        contentRevision &+= 1
    }

    /// A cloud item whose bytes are not here yet. False for a local file, and
    /// for a cloud file already fully downloaded.
    private static func isOnlineOnly(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ])
        guard values?.isUbiquitousItem == true else { return false }
        return values?.ubiquitousItemDownloadingStatus != .current
    }
}

private struct QuickLookViewer: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }

    // Viewport sizing (S1): take what we're offered, never the file's natural
    // size. A `QLPreviewController` sizes itself to the document it is showing,
    // and reporting that upwards inflates every ancestor until the top of the
    // detail column sits above the window. See docs/layout-architecture.md.
    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: QLPreviewController,
                      context: Context) -> CGSize? { viewportSizeThatFits(proposal) }

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
