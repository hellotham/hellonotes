//
//  BoxStore.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/7/2026.
//
//  A `RemoteStore` over the Box API 2.0 using plain URLSession — no Box SDK.
//  Slots into the same RemoteBrowser / RemoteMirror / sidebar-collection
//  machinery as Dropbox.
//
//  Two Box-specific wrinkles this file absorbs:
//  1. **OAuth needs the client secret.** Box's authorization-code grant has no
//     PKCE public-client mode; the token exchange requires `client_secret`
//     (from Info.plist `BoxClientSecret`, alongside `BoxClientID`). Its refresh
//     tokens are single-use — every refresh returns a NEW refresh token that
//     must replace the stored one.
//  2. **Box addresses items by numeric ID, not path.** The path-based
//     `RemoteStore` calls are bridged through a path→ID resolver: folder
//     listings prime `folderIDs`/`fileIDs` caches, and unresolved paths are
//     walked down from the root ("0"), one listing per level. `RemoteMirror`
//     lists parents before reading children, so in practice resolution is
//     almost always a cache hit.
//

import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

final class BoxStore: NSObject, RemoteStore, @unchecked Sendable {
    let providerName = "Box"
    private static let tokenAccount = "box"
    private static let refreshAccount = "box-refresh"

    private var clientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "BoxClientID") as? String) ?? ""
    }
    private var clientSecret: String {
        (Bundle.main.object(forInfoDictionaryKey: "BoxClientSecret") as? String) ?? ""
    }
    private let redirectURI = "hellonotes://box-auth"
    private let session: URLSession
    /// Single-flights token refreshes (Box rotates refresh tokens).
    private let refreshCoordinator = RefreshCoordinator()

    /// Path→ID caches (normalized path keys). Root is always folder id "0".
    private let cacheLock = NSLock()
    private var folderIDs: [String: String] = ["": "0"]
    private var fileIDs: [String: String] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    var isAuthenticated: Bool { RemoteTokenStore.token(for: Self.tokenAccount) != nil }

    private func requireToken() throws -> String {
        guard let token = RemoteTokenStore.token(for: Self.tokenAccount) else {
            throw RemoteStoreError.notAuthenticated
        }
        return token
    }

    func signOut() {
        RemoteTokenStore.setToken(nil, for: Self.tokenAccount)
        RemoteTokenStore.setToken(nil, for: Self.refreshAccount)
        cacheLock.lock()
        folderIDs = ["": "0"]
        fileIDs = [:]
        cacheLock.unlock()
    }

    // MARK: - CRUD (path-based over Box's ID-based API)

    /// Lists a folder in full. Box pages `folders/{id}/items`, so walk `offset`
    /// until a short page arrives — otherwise a big folder silently loses its
    /// tail (and, since IDs are primed here, those notes become unreadable).
    func list(path: String) async throws -> [RemoteEntry] {
        let folderID = try await resolveFolderID(path: path)
        let parentPath = Self.normalizedPath(path)
        var all: [RemoteEntry] = []
        var offset = 0
        while true {
            let data = try await sendAuthed {
                Self.listItemsRequest(folderID: folderID, token: $0, offset: offset)
            }
            let page = try Self.parseItemsPage(data, parentPath: parentPath)
            cacheLock.lock()
            for item in page.items {
                if item.entry.isDirectory { folderIDs[item.entry.path] = item.id }
                else { fileIDs[item.entry.path] = item.id }
            }
            cacheLock.unlock()
            all += page.items.map(\.entry)
            // Compare against the RAW entry count (`items` drops web_links, so a
            // full page can yield fewer usable items). A short page ends the walk.
            guard page.rawCount >= Self.pageSize else { break }
            offset += Self.pageSize
        }
        return all
    }

    func read(path: String) async throws -> Data {
        let id = try await resolveFileID(path: path)
        return try await sendAuthed { Self.downloadRequest(fileID: id, token: $0) }
    }

    func write(_ data: Data, to path: String) async throws {
        let p = Self.normalizedPath(path)
        let name = String(p.split(separator: "/").last ?? "untitled.md")
        if let id = try? await resolveFileID(path: p) {
            // Existing file → new version.
            _ = try await sendAuthed {
                Self.uploadUpdateRequest(fileID: id, filename: name, data: data,
                                         token: $0, boundary: Self.makeBoundary())
            }
        } else {
            // New file → create in its parent folder.
            let parentID = try await resolveFolderID(path: Self.parentPath(of: p))
            let response = try await sendAuthed {
                Self.uploadNewRequest(name: name, parentID: parentID, data: data,
                                      token: $0, boundary: Self.makeBoundary())
            }
            if let id = Self.parseUploadedFileID(response) {
                cacheLock.lock(); fileIDs[p] = id; cacheLock.unlock()
            }
        }
    }

    func delete(path: String) async throws {
        let p = Self.normalizedPath(path)
        if let id = try? await resolveFileID(path: p) {
            _ = try await sendAuthed { Self.deleteFileRequest(fileID: id, token: $0) }
            cacheLock.lock(); fileIDs[p] = nil; cacheLock.unlock()
        } else {
            let id = try await resolveFolderID(path: p)
            _ = try await sendAuthed { Self.deleteFolderRequest(folderID: id, token: $0) }
            cacheLock.lock(); folderIDs[p] = nil; cacheLock.unlock()
        }
    }

    // MARK: - Path → ID resolution

    private func cachedFolderID(_ path: String) -> String? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return folderIDs[path]
    }

    private func cachedFileID(_ path: String) -> String? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return fileIDs[path]
    }

    /// Walk from the deepest cached ancestor down to `path`, listing each level
    /// (which primes the caches). Terminates because "" (root, id "0") is always
    /// cached, and each `list` call resolves a strictly shorter, already-cached
    /// prefix.
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
                throw RemoteStoreError.http(404, "No folder named “\(component)” in “\(currentPath.isEmpty ? "root" : currentPath)”")
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
        _ = try await list(path: Self.parentPath(of: p))   // primes file ids
        guard let id = cachedFileID(p) else {
            throw RemoteStoreError.http(404, "No file at “\(p)”")
        }
        return id
    }

    // MARK: - Authed transport (with single-use refresh-token rotation)

    private func sendAuthed(_ make: (String) -> URLRequest) async throws -> Data {
        let token = try requireToken()
        do {
            return try await send(make(token))
        } catch RemoteStoreError.http(401, _) {
            let refreshed = try await refreshAccessToken()
            return try await send(make(refreshed))
        }
    }

    /// Box refresh tokens are **single-use**: the refresh response carries a new
    /// refresh token that must replace the stored one, or the next refresh fails.
    /// Routed through `refreshCoordinator` so concurrent 401s (two uploads, say)
    /// don't each spend the same token — the loser would get `invalid_grant`.
    private func refreshAccessToken() async throws -> String {
        let id = clientID, secret = clientSecret
        let session = self.session
        return try await refreshCoordinator.refresh {
            guard let refresh = RemoteTokenStore.token(for: Self.refreshAccount) else {
                throw RemoteStoreError.notAuthenticated
            }
            let request = Self.refreshRequest(refreshToken: refresh, clientID: id, clientSecret: secret)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw RemoteStoreError.decoding("no HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw RemoteStoreError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = json["access_token"] as? String else {
                throw RemoteStoreError.decoding("token refresh")
            }
            RemoteTokenStore.setToken(access, for: Self.tokenAccount)
            if let rotated = json["refresh_token"] as? String {
                RemoteTokenStore.setToken(rotated, for: Self.refreshAccount)
            }
            return access
        }
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

    // MARK: - Pure path helpers (unit-tested)

    /// Same convention as Dropbox: "" is the root, otherwise a leading-slash
    /// absolute path with no trailing slash. (Purely our own convention — Box
    /// itself addresses by ID.)
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
        return String(p[p.startIndex..<idx])   // "" for a top-level item
    }

    // MARK: - Pure request builders (unit-tested)

    /// Entries requested per page; the pager walks `offset` in these steps.
    static let pageSize = 1000

    static func listItemsRequest(folderID: String, token: String, offset: Int = 0) -> URLRequest {
        var c = URLComponents(string: "https://api.box.com/2.0/folders/\(folderID)/items")!
        c.queryItems = [
            .init(name: "fields", value: "id,type,name,size,modified_at"),
            .init(name: "limit", value: "\(pageSize)"),
            .init(name: "offset", value: "\(offset)"),
        ]
        var r = URLRequest(url: c.url!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    static func downloadRequest(fileID: String, token: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://api.box.com/2.0/files/\(fileID)/content")!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    static func deleteFileRequest(fileID: String, token: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://api.box.com/2.0/files/\(fileID)")!)
        r.httpMethod = "DELETE"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    static func deleteFolderRequest(folderID: String, token: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://api.box.com/2.0/folders/\(folderID)?recursive=true")!)
        r.httpMethod = "DELETE"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    /// Create a new file: multipart upload to the dedicated upload host, with an
    /// `attributes` JSON part naming the file and its parent folder.
    static func uploadNewRequest(name: String, parentID: String, data: Data,
                                 token: String, boundary: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://upload.box.com/api/2.0/files/content")!)
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let attributes = "{\"name\":\(jsonString(name)),\"parent\":{\"id\":\(jsonString(parentID))}}"
        r.httpBody = multipartBody(boundary: boundary, attributes: attributes, filename: name, fileData: data)
        return r
    }

    /// Upload a new version of an existing file.
    static func uploadUpdateRequest(fileID: String, filename: String, data: Data,
                                    token: String, boundary: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://upload.box.com/api/2.0/files/\(fileID)/content")!)
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.httpBody = multipartBody(boundary: boundary, attributes: nil, filename: filename, fileData: data)
        return r
    }

    static func multipartBody(boundary: String, attributes: String?, filename: String, fileData: Data) -> Data {
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        if let attributes {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"attributes\"\r\n\r\n")
            append(attributes + "\r\n")
        }
        append("--\(boundary)\r\n")
        // RFC 7578 §4.2: escape `\` and `"` in the filename parameter. Both are
        // legal in an APFS filename, and an unescaped quote truncates the header
        // value, which Box rejects with a 400.
        let escapedName = filename
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(escapedName)\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    static func makeBoundary() -> String { "hn-\(UUID().uuidString)" }

    private static func jsonString(_ s: String) -> String {
        (try? JSONSerialization.data(withJSONObject: [s]))
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { String($0.dropFirst().dropLast()) } ?? "\"\(s)\""
    }

    // MARK: - Pure response parsing (unit-tested)

    /// Parse a folder-items listing into entries + their Box IDs. Skips item
    /// types that aren't files or folders (e.g. `web_link`).
    static func parseItems(_ data: Data, parentPath: String) throws -> [(entry: RemoteEntry, id: String)] {
        try parseItemsPage(data, parentPath: parentPath).items
    }

    /// One page of items, plus the *raw* entry count (before `web_link` and
    /// other non-file/folder types are dropped) so the pager can tell a full
    /// page from the last one.
    static func parseItemsPage(_ data: Data, parentPath: String) throws
        -> (items: [(entry: RemoteEntry, id: String)], rawCount: Int) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["entries"] as? [[String: Any]] else {
            throw RemoteStoreError.decoding("folder items")
        }
        let formatter = ISO8601DateFormatter()
        let items: [(entry: RemoteEntry, id: String)] = entries.compactMap { e in
            guard let type = e["type"] as? String, type == "file" || type == "folder",
                  let id = e["id"] as? String,
                  let name = e["name"] as? String else { return nil }
            let entry = RemoteEntry(
                path: parentPath + "/" + name,
                name: name,
                isDirectory: type == "folder",
                size: e["size"] as? Int ?? 0,
                modified: (e["modified_at"] as? String).flatMap { formatter.date(from: $0) },
                rev: nil
            )
            return (entry, id)
        }
        return (items, entries.count)
    }

    /// The upload endpoints answer with `{"entries":[{"type":"file","id":…}]}`.
    static func parseUploadedFileID(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["entries"] as? [[String: Any]] else { return nil }
        return entries.first?["id"] as? String
    }

    // MARK: - OAuth (authorization code + client secret; rotating refresh)

    static func authorizeURL(clientID: String, redirectURI: String, state: String) -> URL {
        var c = URLComponents(string: "https://account.box.com/api/oauth2/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "state", value: state),
        ]
        return c.url!
    }

    static func tokenExchangeRequest(code: String, clientID: String, clientSecret: String) -> URLRequest {
        formRequest([
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code", value: code),
            .init(name: "client_id", value: clientID),
            .init(name: "client_secret", value: clientSecret),
        ])
    }

    static func refreshRequest(refreshToken: String, clientID: String, clientSecret: String) -> URLRequest {
        formRequest([
            .init(name: "grant_type", value: "refresh_token"),
            .init(name: "refresh_token", value: refreshToken),
            .init(name: "client_id", value: clientID),
            .init(name: "client_secret", value: clientSecret),
        ])
    }

    private static func formRequest(_ items: [URLQueryItem]) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://api.box.com/oauth2/token")!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = items
        r.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        return r
    }

    @MainActor
    func authenticate() async throws {
        let id = clientID, secret = clientSecret
        guard !id.isEmpty, !secret.isEmpty else {
            throw RemoteStoreError.notConfigured(
                "Add BoxClientID and BoxClientSecret to Info.plist, and register \(redirectURI) as a redirect URI in the Box Developer Console.")
        }
        #if canImport(AuthenticationServices)
        let state = UUID().uuidString
        let url = Self.authorizeURL(clientID: id, redirectURI: redirectURI, state: state)
        let callback = try await presentWebAuth(url: url, scheme: "hellonotes")
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems
        guard items?.first(where: { $0.name == "state" })?.value == state,
              let code = items?.first(where: { $0.name == "code" })?.value else {
            throw RemoteStoreError.cancelled
        }
        // Box authorization codes expire after 30 seconds — exchange immediately.
        let data = try await send(Self.tokenExchangeRequest(code: code, clientID: id, clientSecret: secret))
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw RemoteStoreError.decoding("token exchange")
        }
        RemoteTokenStore.setToken(access, for: Self.tokenAccount)
        if let refresh = json["refresh_token"] as? String {
            RemoteTokenStore.setToken(refresh, for: Self.refreshAccount)
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
extension BoxStore: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        return NSApplication.shared.keyWindow ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}
#endif
