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
import MarkdownEditor

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

actor BlockRenderAdapter: BlockRenderer {
    /// Resolve an embed target (`![[name]]`) to a file URL, or nil. Sendable
    /// so it can be captured across the actor boundary.
    private let resolve: @Sendable (String) -> URL?
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
        resolve: @escaping @Sendable (String) -> URL?,
        renderMermaid: @escaping @Sendable (String, Bool) async -> PlatformImage? = { _, _ in nil },
        renderMath: @escaping @Sendable (String, Bool) async -> PlatformImage? = { _, _ in nil },
        renderTransclusion: @escaping @Sendable (String, Bool) async -> PlatformImage? = { _, _ in nil },
        renderTable: @escaping @Sendable (String, CGFloat, Bool) async -> PlatformImage? = { _, _, _ in nil },
        renderHTML: @escaping @Sendable (String, CGFloat, Bool, Bool) async -> PlatformImage? = { _, _, _, _ in nil },
        renderInlineMath: @escaping @Sendable (String, CGFloat, Bool) async -> PlatformImage? = { _, _, _ in nil }
    ) {
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
        case .image(let target):
            // An image *file* → load + scale here (off-main). Otherwise the
            // target is a note → render a transclusion card on the main actor.
            if let url = resolve(target), Self.imageExtensions.contains(url.pathExtension.lowercased()) {
                return await imageEmbed(url: url, maxWidth: maxWidth)
            }
            return scaled(await renderTransclusion(target, darkMode), maxWidth: maxWidth)
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

    private func imageEmbed(url: URL, maxWidth: CGFloat) async -> PlatformImage? {
        // As the file is now: a URL answers from its first look off the main
        // run loop (`FileIO.currentResourceValues`, implemented.md §51.56).
        // Asked here and not on the picture's lane: a date is the file
        // system's to give, which no provider's hold holds up, and on a lane a
        // picture already drawn would wait behind another file's (§51.64).
        let mtime = (try? FileIO.currentResourceValues(at: url, keys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        let key = "\(url.path)\u{1}\(mtime)\u{1}\(Int(maxWidth))"
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
        let result = scaled(image, maxWidth: maxWidth) ?? image
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

    private static let imageExtensions: Set<String> =
        ["png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff", "svg"]
}
