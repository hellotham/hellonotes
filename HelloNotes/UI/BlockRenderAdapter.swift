//
//  BlockRenderAdapter.swift
//  HelloNotes
//
//  Created by Chris Tham on 17/7/2026.
//
//  The new editor's BlockRenderer: turns block embeds into images drawn
//  inline — `![[image-file]]` embeds, Mermaid, block/inline math, GFM tables,
//  and `![[Note]]` transclusion cards. An actor confines the (main-thread-only)
//  image loading/scaling and caches by resolved URL + size, so a restyle never
//  re-reads or re-scales. Cross-platform (`PlatformImage` via `PlatformImageKit`).
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
    /// Render a Mermaid diagram to an image (off-main safe).
    private let renderMermaid: @Sendable (String, Bool) -> PlatformImage?
    /// Render a `$$…$$` block to an image (hops to the main actor inside).
    private let renderMath: @Sendable (String, Bool) async -> PlatformImage?
    /// Render a `![[Note]]` transclusion card (hops to the main actor inside).
    private let renderTransclusion: @Sendable (String, Bool) async -> PlatformImage?
    /// Render a GFM table to an aligned grid (hops to the main actor inside).
    private let renderTable: @Sendable (String, CGFloat, Bool) async -> PlatformImage?
    /// Render an inline `$…$` math span (hops to the main actor inside).
    private let renderInlineMathFn: @Sendable (String, CGFloat, Bool) async -> PlatformImage?

    private var cache: [String: PlatformImage] = [:]

    init(
        resolve: @escaping @Sendable (String) -> URL?,
        renderMermaid: @escaping @Sendable (String, Bool) -> PlatformImage? = { _, _ in nil },
        renderMath: @escaping @Sendable (String, Bool) async -> PlatformImage? = { _, _ in nil },
        renderTransclusion: @escaping @Sendable (String, Bool) async -> PlatformImage? = { _, _ in nil },
        renderTable: @escaping @Sendable (String, CGFloat, Bool) async -> PlatformImage? = { _, _, _ in nil },
        renderInlineMath: @escaping @Sendable (String, CGFloat, Bool) async -> PlatformImage? = { _, _, _ in nil }
    ) {
        self.resolve = resolve
        self.renderMermaid = renderMermaid
        self.renderMath = renderMath
        self.renderTransclusion = renderTransclusion
        self.renderTable = renderTable
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
                return imageEmbed(url: url, maxWidth: maxWidth)
            }
            return scaled(await renderTransclusion(target, darkMode), maxWidth: maxWidth)
        case .mermaid(let source):
            return scaled(renderMermaid(source, darkMode), maxWidth: maxWidth)
        case .math(let source):
            return scaled(await renderMath(source, darkMode), maxWidth: maxWidth)
        case .table(let source):
            // The renderer sizes to maxWidth itself (no post-scale needed).
            return await renderTable(source, maxWidth, darkMode)
        }
    }

    private func imageEmbed(url: URL, maxWidth: CGFloat) -> PlatformImage? {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        let key = "\(url.path)\u{1}\(mtime)\u{1}\(Int(maxWidth))"
        if let cached = cache[key] { return cached }
        guard let image = PlatformImageKit.loadImage(contentsOf: url) else { return nil }
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
