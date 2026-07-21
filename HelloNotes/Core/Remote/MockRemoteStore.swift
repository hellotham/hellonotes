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

final class MockRemoteStore: RemoteStore, @unchecked Sendable {
    let providerName = "Demo cloud"
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

    var isAuthenticated: Bool { authed }
    func authenticate() async throws { authed = true }
    func signOut() { authed = false }

    func list(path: String) async throws -> [RemoteEntry] {
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

    func read(path: String) async throws -> Data {
        guard authed else { throw RemoteStoreError.notAuthenticated }
        guard let d = files[path] else { throw RemoteStoreError.http(409, "path/not_found") }
        return d
    }

    func write(_ data: Data, to path: String) async throws {
        guard authed else { throw RemoteStoreError.notAuthenticated }
        files[path] = data
    }

    func delete(path: String) async throws {
        guard authed else { throw RemoteStoreError.notAuthenticated }
        files[path] = nil
        folders.remove(path)
    }

    private static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<slash])   // "" for a root-level item
    }
    private static func name(_ path: String) -> String {
        String(path[(path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex)...])
    }
}
