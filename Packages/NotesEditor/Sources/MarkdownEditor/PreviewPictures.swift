//
//  PreviewPictures.swift
//  MarkdownEditor
//
//  Pictures a Preview page shows by a private address: the files a note's
//  `![[…]]` embeds name, wherever in the collection they are.
//

import Foundation
import Synchronization
import WebKit

/// Addresses for the pictures a Preview page shows, and the reader behind them.
///
/// **Why not a path.** Preview loads its page with the note's folder as its
/// base, and a `WKWebView` reads a `file:` URL only inside what it has been
/// granted — that folder (`BlockAssetScheme` says the same of an HTML block's
/// page). An Obsidian vault keeps its pictures wherever its settings say:
/// the vault's top folder by default, one folder for all of them, or one
/// beside each note. `![[photo.png]]` names one *by name* from anywhere, so
/// the file is as often in a folder beside the note's as under it — and on
/// an iPad the vault is in iCloud Drive, outside the app's container, where
/// the app can read it only through the folder's security scope, which the
/// web view does not hold. So the page names the picture by an address of
/// this scheme, and the app reads the file — through its own coordinated
/// read, which waits for a file still in the cloud — and hands the bytes over.
///
/// **Only what a page was given.** An address is a token the app made for a
/// file it had already resolved (`address(of:modified:)`), so a note cannot
/// ask for a file by writing its path into an `<img>`: an address no page was
/// given names nothing.
public nonisolated enum PreviewPictures {
    /// The scheme of every address.
    public static let scheme = "hn-picture"

    private struct Registry {
        var tokens: [String: String] = [:]      // file path → token
        var files: [String: URL] = [:]          // token → file
        var read: (@Sendable (URL) async -> Data?)?
    }

    private static let registry = Mutex(Registry())

    /// How a picture is read — the app's coordinated read, set once at
    /// launch. Without one (this package's own tests) the file is read
    /// plainly, off the main actor.
    public static func setReader(_ read: @escaping @Sendable (URL) async -> Data?) {
        registry.withLock { $0.read = read }
    }

    /// The address a page shows `file` by. One file has one token for the
    /// life of the process, so a page built again is the same page and the
    /// web view does not load it again; `modified` is part of the address so
    /// that a picture changed on disk is fetched again rather than served
    /// from the web view's cache.
    public static func address(of file: URL, modified: Date?) -> URL {
        let token = registry.withLock { state -> String in
            if let known = state.tokens[file.path] { return known }
            let made = UUID().uuidString.lowercased()
            state.tokens[file.path] = made
            state.files[made] = file
            return made
        }
        let version = modified.map { String(Int($0.timeIntervalSinceReferenceDate * 1000)) } ?? "0"
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "picture"
        // The name last, so the address says what it is to anyone reading
        // the page, and so WebKit has an extension to go by.
        parts.path = "/\(token)/\(version)/\(file.lastPathComponent)"
        return parts.url ?? URL(string: "\(scheme)://picture/\(token)/\(version)")!
    }

    /// The file an address names, if a page was given it.
    public static func file(at address: URL) -> URL? {
        let parts = address.pathComponents.filter { $0 != "/" }
        guard address.scheme == scheme, let token = parts.first else { return nil }
        return registry.withLock { $0.files[token] }
    }

    static func read(_ file: URL) async -> Data? {
        if let read = registry.withLock({ $0.read }) { return await read(file) }
        return await Task.detached { try? Data(contentsOf: file) }.value
    }
}

/// Answers a Preview page's requests for `hn-picture:` addresses
/// (`PreviewPictures`). One per web view, made with it.
final class PreviewPictureScheme: NSObject, WKURLSchemeHandler {
    /// Reads under way that WebKit has not stopped — the only ones that may
    /// still be answered — kept so a stop can stop the read with them.
    private var reading: [ObjectIdentifier: Task<Void, Never>] = [:]

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let file = PreviewPictures.file(at: url) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        let id = ObjectIdentifier(task)
        reading[id] = Task { @MainActor in
            let data = await PreviewPictures.read(file)
            // Stopped meanwhile: answering it now is an exception in WebKit.
            guard self.reading.removeValue(forKey: id) != nil else { return }
            guard let data else { return task.didFailWithError(URLError(.fileDoesNotExist)) }
            task.didReceive(URLResponse(url: url, mimeType: Self.mime(of: data, named: file),
                                        expectedContentLength: data.count, textEncodingName: nil))
            task.didReceive(data)
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        reading.removeValue(forKey: ObjectIdentifier(task))?.cancel()
    }

    /// By content where it says, and by name where it does not: a wrong
    /// `Content-Type` is a picture that does not draw.
    private static func mime(of data: Data, named file: URL) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: [0xFF, 0xD8]) { return "image/jpeg" }
        if data.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if data.starts(with: Array("<svg".utf8)) || data.starts(with: Array("<?xml".utf8)) {
            return "image/svg+xml"
        }
        switch file.pathExtension.lowercased() {
        case "webp": return "image/webp"
        case "avif": return "image/avif"
        case "heic", "heif": return "image/heic"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }
}
