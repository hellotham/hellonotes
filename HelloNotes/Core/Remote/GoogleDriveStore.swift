//
//  GoogleDriveStore.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/7/2026.
//
//  A `RemoteStore` over the Google Drive API v3 using plain URLSession — no
//  Google SDK. Third provider on the shared RemoteBrowser / RemoteMirror /
//  sidebar-collection machinery.
//
//  Google-specific traits this file absorbs:
//  1. **PKCE public client, reversed-scheme redirect.** Google's iOS-type OAuth
//     client needs no secret; the redirect URI is derived from the client id
//     (`com.googleusercontent.apps.<id-prefix>:/oauth2redirect`), so nothing is
//     configured in the console and the callback scheme is computed at runtime.
//     (`ASWebAuthenticationSession` doesn't require Info.plist registration.)
//  2. **ID-addressed files, like Box.** The root's alias is `root`; folders are
//     files with `mimeType application/vnd.google-apps.folder`; listing a folder
//     is a `q='<id>' in parents and trashed=false` query. The path-based
//     RemoteStore calls go through the same cached path→ID bridging as BoxStore.
//  3. Uploads: new files via multipart/related (metadata JSON + media);
//     updates via a plain media PATCH.
//
//  Config: `GOOGLE_CLIENT_ID` in Config/Secrets.xcconfig → Info.plist
//  (`GoogleClientID`). Refresh tokens are returned on first authorization and
//  do not rotate (unlike Box).
//

import Foundation
import CryptoKit
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

final class GoogleDriveStore: NSObject, RemoteStore, @unchecked Sendable {
    let providerName = "Google Drive"
    /// The Keychain keys for *this* account's tokens.
    ///
    /// Scoped by account id, because a person may hold more than one account
    /// on the same service — a personal and a work OneDrive is the ordinary
    /// case. Keyed by the provider alone, the second sign-in overwrote the
    /// first one's token and the app could hold exactly one account per
    /// provider with no way to name or choose between them.
    let accountID: String
    private var tokenAccount: String { "gdrive#\(accountID)" }
    private var refreshAccount: String { tokenAccount + "-refresh" }
    static let folderMIME = "application/vnd.google-apps.folder"

    private var clientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String) ?? ""
    }
    private let session: URLSession

    /// Path→ID caches (normalized path keys). Root is Drive's alias "root".
    private let cacheLock = NSLock()
    private var folderIDs: [String: String] = ["": "root"]
    private var fileIDs: [String: String] = [:]

    /// The path we know a Drive id by, if we have listed it.
    ///
    /// Drive's change feed reports ids and no paths, so this reverse lookup is
    /// what places a change in the tree. An id we have never seen is something
    /// in a folder we have not walked — a full sync finds it, and guessing would
    /// be worse than waiting.
    fileprivate func knownPath(forFileID id: String) -> String? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let hit = fileIDs.first(where: { $0.value == id })?.key { return hit }
        return folderIDs.first(where: { $0.value == id })?.key
    }

    init(session: URLSession = .shared, accountID: String) {
        self.accountID = accountID
        self.session = session
    }

    var isAuthenticated: Bool { RemoteTokenStore.token(for: tokenAccount) != nil }

    private func requireToken() throws -> String {
        guard let token = RemoteTokenStore.token(for: tokenAccount) else {
            throw RemoteStoreError.notAuthenticated
        }
        return token
    }

    func signOut() {
        RemoteTokenStore.setToken(nil, for: tokenAccount)
        RemoteTokenStore.setToken(nil, for: refreshAccount)
        cacheLock.lock()
        folderIDs = ["": "root"]
        fileIDs = [:]
        cacheLock.unlock()
    }

    // MARK: - CRUD (path-based over Drive's ID-based API)

    /// Lists a folder in full, following Drive's `nextPageToken`. Without the
    /// loop a folder past one page silently loses its tail — and since IDs are
    /// primed here, those files then fail to read/write with a 404.
    func list(path: String) async throws -> [RemoteEntry] {
        let folderID = try await resolveFolderID(path: path)
        let parentPath = Self.normalizedPath(path)
        var all: [RemoteEntry] = []
        var pageToken: String?
        repeat {
            let token = pageToken
            let data = try await sendAuthed {
                Self.listRequest(folderID: folderID, token: $0, pageToken: token)
            }
            let page = try Self.parseFileListPage(data, parentPath: parentPath)
            cacheLock.lock()
            for item in page.items {
                if item.entry.isDirectory { folderIDs[item.entry.path] = item.id }
                else { fileIDs[item.entry.path] = item.id }
            }
            cacheLock.unlock()
            all += page.items.map(\.entry)
            pageToken = page.nextPageToken
        } while pageToken != nil
        return all
    }

    /// Every item under `path`, in a handful of queries instead of one per
    /// folder.
    ///
    /// **Drive has no "descendant of" query**, which is why this is shaped
    /// differently from Dropbox's and Graph's — both of those hand back a whole
    /// subtree directly. What Drive does allow is `'a' in parents or 'b' in
    /// parents …`, so the subtree can be assembled in two steps:
    ///
    ///   1. one query for *every folder* in the Drive, asking for `parents`.
    ///      Folders are orders of magnitude fewer than files, so this is a page
    ///      or two, and it is enough to compute the vault's whole folder tree
    ///      locally — including the paths, which Drive never returns.
    ///   2. the files, asked for fifty parents at a time.
    ///
    /// Three hundred folders cost roughly eight queries this way rather than
    /// three hundred listings six at a time. Any failure returns nil and the
    /// caller walks exactly as before — a partial tree would be worse than a
    /// slow one, because the walk's output is what the collection believes.
    func listRecursively(path: String) async throws -> [RemoteEntry]? {
        let rootID = try await resolveFolderID(path: path)
        let rootPath = Self.normalizedPath(path)

        // 1 · every folder, with its parent, so the tree can be built here.
        var folderName: [String: String] = [:]
        var folderParent: [String: String] = [:]
        var pageToken: String?
        repeat {
            let token = pageToken
            let data = try await sendAuthed { Self.allFoldersRequest(token: $0, pageToken: token) }
            guard let page = try? Self.parseFolderTreePage(data) else { return nil }
            for folder in page.folders {
                folderName[folder.id] = folder.name
                if let parent = folder.parent { folderParent[folder.id] = parent }
            }
            pageToken = page.nextPageToken
        } while pageToken != nil

        // Descendants of the vault root, with the path each one has.
        var pathByID: [String: String] = [rootID: rootPath]
        var childrenOf: [String: [String]] = [:]
        for (id, parent) in folderParent { childrenOf[parent, default: []].append(id) }
        var queue = [rootID]
        var subtree: [String] = [rootID]
        var folders: [RemoteEntry] = []
        while let id = queue.popLast() {
            for child in childrenOf[id] ?? [] {
                guard let name = folderName[child], pathByID[child] == nil else { continue }
                let childPath = (pathByID[id] ?? rootPath) + "/" + name
                pathByID[child] = childPath
                subtree.append(child)
                queue.append(child)
                folders.append(RemoteEntry(path: childPath, name: name,
                                           isDirectory: true, size: 0))
            }
        }

        // 2 · the files, fifty parents at a time — Drive's query has a length
        // limit and an `or` chain is the only way to ask about several parents.
        var files: [RemoteEntry] = []
        var idsByPath: [String: String] = [:]
        for chunk in stride(from: 0, to: subtree.count, by: 50).map({
            Array(subtree[$0..<min($0 + 50, subtree.count)])
        }) {
            var token: String?
            repeat {
                let pageToken = token
                let data = try await sendAuthed {
                    Self.filesInParentsRequest(parents: chunk, token: $0, pageToken: pageToken)
                }
                guard let page = try? Self.parseFilesInParentsPage(data) else { return nil }
                for item in page.items where !item.isFolder {
                    guard let parent = item.parent, let base = pathByID[parent] else { continue }
                    let full = base + "/" + item.name
                    files.append(RemoteEntry(path: full, name: item.name, isDirectory: false,
                                             size: item.size, modified: item.modified))
                    idsByPath[full] = item.id
                }
                token = page.nextPageToken
            } while token != nil
        }

        // Seed the id caches, so reading a file afterwards costs no extra
        // resolution — the walk used to populate these as a side effect.
        cacheLock.lock()
        for (id, p) in pathByID where !p.isEmpty { folderIDs[p] = id }
        for (p, id) in idsByPath { fileIDs[p] = id }
        cacheLock.unlock()

        return folders + files
    }

    func changes(since cursor: String?, path: String) async throws -> RemoteChangeSet? {
        guard let cursor else {
            // No token yet: take one, and let this round be a full sync.
            let data = try await sendAuthed { Self.startPageTokenRequest(token: $0) }
            return RemoteChangeSet(cursor: Self.parseStartPageToken(data))
        }

        var result = RemoteChangeSet()
        var next: String? = cursor
        while let token = next {
            let data = try await sendAuthed { Self.changesRequest(pageToken: token, token: $0) }
            let page = Self.parseChangesPage(data)
            // Drive hands back ids, not paths. Only files we already know the
            // path of can be placed; anything else is new somewhere we have not
            // walked, and a full sync will find it.
            for change in page.changed {
                if let known = knownPath(forFileID: change.id) {
                    var entry = change.entry
                    entry.path = known
                    result.changed.append(entry)
                }
            }
            result.deleted += page.removed.compactMap { knownPath(forFileID: $0) }
            if let newStart = page.newStart { result.cursor = newStart }
            next = page.next
        }
        return result
    }

    func latestCursor(path: String) async throws -> String? {
        let data = try await sendAuthed { Self.startPageTokenRequest(token: $0) }
        return Self.parseStartPageToken(data)
    }

    func read(path: String) async throws -> Data {
        let id = try await resolveFileID(path: path)
        return try await sendAuthed { Self.downloadRequest(fileID: id, token: $0) }
    }

    func write(_ data: Data, to path: String) async throws {
        let p = Self.normalizedPath(path)
        let name = String(p.split(separator: "/").last ?? "untitled.md")
        if let id = try? await resolveFileID(path: p) {
            _ = try await sendAuthed { Self.updateRequest(fileID: id, data: data, token: $0) }
        } else {
            let parentID = try await resolveFolderID(path: Self.parentPath(of: p))
            let response = try await sendAuthed {
                Self.createRequest(name: name, parentID: parentID, data: data,
                                   token: $0, boundary: Self.makeBoundary())
            }
            if let id = Self.parseFileID(response) {
                cacheLock.lock(); fileIDs[p] = id; cacheLock.unlock()
            }
        }
    }

    func delete(path: String) async throws {
        let p = Self.normalizedPath(path)
        if let id = try? await resolveFileID(path: p) {
            _ = try await sendAuthed { Self.deleteRequest(fileID: id, token: $0) }
            cacheLock.lock(); fileIDs[p] = nil; cacheLock.unlock()
        } else {
            let id = try await resolveFolderID(path: p)
            _ = try await sendAuthed { Self.deleteRequest(fileID: id, token: $0) }
            cacheLock.lock(); folderIDs[p] = nil; cacheLock.unlock()
        }
    }

    // MARK: - Path → ID resolution (same walk-down bridging as BoxStore)

    private func cachedFolderID(_ path: String) -> String? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return folderIDs[path]
    }

    private func cachedFileID(_ path: String) -> String? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return fileIDs[path]
    }

    private func resolveFolderID(path: String) async throws -> String {
        let p = Self.normalizedPath(path)
        if let id = cachedFolderID(p) { return id }
        var currentPath = ""
        for component in p.split(separator: "/").map(String.init) {
            let childPath = currentPath + "/" + component
            if cachedFolderID(childPath) == nil {
                _ = try await list(path: currentPath)
            }
            guard cachedFolderID(childPath) != nil else {
                throw RemoteStoreError.http(404, "No folder named “\(component)” in “\(currentPath.isEmpty ? "My Drive" : currentPath)”")
            }
            currentPath = childPath
        }
        guard let id = cachedFolderID(p) else {
            throw RemoteStoreError.http(404, "Couldn't resolve folder “\(p)”")
        }
        return id
    }

    private func resolveFileID(path: String) async throws -> String {
        let p = Self.normalizedPath(path)
        if let id = cachedFileID(p) { return id }
        _ = try await list(path: Self.parentPath(of: p))
        guard let id = cachedFileID(p) else {
            throw RemoteStoreError.http(404, "No file at “\(p)”")
        }
        return id
    }

    // MARK: - Authed transport

    private func sendAuthed(_ make: (String) -> URLRequest) async throws -> Data {
        let token = try requireToken()
        do {
            return try await send(make(token))
        } catch RemoteStoreError.http(401, _) {
            let refreshed = try await refreshAccessToken()
            return try await send(make(refreshed))
        }
    }

    private func refreshAccessToken() async throws -> String {
        guard let refresh = RemoteTokenStore.token(for: refreshAccount) else {
            throw RemoteStoreError.notAuthenticated
        }
        let data = try await send(Self.refreshRequest(refreshToken: refresh, clientID: clientID))
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw RemoteStoreError.decoding("token refresh")
        }
        RemoteTokenStore.setToken(access, for: tokenAccount)
        return access
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteStoreError.decoding("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RemoteStoreError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    // MARK: - Pure path helpers (unit-tested; same convention as the others)

    static func normalizedPath(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespaces)
        if p == "/" || p.isEmpty { return "" }
        if !p.hasPrefix("/") { p = "/" + p }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    static func parentPath(of path: String) -> String {
        let p = normalizedPath(path)
        guard let idx = p.lastIndex(of: "/") else { return "" }
        return String(p[p.startIndex..<idx])
    }

    /// The OAuth redirect derives from the client id:
    /// `123-abc.apps.googleusercontent.com` → scheme
    /// `com.googleusercontent.apps.123-abc`, redirect `<scheme>:/oauth2redirect`.
    static func redirectScheme(clientID: String) -> String {
        let prefix = clientID.hasSuffix(".apps.googleusercontent.com")
            ? String(clientID.dropLast(".apps.googleusercontent.com".count))
            : clientID
        return "com.googleusercontent.apps.\(prefix)"
    }

    static func redirectURI(clientID: String) -> String {
        "\(redirectScheme(clientID: clientID)):/oauth2redirect"
    }

    // MARK: - Pure request builders (unit-tested)

    /// A starting point for Drive's change feed.
    static func startPageTokenRequest(token: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/changes/startPageToken")!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    /// Everything that changed since `pageToken`.
    static func changesRequest(pageToken: String, token: String) -> URLRequest {
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/changes")!
        c.queryItems = [
            URLQueryItem(name: "pageToken", value: pageToken),
            URLQueryItem(name: "pageSize", value: "1000"),
            URLQueryItem(name: "fields",
                         value: "nextPageToken,newStartPageToken,changes(fileId,removed,file(id,name,mimeType,size,modifiedTime,version,parents,trashed))"),
        ]
        var r = URLRequest(url: c.url!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    static func parseStartPageToken(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["startPageToken"] as? String
    }

    /// One page of `changes.list`.
    ///
    /// Drive is id-based and a change carries no path, so entries come back
    /// keyed by **file id** in the `path` field; the store's own id caches map
    /// them back. A change is a removal when `removed` is set or the file has
    /// been trashed.
    static func parseChangesPage(_ data: Data)
        -> (changed: [(id: String, entry: RemoteEntry)], removed: [String],
            next: String?, newStart: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let changes = root["changes"] as? [[String: Any]] else { return ([], [], nil, nil) }
        let formatter = ISO8601DateFormatter()
        var changed: [(id: String, entry: RemoteEntry)] = []
        var removed: [String] = []

        for change in changes {
            guard let fileID = change["fileId"] as? String else { continue }
            let file = change["file"] as? [String: Any]
            if change["removed"] as? Bool == true || file?["trashed"] as? Bool == true || file == nil {
                removed.append(fileID)
                continue
            }
            guard let file, let name = file["name"] as? String else { continue }
            let mime = file["mimeType"] as? String ?? ""
            changed.append((fileID, RemoteEntry(
                path: fileID,                       // resolved to a path by the caller
                name: name,
                isDirectory: mime == folderMIME,
                size: Int(file["size"] as? String ?? "") ?? 0,
                modified: (file["modifiedTime"] as? String).flatMap { formatter.date(from: $0) },
                rev: (file["version"] as? String) ?? (file["version"] as? NSNumber)?.stringValue)))
        }
        return (changed, removed,
                root["nextPageToken"] as? String,
                root["newStartPageToken"] as? String)
    }

    /// Every folder in the Drive, with its parent — the input to building the
    /// vault's tree locally. `parents` is not in the ordinary listing's fields
    /// because a per-folder listing already knows the parent it asked about.
    static func allFoldersRequest(token: String, pageToken: String? = nil) -> URLRequest {
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        c.queryItems = [
            .init(name: "q", value: "mimeType='\(folderMIME)' and trashed=false"),
            .init(name: "fields", value: "nextPageToken,files(id,name,parents)"),
            .init(name: "pageSize", value: "1000"),
        ]
        if let pageToken { c.queryItems?.append(.init(name: "pageToken", value: pageToken)) }
        var r = URLRequest(url: c.url!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    /// Files whose parent is any of `parents`. Drive has no descendant query,
    /// but it does accept an `or` chain, which is what turns one request per
    /// folder into one per fifty.
    static func filesInParentsRequest(parents: [String], token: String,
                                      pageToken: String? = nil) -> URLRequest {
        let clause = parents.map { "'\($0)' in parents" }.joined(separator: " or ")
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        c.queryItems = [
            .init(name: "q", value: "(\(clause)) and trashed=false"),
            .init(name: "fields",
                  value: "nextPageToken,files(id,name,mimeType,size,modifiedTime,parents)"),
            .init(name: "pageSize", value: "1000"),
        ]
        if let pageToken { c.queryItems?.append(.init(name: "pageToken", value: pageToken)) }
        var r = URLRequest(url: c.url!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    static func parseFolderTreePage(_ data: Data) throws
        -> (folders: [(id: String, name: String, parent: String?)], nextPageToken: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = root["files"] as? [[String: Any]] else {
            throw RemoteStoreError.decoding("drive folder tree")
        }
        let folders = files.compactMap { f -> (String, String, String?)? in
            guard let id = f["id"] as? String, let name = f["name"] as? String else { return nil }
            return (id, name, (f["parents"] as? [String])?.first)
        }
        return (folders, root["nextPageToken"] as? String)
    }

    static func parseFilesInParentsPage(_ data: Data) throws
        -> (items: [(id: String, name: String, isFolder: Bool, size: Int,
                     modified: Date?, parent: String?)], nextPageToken: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = root["files"] as? [[String: Any]] else {
            throw RemoteStoreError.decoding("drive files in parents")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let items = files.compactMap { f -> (String, String, Bool, Int, Date?, String?)? in
            guard let id = f["id"] as? String,
                  let name = f["name"] as? String,
                  let mime = f["mimeType"] as? String else { return nil }
            let isFolder = mime == folderMIME
            // Same rule the ordinary listing applies: Google-native documents
            // have no bytes to download, so they are not notes.
            if !isFolder && mime.hasPrefix("application/vnd.google-apps") { return nil }
            let modified = (f["modifiedTime"] as? String).flatMap {
                formatter.date(from: $0) ?? plain.date(from: $0)
            }
            return (id, name, isFolder,
                    (f["size"] as? String).flatMap(Int.init) ?? 0,
                    modified, (f["parents"] as? [String])?.first)
        }
        return (items, root["nextPageToken"] as? String)
    }

    static func listRequest(folderID: String, token: String, pageToken: String? = nil) -> URLRequest {
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        c.queryItems = [
            .init(name: "q", value: "'\(folderID)' in parents and trashed=false"),
            // `nextPageToken` must be requested explicitly — it isn't returned
            // when `fields` names only `files(...)`.
            .init(name: "fields", value: "nextPageToken,files(id,name,mimeType,size,modifiedTime)"),
            .init(name: "pageSize", value: "1000"),
        ]
        if let pageToken { c.queryItems?.append(.init(name: "pageToken", value: pageToken)) }
        var r = URLRequest(url: c.url!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    static func downloadRequest(fileID: String, token: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)?alt=media")!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    static func deleteRequest(fileID: String, token: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)")!)
        r.httpMethod = "DELETE"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    /// Create a new file: multipart/related with a metadata JSON part (name +
    /// parent folder) and the media part.
    static func createRequest(name: String, parentID: String, data: Data,
                              token: String, boundary: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id")!)
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let metadata = "{\"name\":\(jsonString(name)),\"parents\":[\(jsonString(parentID))]}"
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        append("--\(boundary)\r\n")
        append("Content-Type: application/json; charset=UTF-8\r\n\r\n")
        append(metadata + "\r\n")
        append("--\(boundary)\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
        r.httpBody = body
        return r
    }

    /// Update an existing file's content in place (simple media upload).
    static func updateRequest(fileID: String, data: Data, token: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files/\(fileID)?uploadType=media")!)
        r.httpMethod = "PATCH"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        r.httpBody = data
        return r
    }

    static func makeBoundary() -> String { "hn-\(UUID().uuidString)" }

    private static func jsonString(_ s: String) -> String {
        (try? JSONSerialization.data(withJSONObject: [s]))
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { String($0.dropFirst().dropLast()) } ?? "\"\(s)\""
    }

    // MARK: - Pure response parsing (unit-tested)

    static func parseFileList(_ data: Data, parentPath: String) throws -> [(entry: RemoteEntry, id: String)] {
        try parseFileListPage(data, parentPath: parentPath).items
    }

    /// One page of results, plus Drive's continuation token (nil on the last).
    static func parseFileListPage(_ data: Data, parentPath: String) throws
        -> (items: [(entry: RemoteEntry, id: String)], nextPageToken: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = root["files"] as? [[String: Any]] else {
            throw RemoteStoreError.decoding("drive file list")
        }
        let nextPageToken = root["nextPageToken"] as? String
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let items: [(entry: RemoteEntry, id: String)] = files.compactMap { f in
            guard let id = f["id"] as? String,
                  let name = f["name"] as? String,
                  let mime = f["mimeType"] as? String else { return nil }
            // Native Google Docs/Sheets/… aren't byte-downloadable — skip
            // everything Google-native except folders.
            let isFolder = mime == folderMIME
            if !isFolder && mime.hasPrefix("application/vnd.google-apps") { return nil }
            let modified = (f["modifiedTime"] as? String).flatMap {
                formatter.date(from: $0) ?? plain.date(from: $0)
            }
            let entry = RemoteEntry(
                path: parentPath + "/" + name,
                name: name,
                isDirectory: isFolder,
                size: (f["size"] as? String).flatMap(Int.init) ?? 0,   // Drive returns size as a string
                modified: modified,
                rev: nil
            )
            return (entry, id)
        }
        return (items, nextPageToken)
    }

    static func parseFileID(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["id"] as? String
    }

    // MARK: - OAuth (PKCE, no secret; reversed-client-id redirect)

    static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func authorizeURL(clientID: String, challenge: String, state: String) -> URL {
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI(clientID: clientID)),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "https://www.googleapis.com/auth/drive"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        return c.url!
    }

    static func tokenExchangeRequest(code: String, verifier: String, clientID: String) -> URLRequest {
        formRequest([
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code", value: code),
            .init(name: "client_id", value: clientID),
            .init(name: "code_verifier", value: verifier),
            .init(name: "redirect_uri", value: redirectURI(clientID: clientID)),
        ])
    }

    static func refreshRequest(refreshToken: String, clientID: String) -> URLRequest {
        formRequest([
            .init(name: "grant_type", value: "refresh_token"),
            .init(name: "refresh_token", value: refreshToken),
            .init(name: "client_id", value: clientID),
        ])
    }

    private static func formRequest(_ items: [URLQueryItem]) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = items
        r.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        return r
    }

    @MainActor
    func authenticate() async throws {
        let id = clientID
        guard !id.isEmpty else {
            throw RemoteStoreError.notConfigured(
                "Add GOOGLE_CLIENT_ID to Config/Secrets.xcconfig (an iOS-type OAuth client from the Google Cloud Console).")
        }
        #if canImport(AuthenticationServices)
        let verifier = Self.makeCodeVerifier()
        let state = UUID().uuidString
        let url = Self.authorizeURL(clientID: id, challenge: Self.codeChallenge(for: verifier), state: state)
        let callback = try await presentWebAuth(url: url, scheme: Self.redirectScheme(clientID: id))
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems
        guard items?.first(where: { $0.name == "state" })?.value == state,
              let code = items?.first(where: { $0.name == "code" })?.value else {
            throw RemoteStoreError.cancelled
        }
        let data = try await send(Self.tokenExchangeRequest(code: code, verifier: verifier, clientID: id))
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw RemoteStoreError.decoding("token exchange")
        }
        RemoteTokenStore.setToken(access, for: tokenAccount)
        if let refresh = json["refresh_token"] as? String {
            RemoteTokenStore.setToken(refresh, for: refreshAccount)
        }
        #else
        throw RemoteStoreError.notConfigured("Web authentication isn't available on this platform.")
        #endif
    }

    #if canImport(AuthenticationServices)
    @MainActor
    private func presentWebAuth(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    continuation.resume(throwing: RemoteStoreError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? RemoteStoreError.cancelled)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }
    #endif
}

#if canImport(AuthenticationServices)
extension GoogleDriveStore: ASWebAuthenticationPresentationContextProviding {
    // Shared with the other three providers: on iOS a bare `ASPresentationAnchor()`
    // is a scene-less `UIWindow`, which makes `start()` fail with
    // `presentationContextInvalid` and the login sheet never appear.
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        WebAuthAnchor.presentationAnchor()
    }
}
#endif
