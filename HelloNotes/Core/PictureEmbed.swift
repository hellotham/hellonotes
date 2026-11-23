//
//  PictureEmbed.swift
//  HelloNotes
//
//  `![[photo.png|300]]` as Obsidian reads it, and where in a collection the
//  picture it names is.
//

import Foundation
import MarkdownCore

/// A picture a note shows, as it was written.
///
/// Two spellings, two rules. A Markdown image, `![](assets/photo.png)`, is a
/// path from the note's folder — what GitHub and Preview's cmark read; Edit
/// also looks in the note's pictures folder for one (`EditorHost`), as it
/// always has. An Obsidian embed, `![[photo.png]]`, names its picture *by
/// name*: Obsidian writes the shortest name that is unique in the vault, so
/// the picture may be in the vault's top folder (Obsidian's default for new
/// attachments), in a folder of its own, or beside the note, and the note
/// says only `photo.png`. After a pipe it may give a width, `|300`, or a
/// width and height, `|300x200`; anything else there is the picture's
/// description.
nonisolated struct PictureEmbed: Equatable, Sendable {
    /// The picture's path as written, less any `#…` subpath: a name, or a
    /// path from the note's folder or the collection's.
    let path: String
    /// Whether it was written `![[…]]`, and is looked up by name.
    let byName: Bool
    /// The size the note asks for, in points — CSS pixels, as Obsidian's are.
    let width: Int?
    let height: Int?
    /// What the note says the picture shows, if it says.
    let alt: String?

    /// An `![[…]]` embed's inner text, `photo.png|300` — what the editor
    /// hands the renderer (`BlockEmbedKind.image(target:isWikiEmbed:)`).
    init(wiki inner: String) {
        let alias = WikiLinkSyntax.split(inner).alias
        path = PictureNames.embedTarget(inner)
        byName = true
        // `alt|300`: the size is the last part, when it is one.
        var parts = alias.map { $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init) } ?? []
        var width: Int?, height: Int?
        if let last = parts.last, let size = Self.size(last) {
            (width, height) = size
            parts.removeLast()
        }
        self.width = width
        self.height = height
        // A table's row escapes the pipe (`![[photo.png\|alt\|300]]`); the
        // escape belongs to the row, not to the words.
        let words = parts.map { $0.hasSuffix("\\") ? String($0.dropLast()) : $0 }
            .joined(separator: "|").trimmingCharacters(in: .whitespaces)
        alt = words.isEmpty ? nil : words
    }

    /// A Markdown image's destination, already decoded, less any `#…`
    /// fragment — `![](logo.png#gh-dark-mode-only)`, which GitHub's READMEs
    /// use, names `logo.png`, as a page's `<img src>` does. Kept, the
    /// fragment was read as the extension (`png#gh-dark-mode-only`), and the
    /// picture was not drawn.
    init(path: String) {
        self.path = path.firstIndex(of: "#").map { String(path[..<$0]) } ?? path
        byName = false
        width = nil
        height = nil
        alt = nil
    }

    /// The `BlockEmbedKind.image` payload, read.
    init(target: String, isWikiEmbed: Bool) {
        self = isWikiEmbed ? PictureEmbed(wiki: target) : PictureEmbed(path: target)
    }

    /// Whether the name is a picture's — not a note shown in place, a PDF, …
    var isPicture: Bool { PictureNames.isPicture(path) }

    /// `300` or `300x200`, as Obsidian writes a size (`PictureNames.size`).
    static func size(_ text: String) -> (width: Int, height: Int?)? { PictureNames.size(text) }
}

/// The pictures in a collection, by their place in it — the path from its
/// folder, `/`-separated — so `![[photo.png]]` can be found as Obsidian finds
/// it, without asking the disk.
///
/// Made from what the collection's walk lists (`Collection.attachments`), and
/// asked while a note is drawn: a look at the disk there is a wait on a
/// provider that answers when it pleases, which a list already in memory is
/// not.
nonisolated struct PictureIndex: Equatable, Sendable {
    /// Every picture's place, by the place lowercased: a vault on a Mac's or
    /// an iPad's disk does not tell `Photo.PNG` from `photo.png`, and
    /// Obsidian matches names without regard to case.
    private var byPlace: [String: String] = [:]
    /// The places of the pictures with each name, by the name lowercased.
    private var byName: [String: [String]] = [:]

    init() {}

    init(places: [String]) {
        for place in places {
            let key = place.lowercased()
            guard byPlace[key] == nil else { continue }
            byPlace[key] = place
            byName[Self.name(of: key), default: []].append(place)
        }
    }

    var isEmpty: Bool { byPlace.isEmpty }

    /// Where the picture `embed` names is, seen from a note in `folder` (its
    /// folder's place, `""` at the top), or nil if no picture in the
    /// collection answers to it.
    ///
    /// In order:
    /// 1. A path starting `./` or `../` is from the note's folder, and one
    ///    starting `/` from the collection's; each names one place and no
    ///    other.
    /// 2. The path from the note's folder — the only rule a Markdown image
    ///    has, as cmark and GitHub read one.
    /// 3. For `![[…]]` alone: the path from the collection's folder —
    ///    Obsidian's other path format, and the only way it can write the
    ///    path of a picture kept there; the note's own pictures folder
    ///    (`attachmentFolder`, where paste and Insert Image put them); then
    ///    any picture whose place ends in what was written, nearest the note
    ///    first — the fewest folders between them, then the shortest place,
    ///    then by name, so the same note always shows the same picture.
    func place(of embed: PictureEmbed, fromNoteIn folder: String, attachmentFolder: String) -> String? {
        var written = embed.path
        guard !written.isEmpty else { return nil }
        if written.hasPrefix("/") {
            while written.hasPrefix("/") { written.removeFirst() }
            return Self.normalised(written).flatMap { byPlace[$0.lowercased()] }
        }
        if written.hasPrefix("./") || written.hasPrefix("../") {
            return Self.normalised(Self.join(folder, written)).flatMap { byPlace[$0.lowercased()] }
        }
        var tries = [Self.join(folder, written)]
        if embed.byName {
            tries.append(written)
            let sub = attachmentFolder.trimmingCharacters(in: .whitespaces)
            if !sub.isEmpty { tries.append(Self.join(Self.join(folder, sub), written)) }
        }
        for candidate in tries {
            if let place = Self.normalised(candidate), let found = byPlace[place.lowercased()] { return found }
        }
        guard embed.byName, let wanted = Self.normalised(written)?.lowercased() else { return nil }
        let matches = (byName[Self.name(of: wanted)] ?? []).filter {
            let place = $0.lowercased()
            return place == wanted || place.hasSuffix("/" + wanted)
        }
        let from = folder.split(separator: "/").map { $0.lowercased() }
        return matches.min { a, b in
            let (da, db) = (Self.distance(from: from, to: a), Self.distance(from: from, to: b))
            if da != db { return da < db }
            if a.count != b.count { return a.count < b.count }
            return a < b
        }
    }

    /// `place`'s path from a note in `folder`, climbing with `..` where it
    /// must — places both, so no spelling of the collection's folder enters.
    static func relativePath(fromNoteIn folder: String, to place: String) -> String {
        let from = folder.split(separator: "/")
        let to = place.split(separator: "/")
        var shared = 0
        while shared < from.count, shared < to.count - 1, from[shared] == to[shared] { shared += 1 }
        let climb = Array(repeating: "..", count: from.count - shared)
        return (climb + to[shared...].map(String.init)).joined(separator: "/")
    }

    /// The folders between a note's folder and a picture's: up to where they
    /// part, then down.
    private static func distance(from folder: [String], to place: String) -> Int {
        let to = place.lowercased().split(separator: "/").dropLast().map(String.init)
        var shared = 0
        while shared < folder.count, shared < to.count, folder[shared] == to[shared] { shared += 1 }
        return (folder.count - shared) + (to.count - shared)
    }

    private static func name(of place: String) -> String {
        place.split(separator: "/").last.map(String.init) ?? place
    }

    private static func join(_ folder: String, _ path: String) -> String {
        folder.isEmpty ? path : folder + "/" + path
    }

    /// `a/./b/../c` as `a/c`, or nil if it climbs out of the collection.
    static func normalised(_ path: String) -> String? {
        var out: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..":
                guard !out.isEmpty else { return nil }
                out.removeLast()
            default: out.append(part)
            }
        }
        return out.isEmpty ? nil : out.joined(separator: "/")
    }
}
