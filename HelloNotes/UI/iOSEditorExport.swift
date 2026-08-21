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
}
#endif
