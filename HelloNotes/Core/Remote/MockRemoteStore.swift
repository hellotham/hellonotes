//
//  MockRemoteStore.swift
//  HelloNotes
//
//  Created by Chris Tham on 21/7/2026.
//
//  An in-memory RemoteStore for driving the Dropbox browse/open/edit/save flow
//  end-to-end without a live provider — used by the "Demo cloud" entry point and
//  by RemoteBrowserModel's unit tests. It exercises exactly the same protocol the
//  real DropboxStore implements, so the UI and model logic are validated even
//  before a real Dropbox app key exists.
//

import Foundation

/// `nonisolated`, as every store is (`RemoteStore`) — so its state is behind a
/// lock: a walk lists six folders at once, away from the main actor.
nonisolated final class MockRemoteStore: RemoteStore, @unchecked Sendable {
    let providerName = "Demo cloud"
    let accountID = "mock"
    private let lock = NSLock()
    private var authed: Bool
    private var files: [String: Data]
    private var folders: Set<String>

    init(preAuthenticated: Bool = false) {
        self.authed = preAuthenticated
        self.files = [
            "/Welcome.md": Data("# Welcome to the demo cloud\n\nThis note lives only in memory — it proves the direct-API browse/open/edit/save loop works end to end.".utf8),
            "/Notes/Idea.md": Data("# Idea\n\n- Fan out\n- Verify\n- Ship".utf8),
            "/Notes/Tasks.md": Data("# Tasks\n\n- [ ] wire it up\n- [x] test it".utf8),
        ]
        self.folders = ["/Notes"]
    }

    var isAuthenticated: Bool { lock.withLock { authed } }
    func authenticate() async throws { lock.withLock { authed = true } }
    func signOut() { lock.withLock { authed = false } }

    func list(path: String) async throws -> [RemoteEntry] {
        try lock.withLock {
            guard authed else { throw RemoteStoreError.notAuthenticated }
            let base = (path == "/" ? "" : path)
            var out: [RemoteEntry] = []
            for f in folders where Self.parent(of: f) == base {
                out.append(RemoteEntry(path: f, name: Self.name(f), isDirectory: true, size: 0, modified: nil, rev: nil))
            }
            for (p, d) in files where Self.parent(of: p) == base {
                out.append(RemoteEntry(path: p, name: Self.name(p), isDirectory: false, size: d.count, modified: nil, rev: nil))
            }
            return out.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }   // folders first
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    func read(path: String) async throws -> Data {
        try lock.withLock {
            guard authed else { throw RemoteStoreError.notAuthenticated }
            guard let d = files[path] else { throw RemoteStoreError.http(409, "path/not_found") }
            return d
        }
    }

    func write(_ data: Data, to path: String) async throws {
        try lock.withLock {
            guard authed else { throw RemoteStoreError.notAuthenticated }
            files[path] = data
        }
    }

    func delete(path: String) async throws {
        try lock.withLock {
            guard authed else { throw RemoteStoreError.notAuthenticated }
            files[path] = nil
            folders.remove(path)
        }
    }

    func move(from source: String, to destination: String) async throws {
        try lock.withLock {
            guard authed else { throw RemoteStoreError.notAuthenticated }
            guard files[destination] == nil, !folders.contains(destination) else {
                throw RemoteStoreError.http(409, "to/conflict")
            }
            if let data = files.removeValue(forKey: source) {
                files[destination] = data
                return
            }
            guard folders.contains(source) else { throw RemoteStoreError.http(409, "from_lookup/not_found") }
            func moved(_ path: String) -> String {
                path == source || path.hasPrefix(source + "/") ? destination + path.dropFirst(source.count) : path
            }
            folders = Set(folders.map(moved))
            files = Dictionary(uniqueKeysWithValues: files.map { (moved($0.key), $0.value) })
        }
    }

    func createFolder(path: String) async throws {
        try lock.withLock {
            guard authed else { throw RemoteStoreError.notAuthenticated }
            guard files[path] == nil, !folders.contains(path) else { throw RemoteStoreError.http(409, "path/conflict") }
            folders.insert(path)
        }
    }

    private static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<slash])   // "" for a root-level item
    }
    private static func name(_ path: String) -> String {
        String(path[(path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex)...])
    }
}
