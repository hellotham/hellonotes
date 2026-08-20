//
//  ImagePaste.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

// **Cross-platform.** Everything below the pasteboard read — the folder, the
// name collision loop, the coordinated write, the relative link — was never
// platform-specific. Only "give me PNG bytes" was, and each platform spells
// that in about six lines.

import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Saves images pasted into the editor as files in the collection, so notes stay
/// plain text that references real image files (never embedded blobs).
enum ImagePaste {
    /// Save an image from `pasteboard` beside `noteURL`, returning a Markdown
    /// image link relative to the note. `subfolder` is the folder to store the
    /// image in (e.g. `"assets"`), created if needed; an empty string saves the
    /// image in the same folder as the note. Returns `nil` when the pasteboard
    /// holds no image.
    static func saveImage(pngData: Data?, nextTo noteURL: URL,
                          subfolder: String, timestamp: Date) -> String? {
        guard let pngData else { return nil }

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
            try FileIO.create(pngData, at: candidate)
        } catch {
            return nil
        }
        let rel = folderName.isEmpty ? candidate.lastPathComponent : "\(folderName)/\(candidate.lastPathComponent)"
        return "![](\(rel))"
    }

    /// PNG bytes from the system pasteboard, or nil when it holds no image.
    #if canImport(AppKit)
    static func pasteboardPNG(_ pasteboard: NSPasteboard = .general) -> Data? {
        if let data = pasteboard.data(forType: .png) { return data }
        if let tiff = pasteboard.data(forType: .tiff), let png = png(fromTIFF: tiff) { return png }
        if let image = pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
           let tiff = image.tiffRepresentation, let png = png(fromTIFF: tiff) {
            return png
        }
        return nil
    }

    private static func png(fromTIFF tiff: Data) -> Data? {
        NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }
    #else
    static func pasteboardPNG(_ pasteboard: UIPasteboard = .general) -> Data? {
        // `pasteboard.image` re-encodes; the raw item is preferred when the
        // source already provided PNG, so a screenshot is not resampled.
        if let data = pasteboard.data(forPasteboardType: "public.png") { return data }
        return pasteboard.image?.pngData()
    }
    #endif
}
