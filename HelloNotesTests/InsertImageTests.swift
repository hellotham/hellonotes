//
//  InsertImageTests.swift
//  HelloNotesTests
//
//  Insert Image (1.3.7): a picture from the collection, the photo library or
//  the camera put into a note, from the keyboard's bar or Format ▸ Insert
//  Image. The pickers are the system's; what these hold is the rest — what a
//  chosen picture is written as and named, the link a note gets to it, where
//  in the note the link goes, and the collection taking in the new file and
//  its folder at once, so Choose from Collection… lists the photo just added.
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HelloNotes

@Suite @MainActor
struct InsertImageTests {

    // MARK: - The link

    @Test func aLinkEncodesWhatALinkCannotHoldAndKeepsEveryLetter() {
        #expect(PictureFile.linkPath("assets/Photo-1.jpg") == "assets/Photo-1.jpg")
        #expect(PictureFile.linkPath("My Pictures/a b.png") == "My%20Pictures/a%20b.png")
        #expect(PictureFile.linkPath("x (1).png") == "x%20%281%29.png")
        #expect(PictureFile.linkPath("a#b?c%d.png") == "a%23b%3Fc%25d.png")
        #expect(PictureFile.linkPath("<a>.png") == "%3Ca%3E.png")
        #expect(PictureFile.linkPath("Pāli/佛陀.png") == "Pāli/佛陀.png")
        #expect(PictureFile.linkPath("../Pictures/x.png") == "../Pictures/x.png")
    }

    @Test func aPathFromTheNotesFolderClimbsOnlyAsFarAsItMust() {
        let vault = URL(fileURLWithPath: "/Users/someone/Vault", isDirectory: true)
        func path(from folder: String, to file: String) -> String {
            PictureFile.relativePath(from: folder.isEmpty ? vault : vault.appending(path: folder),
                                     to: vault.appending(path: file))
        }
        #expect(path(from: "", to: "a.png") == "a.png")
        #expect(path(from: "", to: "assets/a.png") == "assets/a.png")
        #expect(path(from: "Notes", to: "Pictures/a.png") == "../Pictures/a.png")
        #expect(path(from: "A/B", to: "C/a.png") == "../../C/a.png")
        #expect(path(from: "A/B", to: "a.png") == "../../a.png")
        // One folder under its two names — an iPhone's `/private/var/…` — is
        // one folder, never a climb to the root and down again.
        #expect(PictureFile.relativePath(from: URL(fileURLWithPath: "/private/var/mobile/Notes"),
                                         to: URL(fileURLWithPath: "/var/mobile/Notes/assets/a.png"))
                == "assets/a.png")
    }

    @Test func aPictureInTheCollectionIsLinkedWhereItIs() {
        let note = URL(fileURLWithPath: "/Users/someone/Vault/Journal/Day.md")
        let picture = URL(fileURLWithPath: "/Users/someone/Vault/Pictures/My Photo.jpg")
        #expect(PictureFile.markdown(showing: picture, in: note) == "![](../Pictures/My%20Photo.jpg)")
    }

    // MARK: - What a picture is written as

    /// A 2×2 picture of `type`, or `nil` where this machine cannot write one.
    private func picture(_ type: UTType) -> Data? {
        guard let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let out = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    @Test func aPictureEveryReaderShowsIsKeptAsItCame() throws {
        for (type, ext) in [(UTType.png, "png"), (.jpeg, "jpg"), (.gif, "gif")] {
            let data = try #require(picture(type))
            let stored = try #require(PictureFile.storable(data))
            #expect(stored.ext == ext)
            #expect(stored.data == data, "a \(ext) was re-encoded")
        }
    }

    /// An iPhone's photo is HEIC, which GitHub, Obsidian on Windows and most
    /// browsers cannot draw: written as JPEG. TIFF takes the same way, and is
    /// what every machine can make for the test.
    @Test func aPictureNotEveryReaderShowsIsWrittenAsJPEG() throws {
        let tiff = try #require(picture(.tiff))
        var made = [("tiff", tiff)]
        if let heic = picture(.heic) { made.append(("heic", heic)) }
        for (name, data) in made {
            let stored = try #require(PictureFile.storable(data), "a \(name) was refused")
            #expect(stored.ext == "jpg")
            let source = try #require(CGImageSourceCreateWithData(stored.data as CFData, nil))
            #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier, "a \(name) was not re-encoded")
        }
        #expect(PictureFile.storable(Data("not a picture".utf8)) == nil)
    }

    @Test func aFileIsNamedForWhatItWillHold() {
        #expect(PictureFile.fileExtension(for: .png) == "png")
        #expect(PictureFile.fileExtension(for: .jpeg) == "jpg")
        #expect(PictureFile.fileExtension(for: .heic) == "jpg")
        #expect(PictureFile.fileExtension(for: .tiff) == "jpg")
    }

    @Test func aChosenPictureIsPlacedAsAPhotoBesideTheNote() {
        let note = URL(fileURLWithPath: "/Users/someone/Vault/Journal/Day.md")
        let placement = ImagePaste.place(nextTo: note, subfolder: "My Assets",
                                         timestamp: Date(timeIntervalSince1970: 5_000_000),
                                         stem: "Photo", ext: "jpg")
        defer { ImagePaste.release(placement) }
        #expect(placement.url.path == "/Users/someone/Vault/Journal/My Assets/Photo-5000000.jpg")
        #expect(placement.markdown == "![](My%20Assets/Photo-5000000.jpg)")
    }

    // MARK: - Where the link goes

    /// A picture put in on purpose is a paragraph of its own, with one blank
    /// line on each side and no more — at the caret, beside text, it was
    /// drawn inside the paragraph, from the end of its last word.
    @Test func aPictureIsAParagraphOfItsOwn() {
        func put(_ text: String, at location: Int, length: Int = 0) -> String {
            let range = NSRange(location: location, length: length)
            let block = EditorHost.asParagraph("![](p.jpg)", at: range, in: text as NSString)
            return (text as NSString).replacingCharacters(in: range, with: block)
        }
        // After a paragraph's last word, a heading after the blank line.
        #expect(put("special.\n\n## Tour", at: 8) == "special.\n\n![](p.jpg)\n\n## Tour")
        // In the middle of a line.
        #expect(put("one two", at: 3) == "one\n\n![](p.jpg)\n\n two")
        // On the blank line between two paragraphs.
        #expect(put("one\n\ntwo", at: 4) == "one\n\n![](p.jpg)\n\ntwo")
        // At the start, at the end, after a last line's newline, and alone.
        #expect(put("text", at: 0) == "![](p.jpg)\n\ntext")
        #expect(put("text", at: 4) == "text\n\n![](p.jpg)")
        #expect(put("text\n", at: 5) == "text\n\n![](p.jpg)")
        #expect(put("", at: 0) == "![](p.jpg)")
        // In place of a selection.
        #expect(put("keep THIS out", at: 5, length: 4) == "keep \n\n![](p.jpg)\n\n out")
    }

    // MARK: - The collection takes it in

    private func makeVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "hn-insert-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Day\n".write(to: root.appending(path: "Day.md"), atomically: true, encoding: .utf8)
        return root
    }

    private func make(_ relative: String, in root: URL) throws -> URL {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF]).write(to: url)
        return url
    }

    /// The photo just added is listed at once, with the folder made for it —
    /// once, however often the collection is told.
    @Test func aPictureMadeHereIsListedWithItsNewFolderAtOnce() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let collection = Collection(rootURL: root)
        try #require(collection.showsNonNoteFiles, "the premise: a collection lists its other files by default")
        let photo = try make("assets/Photo-1.jpg", in: root)
        let isThePhoto = collection.sameFile(as: photo)
        let revision = collection.revision

        collection.fileMadeHere(photo)
        collection.fileMadeHere(photo)
        #expect(collection.attachments.filter { isThePhoto($0.url) }.count == 1)
        #expect(collection.folders.filter { collection.place(of: $0.path) == "assets" }.count == 1)
        #expect(collection.revision != revision, "nothing that draws the collection was told")
    }

    /// Nothing the walk would not list: it skips anything hidden, so a picture
    /// in `.attachments` listed now would be taken away by the next walk.
    @Test func aPictureInAHiddenFolderIsNotListed() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let collection = Collection(rootURL: root)
        let photo = try make(".attachments/Photo-1.jpg", in: root)

        collection.fileMadeHere(photo)
        #expect(collection.attachments.isEmpty)
        #expect(collection.folders.isEmpty)
    }
}
