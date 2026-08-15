//
//  OneDriveStore.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/7/2026.
//
//  A `RemoteStore` over Microsoft Graph (OneDrive) using plain URLSession — no
//  MSAL/Graph SDK. Fourth provider on the shared RemoteBrowser / RemoteMirror /
//  sidebar-collection machinery.
//
//  OneDrive is the easy one after Box/Drive: Graph is **path-addressable**
//  (`/me/drive/root:/path/to/item:`), so — like Dropbox — there is no ID
//  resolution. A single app registration on the `common` authority serves
//  **both personal and work/school (Business) accounts**; `/me/drive` resolves
//  to whichever account signed in.
//
//  OAuth: Microsoft identity platform v2.0, PKCE public client (no secret),
//  custom-scheme redirect `hellonotes://onedrive-auth`, `offline_access` for a
//  refresh token. Config: `ONEDRIVE_CLIENT_ID` in Config/Secrets.xcconfig →
//  Info.plist (`OneDriveClientID`).
//

import Foundation
import CryptoKit
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

final class OneDriveStore: NSObject, RemoteStore, @unchecked Sendable {
    let providerName = "OneDrive"
    private static let tokenAccount = "onedrive"
    private static let refreshAccount = "onedrive-refresh"
    /// `common` = both personal and work/school accounts.
    private static let authority = "common"
    private static let scope = "Files.ReadWrite offline_access User.Read"

    private var clientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "OneDriveClientID") as? String) ?? ""
    }
    private let redirectURI = "hellonotes://onedrive-auth"
    private let session: URLSession
    /// Single-flights token refreshes (Microsoft rotates refresh tokens).
    private let refreshCoordinator = RefreshCoordinator()

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
    }

    // MARK: - CRUD (path-based; no ID resolution needed)

    /// Lists a folder in full, following Graph's `@odata.nextLink` (a
    /// fully-qualified URL for the next page). Without the loop a folder past
    /// one page silently loses its tail.
    func list(path: String) async throws -> [RemoteEntry] {
        let parentPath = Self.normalizedPath(path)
        var data = try await sendAuthed { Self.listRequest(path: path, token: $0) }
        var page = try Self.parseChildrenPage(data, parentPath: parentPath)
        var all = page.entries
        while let next = page.nextLink {
            data = try await sendAuthed { Self.pageRequest(url: next, token: $0) }
            page = try Self.parseChildrenPage(data, parentPath: parentPath)
            all += page.entries
        }
        return all
    }

    func read(path: String) async throws -> Data {
        try await sendAuthed { Self.downloadRequest(path: path, token: $0) }
    }

    func write(_ data: Data, to path: String) async throws {
        _ = try await sendAuthed { Self.uploadRequest(path: path, data: data, token: $0) }
    }

    func delete(path: String) async throws {
        _ = try await sendAuthed { Self.deleteRequest(path: path, token: $0) }
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

    /// Single-flighted: Microsoft rotates refresh tokens, so concurrent 401s
    /// must not each spend the stored one (the loser would get `invalid_grant`).
    private func refreshAccessToken() async throws -> String {
        let id = clientID
        let session = self.session
        return try await refreshCoordinator.refresh {
            guard let refresh = RemoteTokenStore.token(for: Self.refreshAccount) else {
                throw RemoteStoreError.notAuthenticated
            }
            let request = Self.refreshRequest(refreshToken: refresh, clientID: id)
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
            // Microsoft rotates refresh tokens — persist the new one when present.
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

    // MARK: - Pure path/URL helpers (unit-tested)

    static func normalizedPath(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespaces)
        if p == "/" || p.isEmpty { return "" }
        if !p.hasPrefix("/") { p = "/" + p }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Graph addresses an item by path via the `root:/{path}:` syntax; the root
    /// itself is just `/me/drive/root`. Each path component is percent-encoded
    /// (so spaces / unicode in note names are safe) while the separators stay
    /// literal.
    static func itemURL(path: String, suffix: String) -> URL {
        let base = "https://graph.microsoft.com/v1.0/me/drive"
        let p = normalizedPath(path)
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: ":/"))
        if p.isEmpty {
            return URL(string: base + "/root" + suffix)!
        }
        let encoded = p.split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
        return URL(string: base + "/root:/" + encoded + ":" + suffix)!
    }

    // MARK: - Pure request builders (unit-tested)

    static func listRequest(path: String, token: String) -> URLRequest {
        let url = itemURL(path: path, suffix: "/children")
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "$select", value: "name,size,folder,file,lastModifiedDateTime"),
                        .init(name: "$top", value: "1000")]
        var r = URLRequest(url: c.url!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    /// Fetch a Graph continuation URL (`@odata.nextLink`) verbatim.
    static func pageRequest(url: URL, token: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    static func downloadRequest(path: String, token: String) -> URLRequest {
        var r = URLRequest(url: itemURL(path: path, suffix: "/content"))
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    /// Simple upload (create or overwrite). Fine for notes; Graph's simple PUT
    /// handles files up to 4 MB, which Markdown never approaches.
    static func uploadRequest(path: String, data: Data, token: String) -> URLRequest {
        var r = URLRequest(url: itemURL(path: path, suffix: "/content"))
        r.httpMethod = "PUT"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        r.httpBody = data
        return r
    }

    static func deleteRequest(path: String, token: String) -> URLRequest {
        var r = URLRequest(url: itemURL(path: path, suffix: ""))
        r.httpMethod = "DELETE"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    // MARK: - Pure response parsing (unit-tested)

    /// A Graph driveItem is a folder if it has a `folder` facet, a file if it has
    /// a `file` facet.
    static func parseChildren(_ data: Data, parentPath: String) throws -> [RemoteEntry] {
        try parseChildrenPage(data, parentPath: parentPath).entries
    }

    /// One page of children, plus Graph's continuation link (nil on the last).
    static func parseChildrenPage(_ data: Data, parentPath: String) throws
        -> (entries: [RemoteEntry], nextLink: URL?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = root["value"] as? [[String: Any]] else {
            throw RemoteStoreError.decoding("drive children")
        }
        let nextLink = (root["@odata.nextLink"] as? String).flatMap(URL.init(string:))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let entries: [RemoteEntry] = value.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            let isFolder = item["folder"] != nil
            let modified = (item["lastModifiedDateTime"] as? String).flatMap {
                formatter.date(from: $0) ?? plain.date(from: $0)
            }
            return RemoteEntry(
                path: parentPath + "/" + name,
                name: name,
                isDirectory: isFolder,
                size: item["size"] as? Int ?? 0,
                modified: modified,
                rev: (item["eTag"] as? String)
            )
        }
        return (entries, nextLink)
    }

    // MARK: - OAuth (PKCE, no secret; common authority = personal + business)

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

    static func authorizeURL(clientID: String, redirectURI: String, challenge: String, state: String) -> URL {
        var c = URLComponents(string: "https://login.microsoftonline.com/\(authority)/oauth2/v2.0/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        return c.url!
    }

    static func tokenExchangeRequest(code: String, verifier: String, clientID: String, redirectURI: String) -> URLRequest {
        formRequest([
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code", value: code),
            .init(name: "client_id", value: clientID),
            .init(name: "code_verifier", value: verifier),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scope),
        ])
    }

    static func refreshRequest(refreshToken: String, clientID: String) -> URLRequest {
        formRequest([
            .init(name: "grant_type", value: "refresh_token"),
            .init(name: "refresh_token", value: refreshToken),
            .init(name: "client_id", value: clientID),
            .init(name: "scope", value: scope),
        ])
    }

    private static func formRequest(_ items: [URLQueryItem]) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://login.microsoftonline.com/\(authority)/oauth2/v2.0/token")!)
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
                "Add ONEDRIVE_CLIENT_ID to Config/Secrets.xcconfig (an Entra app registration; redirect \(redirectURI), public client flows enabled).")
        }
        #if canImport(AuthenticationServices)
        let verifier = Self.makeCodeVerifier()
        let state = UUID().uuidString
        let url = Self.authorizeURL(clientID: id, redirectURI: redirectURI,
                                    challenge: Self.codeChallenge(for: verifier), state: state)
        let callback = try await presentWebAuth(url: url, scheme: "hellonotes")
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems
        guard items?.first(where: { $0.name == "state" })?.value == state,
              let code = items?.first(where: { $0.name == "code" })?.value else {
            throw RemoteStoreError.cancelled
        }
        let data = try await send(Self.tokenExchangeRequest(
            code: code, verifier: verifier, clientID: id, redirectURI: redirectURI))
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
extension OneDriveStore: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        return NSApplication.shared.keyWindow ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}
#endif
