//
//  ThumbnailProvider.swift
//  HelloNotesThumbnail-iOS
//
//  Quick Look thumbnails for `.md` files (iOS): a "note page" — title + first
//  lines drawn on a card. Self-contained.
//

import UIKit
import QuickLookThumbnailing

class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let text = (try? String(contentsOf: request.fileURL, encoding: .utf8)) ?? ""
        let size = request.maximumSize
        handler(QLThumbnailReply(contextSize: size, currentContextDrawing: {
            ThumbnailProvider.draw(text: text, in: size)
            return true
        }), nil)
    }

    /// UIKit context is top-left origin, so title sits at the top.
    static func draw(text: String, in size: CGSize) {
        UIColor.systemBackground.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))

        let lines = text.components(separatedBy: "\n")
        let title = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") })?
            .drop(while: { $0 == "#" || $0 == " " }).description
            ?? lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "Markdown"
        let body = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
            .prefix(12).joined(separator: "\n")

        let inset = size.width * 0.08
        let titleFont = UIFont.boldSystemFont(ofSize: max(11, size.height * 0.09))
        let bodyFont = UIFont.systemFont(ofSize: max(8, size.height * 0.05))
        let titleRect = CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height * 0.28)
        let bodyRect = CGRect(x: inset, y: size.height * 0.34, width: size.width - inset * 2, height: size.height * 0.6)

        (title as NSString).draw(in: titleRect, withAttributes: [
            .font: titleFont, .foregroundColor: UIColor.label])
        (body as NSString).draw(in: bodyRect, withAttributes: [
            .font: bodyFont, .foregroundColor: UIColor.secondaryLabel])
    }
}
