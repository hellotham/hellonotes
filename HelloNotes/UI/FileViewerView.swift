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

// MARK: - CSV / TSV

private struct CSVTableView: View {
    let url: URL

    @State private var rows: [[String]] = []
    @State private var truncated = false
    @State private var error: String?

    private let rowCap = 2000

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView("Couldn't read this file", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if rows.isEmpty {
                ContentUnavailableView("Empty", systemImage: "tablecells")
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            GridRow {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                    Text(cell)
                                        .font(index == 0 ? .callout.bold() : .callout)
                                        .lineLimit(1)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .frame(minWidth: 60, maxWidth: 320, alignment: .leading)
                                }
                            }
                            .background(index == 0 ? Color.secondary.opacity(0.18)
                                        : (index.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.06)))
                            Divider()
                        }
                    }
                    if truncated {
                        Text("… showing the first \(rowCap) rows")
                            .font(.caption).foregroundStyle(.secondary).padding(8)
                    }
                }
            }
        }
        .task(id: url) { await load() }
    }

    /// Read and parse off the main actor. A coordinated read of a file that
    /// isn't local yet blocks for as long as its provider takes, and parsing a
    /// large CSV is not free either — neither belongs on the thread drawing the
    /// window.
    private func load() async {
        rows = []; truncated = false; error = nil
        let url = self.url
        let cap = rowCap
        let parsed = await offMain { () -> (rows: [[String]], truncated: Bool)? in
            guard let text = try? FileIO.readString(at: url) else { return nil }
            let delimiter: Character = url.pathExtension.lowercased() == "tsv" ? "\t" : ","
            var rows = CSVParser.parse(text, delimiter: delimiter)
            let truncated = rows.count > cap
            if truncated { rows = Array(rows.prefix(cap)) }
            return (rows, truncated)
        }
        guard let parsed else {
            error = "The file isn't valid UTF-8 text."
            return
        }
        rows = parsed.rows
        truncated = parsed.truncated
    }
}

/// Minimal RFC-4180-ish CSV parser: handles quoted fields, escaped quotes
/// (`""`), and embedded newlines/delimiters inside quotes.
enum CSVParser {
    static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var record: [String] = []
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        func nextChar() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }

        while let ch = nextChar() {
            if inQuotes {
                if ch == "\"" {
                    if let peek = iterator.next() {
                        if peek == "\"" { field.append("\"") }       // escaped quote
                        else { inQuotes = false; pending = peek }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else {
                switch ch {
                case "\"": inQuotes = true
                case delimiter: record.append(field); field = ""
                case "\n":
                    record.append(field); field = ""
                    rows.append(record); record = []
                case "\r":
                    break  // handle CRLF: ignore CR; LF ends the row
                default: field.append(ch)
                }
            }
        }
        // Flush the final field/record if the file didn't end with a newline.
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            rows.append(record)
        }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }
}
#endif
