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
    /// Render a Mermaid diagram to an image (reuses the app's renderer).
    private let renderMermaid: @Sendable (String, Bool) -> NSImage?

    private var cache: [String: NSImage] = [:]

    init(
        resolve: @escaping @Sendable (String) -> URL?,
        renderMermaid: @escaping @Sendable (String, Bool) -> NSImage? = { _, _ in nil }
    ) {
        self.resolve = resolve
        self.renderMermaid = renderMermaid
    }

    func render(_ kind: BlockEmbedKind, maxWidth: CGFloat, darkMode: Bool) async -> NSImage? {
        switch kind {
        case .image(let target):
            return imageEmbed(target: target, maxWidth: maxWidth)
        case .mermaid(let source):
            return scaled(renderMermaid(source, darkMode), maxWidth: maxWidth)
        case .math:
            return nil   // M3c — needs a math renderer dependency
        }
    }

    private func imageEmbed(target: String, maxWidth: CGFloat) -> NSImage? {
        // Only real image files (note transclusion embeds are handled by the
        // old-engine path and aren't rendered inline yet).
        guard let url = resolve(target),
              Self.imageExtensions.contains(url.pathExtension.lowercased()) else { return nil }
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
