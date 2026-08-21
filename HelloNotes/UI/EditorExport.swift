//
//  EditorExport.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import CoreGraphics

/// The page an exported or printed note is laid out on.
///
/// **Deliberately outside the `#if os(macOS)` below**, and read by
/// `iOSEditorExport` too. This geometry lived twice — 48pt margins on the Mac,
/// 36pt on iOS under a comment claiming it produced "the same page shape the
/// Mac's export produces". Two constants that must agree, in two files neither
/// of which mentions the other, is a promise nothing enforces; it was already
/// broken, and silently, because nobody exports the same note from both
/// devices and measures.
enum ExportPage {
    /// US Letter at 72 dpi.
    static let width: CGFloat = 612
    static let height: CGFloat = 792
    /// Two-thirds of an inch on every side — the Mac's print margin, so an
    /// exported PDF and a printed page share a measure as well as a renderer.
    static let margin: CGFloat = 48
}

#if os(macOS)
import AppKit
import GFMRender
import UniformTypeIdentifiers

/// macOS export helpers: write a note's HTML/PDF via a save panel. PDF is
/// produced by the native text system (no WebView) from the exported HTML.
@MainActor
enum EditorExport {

    static func exportHTML(markdown: String, title: String) {
        let html = GFMRenderer.page(markdown, title: title)
        save(data: html.data(using: .utf8), suggestedName: "\(title).html", type: .html)
    }

    static func exportPDF(markdown: String, title: String) {
        let html = GFMRenderer.page(markdown, title: title)
        save(data: pdfData(fromHTML: html), suggestedName: "\(title).pdf", type: .pdf)
    }

    /// Print the note via the standard print panel, rendering its HTML through
    /// the native text system (no WebView).
    static func printNote(markdown: String, title: String) {
        let html = GFMRenderer.page(markdown, title: title)
        guard let attributed = attributed(fromHTML: html) else {
            presentError("Couldn't prepare “\(title)” for printing.")
            return
        }
        // The paper is the user's to choose in the print panel; only the
        // margins are ours, and they match the exported PDF's.
        let info = NSPrintInfo.shared
        applyMargins(to: info)
        let op = NSPrintOperation(view: paginatedTextView(attributed, printInfo: info),
                                  printInfo: info)
        op.jobTitle = title
        op.run()
    }

    // MARK: - Private

    private static func save(data: Data?, suggestedName: String, type: UTType) {
        guard let data else {
            presentError("HelloNotes couldn't generate the \(type == .pdf ? "PDF" : "document") to export.")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileIO.write(data, to: url)   // coordinated: the export target may be a cloud folder
        } catch {
            presentError("HelloNotes couldn't write “\(url.lastPathComponent)”: \(error.localizedDescription)")
        }
    }

    private static func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Export failed"
        alert.informativeText = message
        alert.runModal()
    }

    /// The text system's HTML importer — not a WebView.
    private static func attributed(fromHTML html: String) -> NSAttributedString? {
        guard let htmlData = html.data(using: .utf8) else { return nil }
        return try? NSAttributedString(
            data: htmlData,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil
        )
    }

    private static func applyMargins(to info: NSPrintInfo) {
        info.topMargin = ExportPage.margin
        info.bottomMargin = ExportPage.margin
        info.leftMargin = ExportPage.margin
        info.rightMargin = ExportPage.margin
    }

    /// An offscreen `NSTextView` laid out to the printable width and grown to
    /// its full content height, ready for `NSPrintOperation` to slice into
    /// pages. `NSTextView` overrides `adjustPageHeight` so the slices fall
    /// between lines rather than through them.
    private static func paginatedTextView(_ attributed: NSAttributedString,
                                          printInfo info: NSPrintInfo) -> NSTextView {
        let contentWidth = info.paperSize.width - info.leftMargin - info.rightMargin
        let contentHeight = info.paperSize.height - info.topMargin - info.bottomMargin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight))
        textView.isEditable = false
        // The margins are the print info's now; a container inset would add to
        // them and shrink the text column on every page.
        textView.textContainerInset = .zero
        textView.textStorage?.setAttributedString(attributed)

        if let container = textView.textContainer, let layout = textView.layoutManager {
            // Unbounded height, or the layout stops at one page's worth and
            // `usedRect` reports a document exactly one page long however many
            // it really is. (`size`, not the soft-deprecated `containerSize`.)
            container.size = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
            container.widthTracksTextView = true
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height
            textView.setFrameSize(NSSize(width: contentWidth, height: max(used, contentHeight)))
        }
        return textView
    }

    /// Render the HTML to a **paginated** PDF.
    ///
    /// It used to be one page as tall as the whole document —
    /// `page.dataWithPDF(inside: page.bounds)` over a view grown to the full
    /// text height — so a twenty-page note exported as one 15,840pt page that
    /// no printer, and few readers, will take. (iOS has always paginated, via
    /// `UIPrintPageRenderer.numberOfPages`.) `NSPrintOperation` with a save
    /// disposition is AppKit's pagination: the same machinery Print uses, run
    /// headlessly to a file, so the exported PDF and the printed page come out
    /// of one code path instead of two that drifted.
    private static func pdfData(fromHTML html: String) -> Data? {
        guard let attributed = attributed(fromHTML: html) else { return nil }

        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("hellonotes-export-\(UUID().uuidString).pdf")
        // The destination has to come in through the attribute dictionary —
        // `NSPrintInfo` has a typed `jobDisposition` but no typed saving URL.
        // Built here rather than by poking `info.dictionary()` afterwards
        // because this initialiser is keyed by `AttributeKey`, so a mistyped
        // key is a compile error instead of a job that prints to a printer.
        let info = NSPrintInfo(dictionary: [.jobSavingURL: target as NSURL])
        info.jobDisposition = .save
        info.paperSize = NSSize(width: ExportPage.width, height: ExportPage.height)
        applyMargins(to: info)
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        let op = NSPrintOperation(view: paginatedTextView(attributed, printInfo: info),
                                  printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { return nil }

        defer { try? FileManager.default.removeItem(at: target) }
        // A temp file we just wrote ourselves, so an uncoordinated read is
        // right here — `FileIO` exists for vault content on cloud volumes.
        return try? Data(contentsOf: target)
    }
}
#endif
