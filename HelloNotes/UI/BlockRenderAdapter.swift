//
//  BlockRenderAdapter.swift
//  HelloNotes
//
//  Created by Chris Tham on 17/7/2026.
//
//  The new editor's BlockRenderer: turns block embeds into images drawn
//  inline. v1 renders `![[image-file]]` embeds (the common case — pasted
//  screenshots, saved diagrams); Mermaid and math follow. An actor confines
//  the (main-thread-only) AppKit image loading/scaling and caches by
//  resolved URL + size, so a restyle never re-reads or re-scales.
//

#if os(macOS)
import AppKit
import MarkdownEditor

actor BlockRenderAdapter: BlockRenderer {
    /// Resolve an embed target (`![[name]]`) to a file URL, or nil. Sendable
    /// so it can be captured across the actor boundary.
    private let resolve: @Sendable (String) -> URL?
    /// Render a Mermaid diagram to an image (off-main safe).
    private let renderMermaid: @Sendable (String, Bool) -> NSImage?
    /// Render a `$$…$$` block to an image (hops to the main actor inside).
    private let renderMath: @Sendable (String, Bool) async -> NSImage?
    /// Render a `![[Note]]` transclusion card (hops to the main actor inside).
    private let renderTransclusion: @Sendable (String, Bool) async -> NSImage?
    /// Render a GFM table to an aligned grid (hops to the main actor inside).
    private let renderTable: @Sendable (String, CGFloat, Bool) async -> NSImage?

    private var cache: [String: NSImage] = [:]

    init(
        resolve: @escaping @Sendable (String) -> URL?,
        renderMermaid: @escaping @Sendable (String, Bool) -> NSImage? = { _, _ in nil },
        renderMath: @escaping @Sendable (String, Bool) async -> NSImage? = { _, _ in nil },
        renderTransclusion: @escaping @Sendable (String, Bool) async -> NSImage? = { _, _ in nil },
        renderTable: @escaping @Sendable (String, CGFloat, Bool) async -> NSImage? = { _, _, _ in nil }
    ) {
        self.resolve = resolve
        self.renderMermaid = renderMermaid
        self.renderMath = renderMath
        self.renderTransclusion = renderTransclusion
        self.renderTable = renderTable
    }

    func render(_ kind: BlockEmbedKind, maxWidth: CGFloat, darkMode: Bool) async -> NSImage? {
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

    private func imageEmbed(url: URL, maxWidth: CGFloat) -> NSImage? {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        let key = "\(url.path)\u{1}\(mtime)\u{1}\(Int(maxWidth))"
        if let cached = cache[key] { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        let result = scaled(image, maxWidth: maxWidth) ?? image
        cache[key] = result
        return result
    }

    /// Downscale to fit `maxWidth` (never upscale past the natural size).
    private func scaled(_ image: NSImage?, maxWidth: CGFloat) -> NSImage? {
        guard let image, image.size.width > 0 else { return nil }
        let targetWidth = min(image.size.width, maxWidth)
        guard targetWidth < image.size.width else { return image }
        let ratio = targetWidth / image.size.width
        let size = NSSize(width: targetWidth, height: image.size.height * ratio)
        let out = NSImage(size: size)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }

    private static let imageExtensions: Set<String> =
        ["png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff", "svg"]
}
#endif
