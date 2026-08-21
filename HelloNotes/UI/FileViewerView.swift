//
//  FileViewerView.swift
//  HelloNotes
//
//  Previewing a non-note file in the detail column — one view, both platforms.
//
//  There were two, and they had drifted into disagreeing about what previewing
//  a file *is*. The Mac dispatched on `CollectionFile.kind` (PDF → PDFKit,
//  CSV → a table, the rest → Quick Look) and drew a bottom bar with "Open in
//  default app" and "Reveal in Finder". iOS took a bare `URL`, sent everything
//  to Quick Look, and had no bar at all — so on iPad a spreadsheet opened as a
//  wall of comma-separated text and there was no way to hand the file to
//  another app.
//
//  They also disagreed about *when* the bytes arrive. The Mac was handed
//  `isPlaceholder` / `prepare` by the shell — the collection knows how to
//  hydrate its own files — while iOS re-implemented hydration here against
//  iCloud's ubiquitous-item status. Both are needed: a direct-API collection
//  hydrates through its provider and a Files-backed one through iCloud, and
//  either shell may hand over either. So the callbacks are used when supplied
//  and the ubiquitous-item watch is the fallback, on both platforms.
//
//  Three things differ underneath and each has an `#else`: the PDF, Quick Look
//  and "open in the default app" representables. PDFKit ships on both, so even
//  the PDF path is the same decision either side of the gate.
//

import SwiftUI
import PDFKit
import MarkdownEditor   // viewportSizeThatFits (S1)
#if canImport(AppKit)
import AppKit
import QuickLookUI
#else
import UIKit
import QuickLook
#endif

struct FileViewerView: View {
    let file: CollectionFile

    /// Whether this file is only a placeholder — a name at a real path standing
    /// in for content still on the provider.
    var isPlaceholder: (@MainActor (URL) -> Bool)?
    /// Fetch that content. No-op for a local collection or an already-fetched
    /// file, so it is safe to call on every selection.
    var prepare: (@MainActor (URL) async -> Void)?

    @State private var isDownloading = false
    /// Bumped after a download so the viewer re-reads a file whose bytes have
    /// just changed underneath it. PDFKit and Quick Look cache by URL, and the
    /// URL is exactly what did *not* change.
    @State private var contentRevision = 0

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            bottomBar
        }
        .task(id: file.url) { await materialise() }
    }

    @ViewBuilder
    private var content: some View {
        if isDownloading {
            // The file exists and has no content yet. Saying so beats rendering
            // a zero-byte placeholder, which Quick Look draws as simply nothing
            // — indistinguishable from a document that failed to open, and
            // permanent, because nothing was going to reload it.
            ContentUnavailableView {
                Label("Downloading “\(file.name)”", systemImage: "arrow.down.circle")
            } description: {
                Text("Fetching it from the cloud.")
            }
        } else {
            switch file.kind {
            case .pdf:
                PDFKitViewer(url: file.url).id(viewerIdentity)
            case .csv:
                CSVTableView(url: file.url).id(viewerIdentity)
            case .image, .other:
                QuickLookViewer(url: file.url).id(viewerIdentity)
            }
        }
    }

    /// URL *and* revision: the same file with different bytes is a different
    /// thing to render.
    private var viewerIdentity: String { "\(file.url.path)#\(contentRevision)" }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Label(file.name, systemImage: file.kind.symbol)
                .foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 12)
            Button {
                ExternalURL.open(file.url)
            } label: {
                Image(systemName: "arrow.up.forward.app").frame(width: 22, height: 18)
            }
            .buttonStyle(.borderless)
            .help("Open in default app")
            .accessibilityLabel("Open in default app")

            if FileReveal.canReveal(file.url) {
                Button {
                    FileReveal.reveal(file.url)
                } label: {
                    Image(systemName: "folder").frame(width: 22, height: 18)
                }
                .buttonStyle(.borderless)
                .help(FileReveal.revealTitle)
                .accessibilityLabel(FileReveal.revealTitle)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.bar)
    }

    // MARK: - Getting the bytes here

    /// Hydrate the file if it is not local yet, saying so while it happens and
    /// forcing a reload when it lands.
    ///
    /// The shell's `prepare` first, because a collection that mirrors a provider
    /// knows how to fetch its own files. Failing that, the iCloud path: watch
    /// the item's own downloading status, because `startDownloadingUbiquitousItem`
    /// has no completion handler and the URL — the only thing `.task(id:)` keys
    /// on — is exactly what does *not* change when the download completes. An
    /// earlier version fired the download and returned, so an online-only
    /// attachment previewed as a blank page for as long as you looked at it.
    private func materialise() async {
        if let prepare {
            let needed = isPlaceholder?(file.url) ?? false
            if needed { isDownloading = true }
            await prepare(file.url)
            if needed {
                isDownloading = false
                contentRevision &+= 1
            }
            return
        }

        guard Self.isOnlineOnly(file.url) else {
            isDownloading = false
            return
        }
        isDownloading = true
        // Throws only for a non-ubiquitous item, which the guard has excluded.
        try? FileIO.download(at: file.url)

        // The cap is there so a provider that never finishes leaves the user
        // with a preview attempt rather than a spinner with no end.
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            // Throws on cancellation — the selection changed, and the task that
            // replaced this one owns the state now. Returning without touching
            // it is what keeps a cancelled download from clearing a live one's
            // progress view.
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            if !Self.isOnlineOnly(file.url) { break }
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

// MARK: - PDF

/// PDFKit ships on both platforms, so the *decision* is shared and only the
/// representable conformance differs — which is what an `#else` is for.
#if canImport(AppKit)
private struct PDFKitViewer: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView { Self.make(url) }
    func updateNSView(_ view: PDFView, context: Context) { Self.update(view, url) }
    // Viewport sizing (S1): take what we're offered, never the PDF's own size.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PDFView,
                      context: Context) -> CGSize? { viewportSizeThatFits(proposal) }
}
#else
private struct PDFKitViewer: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PDFView { Self.make(url) }
    func updateUIView(_ view: PDFView, context: Context) { Self.update(view, url) }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PDFView,
                      context: Context) -> CGSize? { viewportSizeThatFits(proposal) }
}
#endif

extension PDFKitViewer {
    /// The part that is not platform-shaped: how a PDF is configured for
    /// reading, which used to exist on macOS only and is now what iPad gets
    /// instead of Quick Look's flat rendering of the same file.
    static func make(_ url: URL) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }

    static func update(_ view: PDFView, _ url: URL) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}

// MARK: - Quick Look (images, SVG, and anything else)

#if canImport(AppKit)
private struct QuickLookViewer: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }
    // Viewport sizing (S1): take what we're offered, never the file's natural size.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: QLPreviewView,
                      context: Context) -> CGSize? { viewportSizeThatFits(proposal) }
}
#else
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

    // Viewport sizing (S1): a `QLPreviewController` sizes itself to the document
    // it is showing, and reporting that upwards inflates every ancestor until
    // the top of the detail column sits above the window.
    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: QLPreviewController,
                      context: Context) -> CGSize? { viewportSizeThatFits(proposal) }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
#endif
