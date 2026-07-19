//
//  ThumbnailProvider.swift
//  HelloNotesThumbnail
//
//  Quick Look thumbnails for `.md` files: a "note page" — the title (first
//  heading) plus the first lines, drawn on a card. Self-contained.
//

import QuickLookThumbnailing
import AppKit

class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let text = (try? String(contentsOf: request.fileURL, encoding: .utf8)) ?? ""
        let size = request.maximumSize
        handler(QLThumbnailReply(contextSize: size, drawing: { ctx in
            ThumbnailProvider.draw(text: text, in: size, context: ctx)
            return true
        }), nil)
    }

    static func draw(text: String, in size: CGSize, context: CGContext) {
        let nsctx = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsctx

        NSColor.textBackgroundColor.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()

        let lines = text.components(separatedBy: "\n")
        let title = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") })?
            .drop(while: { $0 == "#" || $0 == " " }).description
            ?? lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "Markdown"
        let body = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
            .prefix(12).joined(separator: "\n")

        let inset: CGFloat = size.width * 0.08
        let titleFont = NSFont.boldSystemFont(ofSize: max(11, size.height * 0.09))
        let bodyFont = NSFont.systemFont(ofSize: max(8, size.height * 0.05))
        let titleRect = CGRect(x: inset, y: size.height * 0.62, width: size.width - inset * 2, height: size.height * 0.3)
        let bodyRect = CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height * 0.5)

        (title as NSString).draw(in: titleRect, withAttributes: [
            .font: titleFont, .foregroundColor: NSColor.labelColor])
        (body as NSString).draw(in: bodyRect, withAttributes: [
            .font: bodyFont, .foregroundColor: NSColor.secondaryLabelColor])

        NSGraphicsContext.restoreGraphicsState()
    }
}
