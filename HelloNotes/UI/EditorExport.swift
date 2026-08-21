//
//  EditorExport.swift
//  HelloNotes
//
//  Export a note as HTML or PDF, and print it — one type, both platforms.
//
//  There were two, `EditorExport` and `iOSEditorExport`, with byte-identical
//  public signatures (`exportHTML`, `exportPDF`, `printNote`, all
//  `(markdown:title:)`) and no relationship in the type system. Every caller
//  therefore had to know which platform it was on to name the type — which is
//  how `NoteMenuActions.exportHTML` ended up wired to one enum on the Mac and a
//  different enum on iPad, free to diverge in what they produced.
//
//  They already had: the page margin was 48pt on macOS and 36pt on iOS, under a
//  comment on the iOS side claiming it produced "the same page shape the Mac's
//  export produces". Two constants that must agree, in two files neither of
//  which mentions the other. `ExportPage` below is what they agree through now.
//
//  One enum, three entry points, and the platform inside each — a save panel
//  and `NSPrintOperation` on one side, a share sheet and
//  `UIPrintInteractionController` on the other. Both render the same GFM HTML,
//  which is the part that decides what the file actually looks like.
//

import Foundation
import CoreGraphics
import GFMRender
#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers
#else
import UIKit
#endif

/// The page an export or a print lands on — shared, because the two exporters
/// each hard-coded it and disagreed.
///
/// The margin was 48pt on macOS and 36pt on iOS, under a comment on the iOS
/// side claiming it produced "the same page shape the Mac's export produces".
/// Two constants that must agree, in two files neither of which mentioned the
/// other, is a promise nothing enforces — and it was already broken, silently,
/// because nobody exports the same note from both devices and measures.
enum ExportPage {
    /// US Letter at 72 dpi.
    static let width: CGFloat = 612
    static let height: CGFloat = 792
    /// Two-thirds of an inch on every side — the Mac's print margin, so an
    /// exported PDF and a printed page share a measure as well as a renderer.
    static let margin: CGFloat = 48
}

@MainActor
enum EditorExport {
#if os(macOS)

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
#else


    /// Render `markdown` to HTML and hand the file to the share sheet.
    static func exportHTML(markdown: String, title: String) {
        let html = GFMRenderer.page(markdown, title: title)
        share(data: Data(html.utf8), filename: "\(safe(title)).html")
    }

    /// Render `markdown` to a paginated PDF and hand it to the share sheet.
    ///
    /// Printed through `UIPrintPageRenderer` against the same GFM HTML the
    /// Preview shows, so an exported PDF matches what was on screen rather than
    /// being a second, subtly different renderer.
    static func exportPDF(markdown: String, title: String) {
        let html = GFMRenderer.page(markdown, title: title)
        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)

        // The same page shape the Mac's export produces — and now literally the
        // same numbers, from `ExportPage`. It used to say this while insetting
        // by 36pt against the Mac's 48pt: a comment claiming a parity that two
        // hard-coded constants in two files could not keep.
        let page = CGRect(x: 0, y: 0, width: ExportPage.width, height: ExportPage.height)
        let printable = page.insetBy(dx: ExportPage.margin, dy: ExportPage.margin)
        renderer.setValue(page, forKey: "paperRect")
        renderer.setValue(printable, forKey: "printableRect")

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, page, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        for index in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: index, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        share(data: data as Data, filename: "\(safe(title)).pdf")
    }

    /// Send the rendered note to the system print panel.
    static func printNote(markdown: String, title: String) {
        let html = GFMRenderer.page(markdown, title: title)
        let info = UIPrintInfo.printInfo()
        info.outputType = .general
        info.jobName = title
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printFormatter = UIMarkupTextPrintFormatter(markupText: html)
        controller.present(animated: true)
    }

    // MARK: - Private

    /// Write to a temporary file and present the share sheet over whatever is
    /// frontmost. A temp file rather than raw `Data` so the sheet shows a real
    /// filename and extension — "HelloNotes.pdf", not "Item". An uncoordinated
    /// write is right here: the temporary directory is ours and local, not
    /// vault content on a cloud volume, which is what `FileIO` exists for.
    private static func share(data: Data, filename: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            // Say so. This used to be `catch { return }`, which made a failed
            // export look exactly like a cancelled one — the share sheet simply
            // never appeared, and the user was left to guess which had happened.
            // The Mac has always raised an alert on a failed write.
            presentError("HelloNotes couldn't write “\(filename)”: \(error.localizedDescription)")
            return
        }

        guard let presenter = frontmostViewController() else {
            presentError("HelloNotes couldn't find a window to share “\(filename)” from.")
            return
        }

        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // Required on iPad: an unanchored popover is a crash, not a no-op.
        sheet.popoverPresentationController?.sourceView = presenter.view
        sheet.popoverPresentationController?.sourceRect = CGRect(
            x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
        sheet.popoverPresentationController?.permittedArrowDirections = []
        presenter.present(sheet, animated: true)
    }

    /// The controller a sheet or alert can actually be presented from — the
    /// top of the presentation stack, not the root. Presenting on a controller
    /// that is already presenting something is a silent no-op with a console
    /// warning, which is the same invisible failure this file just stopped
    /// having.
    private static func frontmostViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              var top = scene.keyWindow?.rootViewController
        else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    private static func presentError(_ message: String) {
        guard let presenter = frontmostViewController() else { return }
        let alert = UIAlertController(title: "Export failed", message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter.present(alert, animated: true)
    }

    private static func safe(_ title: String) -> String {
        let cleaned = title.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Note" : cleaned
    }
#endif
}
