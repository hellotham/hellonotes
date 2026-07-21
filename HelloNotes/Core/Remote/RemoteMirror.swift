//
//  RemoteMirror.swift
//  HelloNotes
//
//  Created by Chris Tham on 21/7/2026.
//
//  Bridges a `RemoteStore` (Dropbox, …) into the app's filesystem-based
//  `Collection` model so a cloud account can be a *first-class collection* in the
//  sidebar. It mirrors the remote folder into a local cache directory; that cache
//  is opened as an ordinary `Collection`, so every existing surface — scan,
//  index, backlinks, the editor, `FileIO` — works unchanged. Edits saved into the
//  cache are uploaded back to the provider (`Collection.noteDidSave` calls
//  `upload`).
//
//  MVP scope: `syncDown()` fetches the folder's Markdown eagerly (notes vaults are
//  small); on-demand hydration of a remote collection is a later refinement.
//

import Foundation

final class RemoteMirror {
    let store: RemoteStore
    /// Local cache directory that stands in for the remote folder.
    let cacheRoot: URL
    /// Provider-absolute path of the mirrored folder ("" = provider root).
    let remoteRoot: String
    /// Shown in the sidebar (the remote folder's name, or the provider name at root).
    let displayName: String

    init(store: RemoteStore, cacheRoot: URL, remoteRoot: String, displayName: String) {
        self.store = store
        self.cacheRoot = cacheRoot
        self.remoteRoot = DropboxPath.normalize(remoteRoot)
        self.displayName = displayName
    }

    // MARK: - Path mapping

    /// The local cache URL for a provider-absolute path.
    func localURL(forRemotePath path: String) -> URL {
        let p = DropboxPath.normalize(path)
        var rel = p
        if !remoteRoot.isEmpty, p.hasPrefix(remoteRoot) {
            rel = String(p.dropFirst(remoteRoot.count))
        }
        rel = rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
        return cacheRoot.appendingPathComponent(rel)
    }

    /// The provider-absolute path for a local cache URL.
    func remotePath(forLocalURL url: URL) -> String {
        let rel = url.standardizedFileURL.path
            .replacingOccurrences(of: cacheRoot.standardizedFileURL.path, with: "")
        let clean = rel.hasPrefix("/") ? rel : "/" + rel
        return remoteRoot.isEmpty ? clean : remoteRoot + clean
    }

    // MARK: - Sync

    /// Fetch the remote folder's Markdown into the local cache (recursive).
    func syncDown() async throws {
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        var folders = [remoteRoot]
        while let folder = folders.popLast() {
            let entries = try await store.list(path: folder)
            for entry in entries {
                if entry.isDirectory {
                    folders.append(entry.path)
                    try? FileManager.default.createDirectory(
                        at: localURL(forRemotePath: entry.path), withIntermediateDirectories: true)
                } else if entry.name.lowercased().hasSuffix(".md") {
                    let data = try await store.read(path: entry.path)
                    let dest = localURL(forRemotePath: entry.path)
                    try? FileManager.default.createDirectory(
                        at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: dest, options: .atomic)
                }
            }
        }
    }

    /// Upload a locally-saved note back to the provider. Best-effort — a failure
    /// is surfaced by the caller; the local cache still holds the edit.
    func upload(localURL url: URL) async throws {
        let data = try FileIO.readData(at: url)
        try await store.write(data, to: remotePath(forLocalURL: url))
    }

    // MARK: - Cache location

    /// A stable per-provider/per-folder cache directory in Application Support
    /// (not Caches — the system may purge Caches, and this is the working copy).
    static func cacheDirectory(provider: String, folder: String) -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let safeFolder = folder.isEmpty ? "root" : folder
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return base
            .appendingPathComponent("RemoteMirror", isDirectory: true)
            .appendingPathComponent(provider.lowercased(), isDirectory: true)
            .appendingPathComponent(safeFolder.isEmpty ? "root" : safeFolder, isDirectory: true)
    }
}

/// Small Dropbox-style path helpers (shared with DropboxStore's conventions).
enum DropboxPath {
    static func normalize(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespaces)
        if p == "/" || p.isEmpty { return "" }
        if !p.hasPrefix("/") { p = "/" + p }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
