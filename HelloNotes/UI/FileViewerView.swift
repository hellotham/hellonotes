//
//  FileViewerView.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Views a non-Markdown collection file in the detail column. Dispatches by kind:
//  PDF → PDFKit, CSV/TSV → a table, and everything else (images incl. SVG, and
//  arbitrary files) → QuickLook, which renders them natively. A bottom bar
//  offers "Open in Default App" and "Reveal in Finder".
//

#if os(macOS)
import SwiftUI
import MarkdownEditor
import AppKit
import PDFKit
import QuickLookUI

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
    /// just changed underneath it. PDFKit and QuickLook cache by URL, and the
    /// URL is exactly what did *not* change.
    @State private var contentRevision = 0

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            bottomBar
        }
        .task(id: file.url) {
            guard let prepare else { return }
            // Only announce a download that is actually going to happen.
            let needed = isPlaceholder?(file.url) ?? false
            if needed { isDownloading = true }
            await prepare(file.url)
            if needed {
                isDownloading = false
                contentRevision += 1
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isDownloading {
            // The file exists and has no content yet. Saying so beats rendering
            // a zero-byte placeholder, which QuickLook draws as simply nothing —
            // indistinguishable from a document that failed to open.
            ContentUnavailableView {
                Label("Downloading “\(file.name)”", systemImage: "arrow.down.circle")
            } description: {
                Text("Fetching it from the cloud.")
            }
        } else {
            switch file.kind {
            case .pdf:
                PDFKitView(url: file.url).id(viewerIdentity)
            case .csv:
                CSVTableView(url: file.url).id(viewerIdentity)
            case .image, .other:
                QuickLookView(url: file.url).id(viewerIdentity)
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
                NSWorkspace.shared.open(file.url)
            } label: { Image(systemName: "arrow.up.forward.app").frame(width: 22, height: 18) }
                .buttonStyle(.borderless).help("Open in default app").accessibilityLabel("Open in default app")
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            } label: { Image(systemName: "folder").frame(width: 22, height: 18) }
                .buttonStyle(.borderless).help("Reveal in Finder").accessibilityLabel("Reveal in Finder")
        }
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.bar)
    }
}

// MARK: - PDF

private struct PDFKitView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
    // Viewport sizing (S1): take what we're offered, never the PDF's own size.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PDFView,
                      context: Context) -> CGSize? { viewportSizeThatFits(proposal) }
}

// MARK: - QuickLook (images, SVG, and anything else)

private struct QuickLookView: NSViewRepresentable {
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
#endif
