//
//  BlockRenderAdapter.swift
//  HelloNotes
//
//  Created by Chris Tham on 17/7/2026.
//
//  The new editor's BlockRenderer: turns block embeds into images drawn
//  inline — `![[image-file]]` embeds, Mermaid, block/inline math, GFM tables,
//  and `![[Note]]` transclusion cards. A background `actor` runs the image
//  loading + scaling off-main (scaling is off-main-safe via `PlatformImageKit`'s
//  CGContext path) and caches by resolved URL + size, so a restyle never
//  re-reads or re-scales. Image *creation* for the AppKit/UIKit renderers hops
//  to the main actor inside each closure. Cross-platform via `PlatformImageKit`.
//

import Foundation
import CoreGraphics
import MarkdownCore
import MarkdownEditor
import Synchronization

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Where the note a renderer draws for is, and its pictures folder — as of
/// now. A note renamed or moved keeps its document (`EditorDocumentStore
/// .documentMoved`), and the document keeps the renderer it was made with:
/// read once, at the making, its pictures were looked for from the folder the
/// note had left — drawn in Edit where Preview, which reads from where the
/// note is, found none. The editor's host says where it is each time it shows
/// the document, and when the setting changes.
nonisolated final class NotePlace: Sendable {
    struct Spot: Sendable, Equatable {
        var note: URL
        var attachmentFolder: String
    }

    private let spot: Mutex<Spot>

    init(note: URL, attachmentFolder: String) {
        spot = Mutex(Spot(note: note, attachmentFolder: attachmentFolder.trimmingCharacters(in: .whitespaces)))
    }

    var now: Spot { spot.withLock { $0 } }

    func update(note: URL, attachmentFolder: String) {
        let new = Spot(note: note, attachmentFolder: attachmentFolder.trimmingCharacters(in: .whitespaces))
        spot.withLock { $0 = new }
    }
}

actor BlockRenderAdapter: BlockRenderer {
    /// Where the note is (`NotePlace`), for a host to keep current — `nil`
    /// for a renderer that draws for no note.
    nonisolated let place: NotePlace?
    /// The file a picture names, or nil. Asynchronous, because an
    /// `![[photo.png]]` is found among the collection's pictures, and a note
    /// opened at launch is drawn before the collection's walk has listed them
    /// (`CollectionEmbedProvider.pictureURL`).
    private let resolve: @Sendable (PictureEmbed) async -> URL?
    /// Render a Mermaid diagram to an image (hops to the main actor inside —
    /// the macOS flip uses AppKit image drawing, which is main-thread-only).
    private let renderMermaid: @Sendable (String, Bool) async -> PlatformImage?
    /// Render a `$$…$$` block to an image (hops to the main actor inside).
    private let renderMath: @Sendable (String, Bool) async -> PlatformImage?
    /// Render a `![[Note]]` transclusion card (hops to the main actor inside).
    private let renderTransclusion: @Sendable (String, Bool) async -> PlatformImage?
    /// Render a GFM table to an aligned grid (hops to the main actor inside).
    private let renderTable: @Sendable (String, CGFloat, Bool) async -> PlatformImage?
    /// Render a raw HTML block through WebKit (hops to the main actor inside).
    private let renderHTML: @Sendable (String, CGFloat, Bool, Bool) async -> PlatformImage?
    /// Render an inline `$…$` math span (hops to the main actor inside).
    private let renderInlineMathFn: @Sendable (String, CGFloat, Bool) async -> PlatformImage?

    private var cache: [String: PlatformImage] = [:]
    /// The picture reads in flight, by file and date: one read for a picture
    /// however many ask for it at once. The actor lets the next caller in
    /// while a read waits, and each began a read of its own (implemented.md
    /// §51.64).
    private var reads: [String: Task<Data?, Never>] = [:]

    init(
        place: NotePlace? = nil,
        resolve: @escaping @Sendable (PictureEmbed) async -> URL?,
        renderMermaid: @escaping @Sendable (String, Bool) async -> PlatformImage? = { _, _ in nil },
        renderMath: @escaping @Sendable (String, Bool) async -> PlatformImage? = { _, _ in nil },
        renderTransclusion: @escaping @Sendable (String, Bool) async -> PlatformImage? = { _, _ in nil },
        renderTable: @escaping @Sendable (String, CGFloat, Bool) async -> PlatformImage? = { _, _, _ in nil },
        renderHTML: @escaping @Sendable (String, CGFloat, Bool, Bool) async -> PlatformImage? = { _, _, _, _ in nil },
        renderInlineMath: @escaping @Sendable (String, CGFloat, Bool) async -> PlatformImage? = { _, _, _ in nil }
    ) {
        self.place = place
        self.resolve = resolve
        self.renderMermaid = renderMermaid
        self.renderMath = renderMath
        self.renderTransclusion = renderTransclusion
        self.renderTable = renderTable
        self.renderHTML = renderHTML
        self.renderInlineMathFn = renderInlineMath
    }

    func renderInlineMath(_ latex: String, fontSize: CGFloat, darkMode: Bool) async -> PlatformImage? {
        await renderInlineMathFn(latex, fontSize, darkMode)
    }

    func render(_ kind: BlockEmbedKind, maxWidth: CGFloat, darkMode: Bool) async -> PlatformImage? {
        switch kind {
        case .image(let target, let isWikiEmbed, let width, let height):
            // A picture → load + scale here (off-main), at the size the note
            // asks for (`![[photo.png|300]]`, `![A cat|300](cat.png)`, read
            // by the editor). Otherwise the target is a note → render a
            // transclusion card on the main actor.
            let picture = PictureEmbed(target: target, isWikiEmbed: isWikiEmbed)
            if picture.isPicture {
                guard let url = await resolve(picture) else { return nil }
                // The editor's reading, or — asked by something that did not
                // read one — the embed's own.
                let asked = width != nil || height != nil
                return await imageEmbed(url: url, maxWidth: maxWidth,
                                        width: asked ? width : picture.width,
                                        height: asked ? height : picture.height)
            }
            // The note the embed names, as every reader of a link reads it
            // (`WikiLinkSyntax`): `![[Note|alias]]` names `Note`. Handed the
            // inner text whole, the card looked up `Note|alias` and was never
            // drawn — in Edit, while Preview, which split it, drew it.
            let note = isWikiEmbed ? String(WikiLinkSyntax.split(target).target) : target
            return scaled(await renderTransclusion(note, darkMode), maxWidth: maxWidth)
        case .mermaid(let source):
            return scaled(await renderMermaid(source, darkMode), maxWidth: maxWidth)
        case .math(let source):
            return scaled(await renderMath(source, darkMode), maxWidth: maxWidth)
        case .table(let source):
            // The renderer sizes to maxWidth itself (no post-scale needed).
            return await renderTable(source, maxWidth, darkMode)
        case .html(let source, let keepsTrailingMargin):
            // Rendered at maxWidth by WebKit, so it needs no post-scale either.
            return await renderHTML(source, maxWidth, darkMode, keepsTrailingMargin)
        }
    }

    /// `width` and `height` are the size the note asks for, which Preview's
    /// `<img width height>` honours as well — up past the picture's own size
    /// and down to the pane's width, as `max-width: 100%` does.
    private func imageEmbed(url: URL, maxWidth: CGFloat, width: Int? = nil, height: Int? = nil) async -> PlatformImage? {
        // As the file is now: a URL answers from its first look off the main
        // run loop (`FileIO.currentResourceValues`, implemented.md §51.56).
        // Asked here and not on the picture's lane: a date is the file
        // system's to give, which no provider's hold holds up, and on a lane a
        // picture already drawn would wait behind another file's (§51.64).
        let mtime = (try? FileIO.currentResourceValues(at: url, keys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        let key = "\(url.path)\u{1}\(mtime)\u{1}\(Int(maxWidth))\u{1}\(width ?? 0)x\(height ?? 0)"
        if let cached = cache[key] { return cached }
        // Through `FileIO`: waited for if it is online-only, with a deadline,
        // then read under coordination. It was read raw — racing a provider
        // still writing it, and holding a thread of the pool while one still
        // downloading came (implemented.md §51.64).
        let file = "\(url.path)\u{1}\(mtime)"
        let read = reads[file] ?? Task { await FileIO.embeddedData(at: url) }
        reads[file] = read
        let data = await read.value
        // Only its own: a read begun for the file since, by a caller after the
        // last one left, is that caller's.
        if reads[file] == read { reads[file] = nil }
        // Drawn at this width by whoever asked first, while this waited.
        if let cached = cache[key] { return cached }
        guard let data, let image = PlatformImageKit.loadImage(data: data, named: url.lastPathComponent)
        else { return nil }
        let result = sized(image, maxWidth: maxWidth, width: width, height: height) ?? image
        // Keys are mtime-versioned; bound the cache so edited/embedded images
        // don't accumulate rendered images for the process lifetime.
        if cache.count > 64 { cache.removeAll(keepingCapacity: true) }
        cache[key] = result
        return result
    }

    /// Downscale to fit `maxWidth` (never upscale past the natural size).
    private func scaled(_ image: PlatformImage?, maxWidth: CGFloat) -> PlatformImage? {
        guard let image, image.size.width > 0 else { return nil }
        return PlatformImageKit.scaled(image, maxWidth: maxWidth)
    }

    /// A picture at the size its note asks for, as a page lays out
    /// `<img width="W" height="H">` under `max-width: 100%`
    /// (`PictureNames.drawnSize`, the rule the parity harness draws by too).
    private func sized(_ image: PlatformImage, maxWidth: CGFloat, width: Int?, height: Int?) -> PlatformImage? {
        let natural = image.size
        guard natural.width > 0, natural.height > 0 else { return nil }
        guard width != nil || height != nil else { return scaled(image, maxWidth: maxWidth) }
        let size = PictureNames.drawnSize(natural: natural, maxWidth: maxWidth, width: width, height: height)
        return PlatformImageKit.resized(image, to: size)
    }
}
