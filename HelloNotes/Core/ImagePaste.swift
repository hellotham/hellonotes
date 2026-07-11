//
//  ImagePaste.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(macOS)
import AppKit

/// Saves images pasted into the editor as files in the vault, so notes stay
/// plain text that references real image files (never embedded blobs).
enum ImagePaste {
    /// Save an image from `pasteboard` into an `assets/` folder beside
    /// `noteURL`, returning a Markdown image link relative to the note.
    /// Returns `nil` when the pasteboard holds no image.
    static func saveImage(from pasteboard: NSPasteboard, nextTo noteURL: URL, timestamp: Date) -> String? {
        guard let pngData = pngData(from: pasteboard) else { return nil }

        let assetsDir = noteURL.deletingLastPathComponent().appendingPathComponent("assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        let stamp = Int(timestamp.timeIntervalSince1970)
        var candidate = assetsDir.appendingPathComponent("Pasted-\(stamp).png")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = assetsDir.appendingPathComponent("Pasted-\(stamp)-\(counter).png")
            counter += 1
        }

        do {
            try pngData.write(to: candidate)
        } catch {
            return nil
        }
        return "![](assets/\(candidate.lastPathComponent))"
    }

    /// Extract PNG data from the pasteboard, converting from TIFF (screenshots)
    /// or an `NSImage` object when necessary.
    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let data = pasteboard.data(forType: .png) {
            return data
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let png = png(fromTIFF: tiff) {
            return png
        }
        if let image = pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
           let tiff = image.tiffRepresentation,
           let png = png(fromTIFF: tiff) {
            return png
        }
        return nil
    }

    private static func png(fromTIFF tiff: Data) -> Data? {
        NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }
}
#endif
