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
import Synchronization
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
    /// Where a pasted picture goes, and the Markdown that shows it — chosen
    /// at once, because the paste returns its Markdown at once. The picture is
    /// written by `write(_:to:)`, off the main actor: a coordinated create on
    /// an iCloud collection waits for the provider, and it waited on the main
    /// thread (implemented.md §51.36). A name chosen and not yet written is
    /// held (`reserved`), so two pastes in one second cannot choose the same.
    ///
    /// **Chosen without a look at the disk.** It looked for each name it tried
    /// on the main actor — before the paste could answer — and in a provider's
    /// folder not listed yet a look waits for the provider. A name already on
    /// disk is the write's to find: it takes the next one free, and the paste
    /// puts the Markdown right (implemented.md §51.67).
    static func place(nextTo noteURL: URL, subfolder: String, timestamp: Date) -> Placement {
        let folderName = subfolder.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        let noteFolder = noteURL.deletingLastPathComponent()
        let targetDir = folderName.isEmpty
            ? noteFolder
            : noteFolder.appendingPathComponent(folderName, isDirectory: true)
        let first = Placement(folder: targetDir, folderName: folderName,
                              stamp: Int(timestamp.timeIntervalSince1970), counter: 1)
        return reserved.withLock { taken in
            var candidate = first
            while taken.contains(candidate.url.path) { candidate = candidate.next }
            taken.insert(candidate.url.path)
            return candidate
        }
    }

    /// Where `place` put a picture.
    nonisolated struct Placement: Sendable, Equatable {
        let url: URL
        let folder: URL
        /// From the note's folder — what the Markdown names.
        let relativePath: String
        let markdown: String
        /// What the name is made of, for the next one along.
        private let folderName: String
        private let stamp: Int
        private let counter: Int

        fileprivate init(folder: URL, folderName: String, stamp: Int, counter: Int) {
            let name = counter == 1 ? "Pasted-\(stamp).png" : "Pasted-\(stamp)-\(counter).png"
            self.url = folder.appendingPathComponent(name)
            self.folder = folder
            self.relativePath = folderName.isEmpty ? name : "\(folderName)/\(name)"
            self.markdown = "![](\(relativePath))"
            self.folderName = folderName
            self.stamp = stamp
            self.counter = counter
        }

        /// The same picture under the next name.
        fileprivate var next: Placement {
            Placement(folder: folder, folderName: folderName, stamp: stamp, counter: counter + 1)
        }
    }

    /// Write `pngData` where `placement` says, off the main actor — or, when
    /// that name is taken on disk (`place` does not look), under the next one
    /// free — and say where: `nil` when nothing was written.
    static func write(_ pngData: Data, to placement: Placement) async -> Placement? {
        let (written, held) = await FileIO.onLane(for: placement.url) { () -> (Placement?, [String]) in
            try? FileIO.createDirectory(at: placement.folder)
            var candidate = placement
            var held = [placement.url.path]
            for _ in 0..<64 {
                do {
                    try FileIO.create(pngData, at: candidate.url)
                    return (candidate, held)
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    // Taken on disk: the next name that no other paste holds.
                    candidate = reserved.withLock { taken in
                        var next = candidate.next
                        while taken.contains(next.url.path) { next = next.next }
                        taken.insert(next.url.path)
                        return next
                    }
                    held.append(candidate.url.path)
                } catch {
                    return (nil, held)
                }
            }
            return (nil, held)
        }
        reserved.withLock { taken in held.forEach { taken.remove($0) } }
        return written
    }

    /// Names chosen and not yet written.
    nonisolated private static let reserved = Mutex<Set<String>>([])

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
