//
//  iOSEditorExport.swift
//  HelloNotes
//
//  Created by Chris Tham on 18/8/2026.
//
//  Export a note as HTML or PDF on iOS.
//
//  `EditorExport` is `#if os(macOS)` — it writes through `NSSavePanel` and
//  prints with `NSPrintOperation`, neither of which exists here. So an iPad
//  could not export or print a note at all. iOS has no save panel by design:
//  the equivalent is to produce the file and hand it to the share sheet, which
//  is also how it reaches Files, Mail, or another app.
//

#if os(iOS)
import UIKit
import GFMRender

enum iOSEditorExport {

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

        // US Letter at 72dpi, with a half-inch margin — the same page shape the
        // Mac's export produces.
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let printable = page.insetBy(dx: 36, dy: 36)
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
    /// filename and extension — "HelloNotes.pdf", not "Item".
    private static func share(data: Data, filename: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do { try data.write(to: url, options: .atomic) } catch { return }

        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.keyWindow?.rootViewController
        else { return }

        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // Required on iPad: an unanchored popover is a crash, not a no-op.
        sheet.popoverPresentationController?.sourceView = root.view
        sheet.popoverPresentationController?.sourceRect = CGRect(
            x: root.view.bounds.midX, y: root.view.bounds.midY, width: 0, height: 0)
        sheet.popoverPresentationController?.permittedArrowDirections = []
        root.present(sheet, animated: true)
    }

    private static func safe(_ title: String) -> String {
        let cleaned = title.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Note" : cleaned
    }
}
#endif
