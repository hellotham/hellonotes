//
//  EditorExport.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// macOS export helpers: write a note's HTML/PDF via a save panel. PDF is
/// produced by the native text system (no WebView) from the exported HTML.
@MainActor
enum EditorExport {

    static func exportHTML(markdown: String, title: String) {
        let html = MarkdownExport.html(from: markdown, title: title)
        save(data: html.data(using: .utf8), suggestedName: "\(title).html", type: .html)
    }

    static func exportPDF(markdown: String, title: String) {
        let html = MarkdownExport.html(from: markdown, title: title)
        save(data: pdfData(fromHTML: html), suggestedName: "\(title).pdf", type: .pdf)
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
            try data.write(to: url, options: .atomic)
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

    /// Render the HTML to a single-page PDF via an offscreen `NSTextView`
    /// (the text system's HTML importer — not a WebView).
    private static func pdfData(fromHTML html: String) -> Data? {
        guard let htmlData = html.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: htmlData,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ],
                documentAttributes: nil
              ) else { return nil }

        let pageWidth: CGFloat = 612  // US Letter, 72 dpi
        let margin: CGFloat = 48
        let contentWidth = pageWidth - margin * 2

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 100))
        textView.isEditable = false
        textView.textContainerInset = NSSize(width: 0, height: margin)
        textView.textStorage?.setAttributedString(attributed)

        guard let container = textView.textContainer, let layout = textView.layoutManager else { return nil }
        layout.ensureLayout(for: container)
        let usedHeight = layout.usedRect(for: container).height + margin * 2
        textView.setFrameSize(NSSize(width: contentWidth, height: max(usedHeight, 200)))

        // Centre the content column on a page-width canvas.
        let page = NSView(frame: NSRect(x: 0, y: 0, width: pageWidth, height: textView.frame.height))
        textView.setFrameOrigin(NSPoint(x: margin, y: 0))
        page.addSubview(textView)

        return page.dataWithPDF(inside: page.bounds)
    }
}
#endif
