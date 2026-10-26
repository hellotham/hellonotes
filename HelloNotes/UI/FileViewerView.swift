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
//  hydrates through its provider and a Files-backed one through iCloud. The
//  callbacks became "used when supplied, iCloud the fallback" — and the one
//  shell always supplies them, so the iCloud wait was never reached and an
//  attachment iCloud held online-only previewed blank for good. One decision
//  now, for either kind of collection, with an end (`AttachmentBytes`,
//  docs/implemented.md §51.52).
//
//  Three things differ underneath and each has an `#else`: the PDF, Quick Look
//  and "open in the default app" representables. PDFKit ships on both, so even
//  the PDF path is the same decision either side of the gate.
//

import SwiftUI
import PDFKit
import Synchronization
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

    /// Getting the bytes here, and what to say meanwhile.
    @State private var bytes = AttachmentBytes()
    /// Bumped by Try Again, which the fetch is keyed on with the file.
    @State private var attempt = 0
    /// Why the PDF could not be opened, for the file and revision it was read
    /// at (`viewerIdentity`), so no other is told. A PDF that could not be
    /// read drew an empty view, which looked like one still coming.
    @State private var unreadable: Unreadable?
    private struct Unreadable { let identity: String; let why: String }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ChromeDivider()
            bottomBar
        }
        .task(id: "\(file.url.path)#\(attempt)") {
            await bytes.fetch(file.url, isPlaceholder: isPlaceholder, prepare: prepare)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch bytes.state {
        case .checking:
            // The moment it takes to ask — nothing drawn, rather than a
            // stand-in previewed as a blank page.
            Color.clear
        case .downloading:
            // The file exists and has no content yet. Saying so beats rendering
            // a zero-byte placeholder, which Quick Look draws as simply nothing
            // — indistinguishable from a document that failed to open.
            ChromeEmptyState("Downloading “\(file.name)”", systemImage: "arrow.down.circle",
                             description: Text("Fetching it from the cloud."))
        case .missing(let why):
            ChromeEmptyState("“\(file.name)” isn’t on this device", systemImage: "icloud.slash",
                             description: Text(why)) {
                Button("Try Again") { attempt &+= 1 }
            }
        case .here:
            switch file.kind {
            case .pdf:
                if let unreadable, unreadable.identity == viewerIdentity {
                    ChromeEmptyState("Couldn’t open “\(file.name)”", systemImage: "exclamationmark.triangle",
                                     description: Text(unreadable.why)) {
                        Button("Try Again") {
                            self.unreadable = nil
                            attempt &+= 1
                        }
                    }
                } else {
                    let identity = viewerIdentity
                    PDFKitViewer(url: file.url) { why in unreadable = Unreadable(identity: identity, why: why) }
                        .id(viewerIdentity)
                }
            case .csv:
                CSVTableView(url: file.url).id(viewerIdentity)
            case .image, .other:
                QuickLookViewer(url: file.url).id(viewerIdentity)
            }
        }
    }

    /// URL *and* revision: the same file with different bytes is a different
    /// thing to render. PDFKit and Quick Look cache by URL, and the URL is
    /// exactly what does not change when a download lands.
    private var viewerIdentity: String { "\(file.url.path)#\(bytes.revision)" }

    /// Whether the fetch found the file not here.
    private var isMissing: Bool {
        if case .missing = bytes.state { return true }
        return false
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Label(file.name, systemImage: file.kind.symbol)
                .foregroundStyle(Chrome.Colour.secondaryLabel).lineLimit(1)
            Spacer(minLength: 12)
            Button {
                ExternalURL.open(file.url)
            } label: {
                Image(systemName: "arrow.up.forward.app").frame(width: 22, height: 18)
            }
            .buttonStyle(ChromeBorderlessStyle())
            .help("Open in default app")
            .accessibilityLabel("Open in default app")

            // Unless the file is known not to be here — the viewer's own fetch
            // knows (`AttachmentBytes`); a look at the disk here was one on
            // the main thread every time the bar was drawn (implemented.md
            // §51.67).
            if !isMissing {
                Button {
                    FileReveal.reveal(file.url)
                } label: {
                    Image(systemName: "folder").frame(width: 22, height: 18)
                }
                .buttonStyle(ChromeBorderlessStyle())
                .help(FileReveal.revealTitle)
                .accessibilityLabel(FileReveal.revealTitle)
            }
        }
        .font(Chrome.Style.callout)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .chromeBackground()
    }
}

// MARK: - PDF

/// PDFKit ships on both platforms, so the *decision* is shared and only the
/// representable conformance differs — which is what an `#else` is for.
#if canImport(AppKit)
private struct PDFKitViewer: NSViewRepresentable {
    let url: URL
    let onUnreadable: @MainActor (String) -> Void
    func makeNSView(context: Context) -> FilePDFView { Self.make(url, onUnreadable) }
    func updateNSView(_ view: FilePDFView, context: Context) { Self.update(view, url, onUnreadable) }
    static func dismantleNSView(_ view: FilePDFView, coordinator: ()) { view.stop() }
    // Viewport sizing (S1): take what we're offered, never the PDF's own size.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FilePDFView,
                      context: Context) -> CGSize? { viewportSizeThatFits(proposal) }
}
#else
private struct PDFKitViewer: UIViewRepresentable {
    let url: URL
    let onUnreadable: @MainActor (String) -> Void
    func makeUIView(context: Context) -> FilePDFView { Self.make(url, onUnreadable) }
    func updateUIView(_ view: FilePDFView, context: Context) { Self.update(view, url, onUnreadable) }
    static func dismantleUIView(_ view: FilePDFView, coordinator: ()) { view.stop() }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: FilePDFView,
                      context: Context) -> CGSize? { viewportSizeThatFits(proposal) }
}
#endif

extension PDFKitViewer {
    /// The part that is not platform-shaped: how a PDF is configured for
    /// reading, which used to exist on macOS only and is now what iPad gets
    /// instead of Quick Look's flat rendering of the same file.
    static func make(_ url: URL, _ onUnreadable: @escaping @MainActor (String) -> Void) -> FilePDFView {
        let view = FilePDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.onUnreadable = onUnreadable
        view.show(url)
        return view
    }

    static func update(_ view: FilePDFView, _ url: URL, _ onUnreadable: @escaping @MainActor (String) -> Void) {
        view.onUnreadable = onUnreadable
        view.show(url)
    }
}

/// A `PDFView` whose document is read through `FileIO` and made off the main
/// actor, and that knows which file it is showing — a document made from data
/// has no `documentURL` to ask. `PDFDocument(url:)` read the file raw, outside
/// coordination, and on the main thread, so a PDF its provider still held, or
/// still had to download, held the app until it let go (implemented.md §51.64).
///
/// - **On lanes of their own** (`calls`), a file always on the same one: the
///   read holds up no one else's open, save or rename. A lane a view, and a
///   PDF its provider held kept one more thread each time it was opened
///   again; here it holds its one lane however often it is opened.
/// - **Mapped** (`.mappedIfSafe`), not read whole onto the heap:
///   `PDFDocument(url:)` read pages as it drew them, and a scanned book held
///   in memory is how an iPad ends an app.
/// - **Made into a document on the lane**: a damaged cross-reference table is
///   rebuilt by reading the whole file — 246 ms of the main actor for one of
///   109 MB.
/// - **Not read for a view that has gone** (`stop`), and **a failure is
///   said** (`onUnreadable`).
final class FilePDFView: PDFView {
    private(set) var shownURL: URL?
    /// Told why the PDF cannot be shown.
    var onUnreadable: (@MainActor (String) -> Void)?
    /// Where PDF views read — for a test to wait on.
    static let calls = FileIO.ProviderCalls(isHere: FileIO.ProviderCalls.live.isHere,
                                            askFor: FileIO.ProviderCalls.live.askFor,
                                            lanes: FileIO.ProviderCalls.makeLanes("com.hellotham.HelloNotes.pdf-view"))
    private let gone = Gone()

    func show(_ url: URL) {
        guard url != shownURL else { return }
        shownURL = url
        document = nil
        let gone = self.gone
        Task { [weak self] in
            let opened = await Self.calls.onLane(for: url) { () -> Opened in
                guard !gone.isSet else { return .gone }
                let data: Data
                do { data = try FileIO.readData(at: url, options: .mappedIfSafe) } catch {
                    return .unreadable(error.localizedDescription)
                }
                guard !gone.isSet else { return .gone }
                guard let document = PDFDocument(data: data) else {
                    return .unreadable(String(localized: "It isn’t a PDF this device can read."))
                }
                return .opened(Handed(document: document))
            }
            guard let self, self.shownURL == url, !gone.isSet else { return }
            switch opened {
            case .opened(let handed): self.document = handed.document
            case .unreadable(let why): self.onUnreadable?(why)
            case .gone: break
            }
        }
    }

    /// The view has gone: a read not yet begun is not begun, and nothing read
    /// is shown.
    func stop() { gone.set() }

    nonisolated private enum Opened: Sendable {
        case opened(Handed), unreadable(String), gone
    }

    /// A document made on the lane and handed over whole: nothing there
    /// touches it after.
    nonisolated private struct Handed: @unchecked Sendable { let document: PDFDocument }

    /// Whether the view a read is for has gone — asked on the lane, where the
    /// view cannot be.
    nonisolated private final class Gone: Sendable {
        private let flag = Atomic(false)
        func set() { flag.store(true, ordering: .relaxed) }
        var isSet: Bool { flag.load(ordering: .relaxed) }
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
