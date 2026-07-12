//
//  ImagePaste.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(macOS)
import AppKit

/// Saves images pasted into the editor as files in the collection, so notes stay
/// plain text that references real image files (never embedded blobs).
enum ImagePaste {
    /// Save an image from `pasteboard` beside `noteURL`, returning a Markdown
    /// image link relative to the note. `subfolder` is the folder to store the
    /// image in (e.g. `"assets"`), created if needed; an empty string saves the
    /// image in the same folder as the note. Returns `nil` when the pasteboard
    /// holds no image.
    static func saveImage(from pasteboard: NSPasteboard, nextTo noteURL: URL,
                          subfolder: String, timestamp: Date) -> String? {
        guard let pngData = pngData(from: pasteboard) else { return nil }

        let folderName = subfolder.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        let noteFolder = noteURL.deletingLastPathComponent()
        let targetDir = folderName.isEmpty
            ? noteFolder
            : noteFolder.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let stamp = Int(timestamp.timeIntervalSince1970)
        var candidate = targetDir.appendingPathComponent("Pasted-\(stamp).png")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = targetDir.appendingPathComponent("Pasted-\(stamp)-\(counter).png")
            counter += 1
        }

        do {
            try pngData.write(to: candidate)
        } catch {
            return nil
        }
        let rel = folderName.isEmpty ? candidate.lastPathComponent : "\(folderName)/\(candidate.lastPathComponent)"
        return "![](\(rel))"
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
