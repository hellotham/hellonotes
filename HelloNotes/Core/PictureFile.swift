//
//  PictureFile.swift
//  HelloNotes
//
//  A picture put into a note from the photo library, the camera, or an
//  iPhone near a Mac: what it is written as, and the Markdown that shows it.
//  And a picture already in the collection: the link to it from a note.
//
//  Pure: bytes in, bytes and text out — ImageIO for the pictures, and no look
//  at the disk for the links, so all of it can be asked anywhere.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum PictureFile {

    /// What a chosen picture is written as, and its file extension: kept as
    /// it came when every Markdown reader shows it (JPEG, PNG, GIF, WebP),
    /// re-encoded as JPEG when not. An iPhone's photo is HEIC, which GitHub,
    /// Obsidian on Windows and most browsers cannot draw, so a note showing
    /// one would show it on Apple's devices alone. Re-encoded with its
    /// metadata, its orientation among it. `nil` when it is not a picture.
    static func storable(_ data: Data) -> (data: Data, ext: String)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let typeID = CGImageSourceGetType(source) as String?,
              let type = UTType(typeID)
        else { return nil }
        if let kept = kept[type] { return (data, kept) }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImageFromSource(destination, source, 0,
                                             [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (out as Data, "jpg")
    }

    /// The extension a picture of `type` is written with — the one rule
    /// `storable` keeps to, so a file named before its bytes are made (a
    /// photo from an iPhone near a Mac) is named what it will hold.
    static func fileExtension(for type: UTType) -> String { kept[type] ?? "jpg" }

    /// The types every Markdown reader shows, written as they came.
    private static let kept: [UTType: String] = [.jpeg: "jpg", .png: "png", .gif: "gif", .webP: "webp"]

    /// A picture no larger than `maxPixels` on its longer side, turned the
    /// way it is meant to be seen — for a list of pictures, from their bytes.
    static func thumbnail(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // The file's own thumbnail when it has one — a camera's photo, a
        // HEIC — rather than the whole picture decoded for 80 pixels: a list
        // of a thousand photos made one per row.
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }

    /// The Markdown that shows the picture at `picture` in the note at `note`:
    /// a path from the note's folder, as paste writes one — what Edit,
    /// Preview, GitHub and Obsidian all read. The picture stays where it is.
    static func markdown(showing picture: URL, in note: URL) -> String {
        "![](\(linkPath(relativePath(from: note.deletingLastPathComponent(), to: picture))))"
    }

    /// `file`'s path from `folder`, climbing with `..` where it must. By text,
    /// with `/private/var` and `/var` taken as one folder (`ContainerPath`),
    /// so two spellings of one place never climb to the root.
    static func relativePath(from folder: URL, to file: URL) -> String {
        let from = ContainerPath.oneSpelling(folder.path).split(separator: "/")
        let to = ContainerPath.oneSpelling(file.path).split(separator: "/")
        var shared = 0
        while shared < from.count, shared < to.count - 1, from[shared] == to[shared] { shared += 1 }
        let climb = Array(repeating: "..", count: from.count - shared)
        return (climb + to[shared...].map(String.init)).joined(separator: "/")
    }

    /// A relative path as a Markdown link writes it: a space, a parenthesis,
    /// `#`, `?`, `%` and the other ASCII a link destination cannot hold,
    /// percent-encoded; letters of any script kept as they are, so the
    /// Markdown stays readable. Edit decodes it (`removingPercentEncoding`),
    /// as Preview, GitHub and Obsidian do.
    static func linkPath(_ path: String) -> String {
        var out = ""
        for scalar in path.unicodeScalars {
            if scalar.isASCII && (!allowed.contains(scalar) || "()<>".unicodeScalars.contains(scalar)) {
                for byte in String(scalar).utf8 { out += String(format: "%%%02X", byte) }
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// A URL path's own characters: `/` and the unreserved ones.
    private static let allowed = CharacterSet.urlPathAllowed
}
