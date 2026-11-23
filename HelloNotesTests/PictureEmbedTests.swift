//
//  PictureEmbedTests.swift
//  HelloNotesTests
//
//  `![[photo.png]]` — an Obsidian picture embed — shown in Edit and Preview.
//
//  Obsidian writes the shortest name that is unique in the vault and keeps
//  new pictures in the vault's top folder unless told otherwise, so the
//  picture an embed names is as often in a folder the note does not name as
//  beside it. The app looked beside the note and in its pictures folder, and
//  nowhere else; Preview, a path from the note's folder. Every picture in a
//  note one folder away from it was a line of text in Edit and a blank in
//  Preview, and `|300` after the name was drawn as the text "300".
//

import CoreGraphics
import Foundation
import GFMRender
import ImageIO
import MarkdownCore
import MarkdownEditor
import Testing
import UniformTypeIdentifiers
@testable import HelloNotes

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@Suite @MainActor
struct PictureEmbedTests {

    // MARK: - What an embed says

    @Test func anEmbedSaysItsNameItsSizeAndItsWords() {
        let plain = PictureEmbed(wiki: "Pasted image 20241122.png")
        #expect(plain.path == "Pasted image 20241122.png")
        #expect(plain.byName && plain.isPicture)
        #expect(plain.width == nil && plain.height == nil && plain.alt == nil)

        let wide = PictureEmbed(wiki: "photo.png|300")
        #expect(wide.path == "photo.png" && wide.width == 300 && wide.height == nil && wide.alt == nil)

        let boxed = PictureEmbed(wiki: "photo.png|300x200")
        #expect(boxed.width == 300 && boxed.height == 200)

        let described = PictureEmbed(wiki: "photo.png|A cat asleep")
        #expect(described.alt == "A cat asleep" && described.width == nil)

        let both = PictureEmbed(wiki: "photo.png|A cat|120")
        #expect(both.alt == "A cat" && both.width == 120)

        // A table's row escapes the pipe; the escape is not the name's.
        let inTable = PictureEmbed(wiki: "photo.png\\|120")
        #expect(inTable.path == "photo.png" && inTable.width == 120)

        // A subpath is not part of the file's name.
        #expect(PictureEmbed(wiki: "assets/photo.png#page").path == "assets/photo.png")
        // Nor is a Markdown image's fragment — GitHub's READMEs pick a
        // picture per appearance with one.
        let fragment = PictureEmbed(path: "assets/logo.png#gh-dark-mode-only")
        #expect(fragment.path == "assets/logo.png" && fragment.isPicture)
        // Not a size: words that happen to hold digits.
        #expect(PictureEmbed(wiki: "photo.png|x300").alt == "x300")
        #expect(PictureEmbed(wiki: "photo.png|300x").width == nil)
    }

    /// A description from Vision is written into `![…](…)` as it comes, so
    /// it holds nothing that syntax reads: no bracket to end it or leave it
    /// open, no backslash to escape the `]` after it, and no pipe — after
    /// one, `| 12` is a size (`PictureNames.sizeSuffix`).
    @Test func aDescriptionFromVisionIsSafeInALink() {
        let read = "Exit [3] C:\\Gate\nPlatform | 12"
        #expect(PictureNames.sizeSuffix(of: read) != nil, "the control: a sign that reads as a size")
        let safe = VisionAlt.markdownSafe(read)
        #expect(safe == "Exit (3) C:/Gate Platform / 12")
        #expect(PictureNames.sizeSuffix(of: safe) == nil)
        #expect(!safe.contains { "[]\\|\n".contains($0) })
    }

    @Test func onlyAPicturesNameIsAPicture() {
        #expect(PictureEmbed(wiki: "Photo.PNG").isPicture)
        #expect(PictureEmbed(wiki: "scan.heic").isPicture)
        #expect(!PictureEmbed(wiki: "Meeting notes").isPicture)
        #expect(!PictureEmbed(wiki: "Meeting notes|alias").isPicture)
        #expect(!PictureEmbed(wiki: "report.pdf").isPicture)
        // A dot in a folder's name is not an extension.
        #expect(!PictureNames.isPicture("v1.png/notes"))
    }

    // MARK: - Where the picture is

    private func find(_ written: String, from folder: String, in places: [String],
                      attachmentFolder: String = "assets", byName: Bool = true) -> String? {
        let embed = byName ? PictureEmbed(wiki: written) : PictureEmbed(path: written)
        return PictureIndex(places: places).place(of: embed, fromNoteIn: folder, attachmentFolder: attachmentFolder)
    }

    /// The case that was reported: a note in a folder, its picture elsewhere,
    /// named by name. A Markdown image of the same name is a path from the
    /// note's folder and finds nothing — the negative control, and the rule
    /// GitHub and Preview's cmark keep.
    @Test func anEmbedIsFoundByNameAnywhereInTheCollection() {
        let places = ["assets/Photo-1.jpg", "Manual/Deep Embeds.md"]
        #expect(find("Photo-1.jpg", from: "Manual", in: places) == "assets/Photo-1.jpg")
        #expect(find("Photo-1.jpg", from: "Manual/Deeper/Still", in: places) == "assets/Photo-1.jpg")
        #expect(find("Photo-1.jpg", from: "Manual", in: places, byName: false) == nil)
        #expect(find("Missing.jpg", from: "Manual", in: places) == nil)
    }

    /// Obsidian's two path formats, from the note and from the vault's top,
    /// in that order; `./` and `../` from the note alone, and never out of
    /// the collection.
    @Test func aPathIsFromTheNotesFolderThenTheCollections() {
        let places = ["Manual/assets/p.png", "assets/p.png", "Attachments/q.png"]
        #expect(find("assets/p.png", from: "Manual", in: places) == "Manual/assets/p.png")
        #expect(find("assets/p.png", from: "", in: places) == "assets/p.png")
        #expect(find("assets/p.png", from: "Journal", in: places) == "assets/p.png")
        #expect(find("Attachments/q.png", from: "Projects/A", in: places) == "Attachments/q.png")
        #expect(find("../assets/p.png", from: "Manual", in: places) == "assets/p.png")
        #expect(find("./assets/p.png", from: "Manual", in: places) == "Manual/assets/p.png")
        #expect(find("/assets/p.png", from: "Manual", in: places) == "assets/p.png")
        #expect(find("../../assets/p.png", from: "Manual", in: places) == nil)
        // A Markdown image's path is the note's folder's, and nothing else.
        #expect(find("assets/p.png", from: "Journal", in: places, byName: false) == nil)
        #expect(find("assets/p.png", from: "Manual", in: places, byName: false) == "Manual/assets/p.png")
    }

    @Test func aNameIsMatchedWithoutRegardToCaseAndOnlyWhole() {
        #expect(find("pic.png", from: "", in: ["Assets/Pic.PNG"]) == "Assets/Pic.PNG")
        #expect(find("assets/pic.png", from: "Notes", in: ["Notes/Assets/Pic.PNG"]) == "Notes/Assets/Pic.PNG")
        // `mypic.png` ends in `pic.png`, and is not it.
        #expect(find("pic.png", from: "", in: ["mypic.png"]) == nil)
        #expect(find("b/pic.png", from: "", in: ["ab/pic.png"]) == nil)
    }

    /// Two pictures of one name: the nearer the note, then the shorter place,
    /// then by name — the same note shows the same picture every time.
    @Test func ofTwoPicturesOfOneNameTheNearerIsShown() {
        let places = ["x/y/pic.png", "Projects/B/pic.png", "Projects/A/sub/pic.png"]
        #expect(find("pic.png", from: "Projects/A", in: places) == "Projects/A/sub/pic.png")
        #expect(find("pic.png", from: "Projects/B/deeper", in: places) == "Projects/B/pic.png")
        #expect(find("pic.png", from: "", in: ["b/pic.png", "a/pic.png"]) == "a/pic.png")
        // The note's own pictures folder comes before the rest — where paste
        // and Insert Image put them — though another folder is as near and
        // its place is shorter.
        let mine = ["Notes/assets/pic.png", "Notes/a/pic.png"]
        #expect(find("pic.png", from: "Notes", in: mine) == "Notes/assets/pic.png")
        #expect(find("pic.png", from: "Notes", in: mine, attachmentFolder: "") == "Notes/a/pic.png")
        // A name is also a path from the collection's top folder — the only
        // way Obsidian can write the path of a picture kept there — and that
        // comes before the pictures folder.
        #expect(find("pic.png", from: "Notes", in: ["Notes/assets/pic.png", "pic.png"]) == "pic.png")
    }

    @Test func aPictureIsLinkedFromTheNotesFolder() {
        #expect(PictureIndex.relativePath(fromNoteIn: "", to: "assets/p.png") == "assets/p.png")
        #expect(PictureIndex.relativePath(fromNoteIn: "Manual", to: "assets/p.png") == "../assets/p.png")
        #expect(PictureIndex.relativePath(fromNoteIn: "A/B", to: "A/C/p.png") == "../C/p.png")
    }

    // MARK: - The collection's pictures

    private func makeVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "hn-embed-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "Manual"), withIntermediateDirectories: true)
        try "![[Photo-1.png]]\n".write(to: root.appending(path: "Manual/Deep.md"), atomically: true, encoding: .utf8)
        return root
    }

    /// A `width`×`height` PNG, filled.
    private func png(_ width: Int, _ height: Int, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test(.timeLimit(.minutes(1)))
    func theCollectionsWalkListsItsPicturesForItsEmbeds() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try png(4, 2, at: root.appending(path: "assets/Photo-1.png"))
        let collection = Collection(rootURL: root)
        try #require(collection.showsNonNoteFiles, "the premise: a collection lists its other files by default")
        collection.scan()

        let note = root.appending(path: "Manual/Deep.md")
        let found = await collection.embedProvider.pictureURL(
            for: PictureEmbed(wiki: "Photo-1.png"), from: note, attachmentFolder: "assets", waitForList: true)
        #expect(found.map { collection.place(of: $0.path) } == "assets/Photo-1.png")

        // The Markdown spelling of the same name looks beside the note only.
        let path = await collection.embedProvider.pictureURL(
            for: PictureEmbed(path: "Photo-1.png"), from: note, attachmentFolder: "assets", waitForList: true)
        #expect(path == nil)
    }

    /// A note opened at launch is drawn from the index cache before the walk
    /// that lists the pictures has run: Edit's picture waits for the walk,
    /// and is drawn when it lands, rather than giving up as text for good.
    @Test(.timeLimit(.minutes(1)))
    func aPictureAskedForBeforeTheWalkWaitsForIt() async throws {
        let root = URL(fileURLWithPath: "/nowhere-\(UUID().uuidString)/Vault", isDirectory: true)
        let provider = CollectionEmbedProvider()
        provider.listsPictures(in: root, spellings: [root.path + "/"])
        let note = root.appending(path: "Manual/Deep.md")

        // Preview does not wait: its page is drawn again when the walk lands.
        let now = await provider.pictureURL(for: PictureEmbed(wiki: "Photo-1.png"), from: note,
                                            attachmentFolder: "assets", waitForList: false)
        #expect(now == nil)

        let waiting = Task {
            await provider.pictureURL(for: PictureEmbed(wiki: "Photo-1.png"), from: note,
                                      attachmentFolder: "assets", waitForList: true)
        }
        // Waiting — not merely started: a sleep here was over before a busy
        // pool had run the lookup, which then found the list already in and
        // passed without waiting at all.
        var patience = Waits.Patience(.seconds(10))
        while provider.lookupsWaitingForPictures == 0, patience.lasts {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(provider.lookupsWaitingForPictures == 1, "the lookup never waited for the list")
        provider.update(pictures: [CollectionFile(url: root.appending(path: "assets/Photo-1.png"),
                                                  lastModified: .now)])
        provider.picturesAreListed()
        let found = await waiting.value
        #expect(found?.path == root.appending(path: "assets/Photo-1.png").path)

        // Listed, a picture not there is not waited for.
        let missing = await provider.pictureURL(for: PictureEmbed(wiki: "Nope.png"), from: note,
                                                attachmentFolder: "assets", waitForList: true)
        #expect(missing == nil)
    }

    /// A provider of a view's own has no collection to wait for.
    @Test(.timeLimit(.minutes(1)))
    func aProviderWithNoCollectionNeverWaits() async {
        let provider = CollectionEmbedProvider()
        let note = URL(fileURLWithPath: "/nowhere-\(UUID().uuidString)/Note.md")
        let found = await provider.pictureURL(for: PictureEmbed(wiki: "Photo-1.png"), from: note,
                                              attachmentFolder: "assets", waitForList: true)
        #expect(found == nil)
    }

    /// A picture beside the note that is a symbolic link to one elsewhere is
    /// found, as `fileExists` found it before Obsidian's names were looked
    /// up: a link's own resource values say it is not a regular file. With
    /// no list to find it in — the collection lists only its notes.
    @Test(.timeLimit(.minutes(1)))
    func aPictureThatIsALinkIsFound() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let elsewhere = FileManager.default.temporaryDirectory
            .appending(path: "hn-embed-target-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try png(4, 2, at: elsewhere)
        let link = root.appending(path: "Manual/Linked.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        let provider = CollectionEmbedProvider()
        provider.listsPictures(in: root, spellings: [root.path + "/"])
        provider.picturesAreListed()
        let found = await provider.pictureURL(for: PictureEmbed(wiki: "Linked.png"),
                                              from: root.appending(path: "Manual/Deep.md"),
                                              attachmentFolder: "assets", waitForList: true)
        #expect(found?.lastPathComponent == "Linked.png")
        // Its control: a name with nothing behind it is not found.
        let missing = await provider.pictureURL(for: PictureEmbed(wiki: "Unlinked.png"),
                                                from: root.appending(path: "Manual/Deep.md"),
                                                attachmentFolder: "assets", waitForList: true)
        #expect(missing == nil)
    }

    // MARK: - Edit draws it

    /// A size at either end is drawn, never trapped on or handed back as it
    /// was: a divider brought down to a column is under a point tall, and a
    /// note can ask for a picture far larger than itself, whose bitmap is
    /// kept to the picture's own pixels or `pixelBudget`.
    @Test func aPictureIsResizedAtEitherExtreme() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "hn-resize-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "divider.png")
        try png(2000, 2, at: file)
        let image = try #require(PlatformImageKit.loadImage(data: Data(contentsOf: file), named: "divider.png"))
        let thin = PlatformImageKit.scaled(image, maxWidth: 640)
        #expect(thin.size.width == 640, "a picture under a point tall came back at its own width")

        let huge = PlatformImageKit.resized(image, to: CGSize(width: 600, height: 9_000_000))
        #expect(huge.size == CGSize(width: 600, height: 9_000_000))
        #if canImport(AppKit)
        let pixels = huge.representations.map { CGFloat($0.pixelsWide) * CGFloat($0.pixelsHigh) }.max() ?? 0
        #else
        let pixels = huge.cgImage.map { CGFloat($0.width) * CGFloat($0.height) } ?? 0
        #endif
        #expect(pixels > 0 && pixels <= PlatformImageKit.pixelBudget * 1.01,
                "a bitmap of \(pixels) pixels for a note's size")
    }

    @Test func editDrawsThePictureAtTheSizeTheNoteAsksFor() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "assets/Photo-1.png")
        try png(40, 20, at: file)
        let asked = Names()
        let adapter = BlockRenderAdapter(
            resolve: { picture in await asked.add(picture.path); return file },
            renderTransclusion: { name, _ in await asked.add("card:" + name); return nil })

        let natural = try #require(await adapter.render(.image(target: "Photo-1.png", isWikiEmbed: true),
                                                        maxWidth: 600, darkMode: false))
        #expect(natural.size == CGSize(width: 40, height: 20))
        // Up past its own size, as `<img width="100">` is drawn…
        let wide = try #require(await adapter.render(.image(target: "Photo-1.png|100", isWikiEmbed: true),
                                                     maxWidth: 600, darkMode: false))
        #expect(wide.size == CGSize(width: 100, height: 50))
        // …and never past the pane, as `max-width: 100%` keeps it.
        let capped = try #require(await adapter.render(.image(target: "Photo-1.png|900", isWikiEmbed: true),
                                                       maxWidth: 300, darkMode: false))
        #expect(capped.size == CGSize(width: 300, height: 150))
        let boxed = try #require(await adapter.render(.image(target: "Photo-1.png|30x30", isWikiEmbed: true),
                                                      maxWidth: 600, darkMode: false))
        #expect(boxed.size == CGSize(width: 30, height: 30))
        #expect(await asked.all == ["Photo-1.png", "Photo-1.png", "Photo-1.png", "Photo-1.png"],
                "the size was taken for part of the name")
        // As the editor asks: the size it read beside the embed.
        let read = try #require(await adapter.render(
            .image(target: "Photo-1.png|100", isWikiEmbed: true, width: 100), maxWidth: 600, darkMode: false))
        #expect(read.size == CGSize(width: 100, height: 50))

        // A Markdown image's size, read from its description by the editor.
        let markdown = try #require(await adapter.render(
            .image(target: "Photo-1.png", isWikiEmbed: false, width: 100), maxWidth: 600, darkMode: false))
        #expect(markdown.size == CGSize(width: 100, height: 50))

        // A note shown in place is looked up by its name, not its alias.
        _ = await adapter.render(.image(target: "Meeting|the meeting", isWikiEmbed: true),
                                 maxWidth: 600, darkMode: false)
        #expect(await asked.all.last == "card:Meeting")
    }

    private actor Names {
        var all: [String] = []
        func add(_ name: String) { all.append(name) }
    }

    // MARK: - Preview draws it

    private func preview(_ text: String, in root: URL, note: String = "Manual/Deep.md") async throws -> String {
        let collection = Collection(rootURL: root)
        collection.scan()
        return await PreviewSuperset.apply(
            to: text, isDark: false, embeds: collection.embedProvider,
            pictures: .init(note: root.appending(path: note), attachmentFolder: "assets"))
    }

    @Test func previewShowsThePictureFromItsOwnAddress() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try png(4, 2, at: root.appending(path: "assets/Photo-1.png"))

        let plain = try await preview("![[Photo-1.png]]", in: root)
        #expect(plain.hasPrefix("![Photo-1.png](<\(PreviewPictures.scheme)://"), "\(plain)")
        let address = try #require(plain.firstMatch(of: /<(hn-picture:[^>]+)>/).map { String($0.1) })
        // The address names the file, for the page's web view to be served.
        #expect(PreviewPictures.file(at: try #require(URL(string: address)))?.lastPathComponent == "Photo-1.png")

        // A paragraph, as `![](…)` is — sized or not: the box Edit measures
        // by. The size goes as Obsidian sizes a Markdown image, and the page
        // reads it (`NoteMarkdown.sizingPictures`).
        let sized = try await preview("![[Photo-1.png|120]]", in: root)
        #expect(sized.hasPrefix("![Photo-1.png\\|120](<hn-picture://"), "\(sized)")
        for page in [plain, sized] {
            let html = GFMRenderer.html(GitHubMarkdown.prepare(page))
            #expect(html.hasPrefix("<p><img src=\"hn-picture://"), "\(html)")
        }
        let shown = GFMRenderer.page(GitHubMarkdown.prepare(sized))
        #expect(shown.contains("alt=\"Photo-1.png\" width=\"120\" />"), "\(shown)")
        // Its words keep their pipes, and a table keeps its cell.
        let inTable = try await preview("| P |\n| --- |\n| ![[Photo-1.png\\|a\\|b\\|60]] |\n", in: root)
        let cell = GFMRenderer.page(GitHubMarkdown.prepare(inTable))
        #expect(cell.contains("alt=\"a|b\" width=\"60\" /></td>"), "\(cell)")

        // In a callout, Obsidian's usual frame for a figure — whose body goes
        // through the pass every other line does, outside a fence of its own.
        let callout = try await preview("> [!note] Figure\n> ![[Photo-1.png]]\n> ==marked==\n", in: root)
        #expect(callout.contains("hn-picture://"), "\(callout)")
        #expect(callout.contains("<mark class=\"hn-highlight\">marked</mark>"), "\(callout)")
        let fenced = try await preview("> [!note] Code\n> ```\n> ![[Photo-1.png]]\n> ```\n", in: root)
        #expect(!fenced.contains("hn-picture://"), "a fence's text was drawn: \(fenced)")

        // A picture not in the collection is said in words, not drawn blank.
        let missing = try await preview("![[Nowhere.png]]", in: root)
        #expect(missing == "!\\[\\[Nowhere.png\\]\\]")
        #expect(!GFMRenderer.html(GitHubMarkdown.prepare(missing)).contains("<img"))
    }

    /// The negative control: with no note to look from, the picture is not
    /// found — and is said in words, as a missing one is.
    @Test func withoutTheNoteAPictureIsNotFound() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try png(4, 2, at: root.appending(path: "assets/Photo-1.png"))
        let collection = Collection(rootURL: root)
        collection.scan()
        let page = await PreviewSuperset.apply(to: "![[Photo-1.png]]", isDark: false,
                                               embeds: collection.embedProvider)
        #expect(!page.contains("hn-picture://"))
    }
}
