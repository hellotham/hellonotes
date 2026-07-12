//
//  CollectionFile.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  A non-Markdown file in the collection (a PDF, image, CSV, or anything else). These
//  are surfaced alongside notes in the folder tree and open in a viewer rather
//  than the Markdown editor.
//

import Foundation
import UniformTypeIdentifiers

enum CollectionFileKind: Hashable, Sendable {
    case pdf, image, csv, other

    static func of(_ url: URL) -> CollectionFileKind {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if ext == "csv" || ext == "tsv" { return .csv }
        let imageExts: Set<String> = [
            "png", "jpg", "jpeg", "gif", "heic", "heif", "webp",
            "tiff", "tif", "bmp", "svg", "icns", "avif",
        ]
        if imageExts.contains(ext) { return .image }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .image) { return .image }
        return .other
    }

    var symbol: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .image: return "photo"
        case .csv: return "tablecells"
        case .other: return "doc"
        }
    }
}

struct CollectionFile: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let kind: CollectionFileKind
    let lastModified: Date

    var name: String { url.lastPathComponent }

    init(url: URL, lastModified: Date) {
        self.url = url
        self.kind = CollectionFileKind.of(url)
        self.lastModified = lastModified
    }
}
