//
//  DropboxStore.swift
//  HelloNotes
//
//  Created by Chris Tham on 21/7/2026.
//
//  A `RemoteStore` over the Dropbox API v2 using plain URLSession — no
//  SwiftyDropbox dependency, so nothing is added to the project graph. This is
//  the Phase-4 pilot the roadmap describes: reach a Dropbox account directly,
//  without Dropbox's desktop/mobile client installed.
//
//  What still needs the user before this can run live:
//   1. Register a Dropbox app (dropbox.com/developers) and paste its **App key**
//      into Info.plist under `DropboxAppKey`, and add the OAuth redirect
//      `hellonotes://dropbox-auth` to the app's Redirect URIs.
//   2. Wire a RemoteStore into the `Collection` model (a separate refactor).
//  The request-building and response-parsing here are pure and unit-tested; the
//  network calls and OAuth are exercised only once a real app key exists.
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

final class DropboxStore: NSObject, RemoteStore {
    let providerName = "Dropbox"
    private static let tokenAccount = "dropbox"
    private static let refreshAccount = "dropbox-refresh"

    /// The Dropbox app key, from Info.plist. Empty until the user configures one.
    private var appKey: String {
        (Bundle.main.object(forInfoDictionaryKey: "DropboxAppKey") as? String) ?? ""
    }
    private let redirectURI = "hellonotes://dropbox-auth"
    private let session: URLSession

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

    // MARK: - CRUD

    func list(path: String) async throws -> [RemoteEntry] {
        let data = try await sendAuthed { Self.listFolderRequest(path: path, token: $0) }
        return try Self.parseListFolder(data)
    }

    func read(path: String) async throws -> Data {
        try await sendAuthed { Self.downloadRequest(path: path, token: $0) }
    }

    func write(_ data: Data, to path: String) async throws {
        _ = try await sendAuthed { Self.uploadRequest(path: path, token: $0, data: data) }
    }

    func delete(path: String) async throws {
        _ = try await sendAuthed { Self.deleteRequest(path: path, token: $0) }
    }

    /// Send an authenticated request; on a 401 (expired access token) refresh
    /// once with the stored refresh token and retry, so sessions survive the
    /// ~4-hour access-token lifetime without re-prompting the user.
    private func sendAuthed(_ make: (String) -> URLRequest) async throws -> Data {
        let token = try requireToken()
        do {
            return try await send(make(token))
        } catch RemoteStoreError.http(401, _) {
            let refreshed = try await refreshAccessToken()
            return try await send(make(refreshed))
        }
    }

    /// Exchange the stored refresh token for a fresh access token.
    private func refreshAccessToken() async throws -> String {
        guard let refresh = RemoteTokenStore.token(for: Self.refreshAccount) else {
            throw RemoteStoreError.notAuthenticated
        }
        let data = try await send(Self.refreshTokenRequest(refreshToken: refresh, appKey: appKey))
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw RemoteStoreError.decoding("token refresh")
        }
        RemoteTokenStore.setToken(access, for: Self.tokenAccount)
        return access
    }

    /// Run a request, mapping non-2xx to `RemoteStoreError.http`.
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

    // MARK: - Pure request builders (unit-tested)

    /// Dropbox wants `""` for the root and a leading-slash absolute path
    /// otherwise; it never wants a trailing slash.
    static func normalizedPath(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespaces)
        if p == "/" || p.isEmpty { return "" }
        if !p.hasPrefix("/") { p = "/" + p }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private static func jsonRequest(_ url: URL, token: String, body: [String: Any]) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return r
    }

    static func listFolderRequest(path: String, token: String) -> URLRequest {
        jsonRequest(URL(string: "https://api.dropboxapi.com/2/files/list_folder")!,
                    token: token,
                    body: ["path": normalizedPath(path), "recursive": false])
    }

    static func deleteRequest(path: String, token: String) -> URLRequest {
        jsonRequest(URL(string: "https://api.dropboxapi.com/2/files/delete_v2")!,
                    token: token,
                    body: ["path": normalizedPath(path)])
    }

    /// Content endpoints pass their arguments in the `Dropbox-API-Arg` header as
    /// JSON (the body carries file bytes, not JSON).
    static func downloadRequest(path: String, token: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/download")!)
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue(apiArg(["path": normalizedPath(path)]), forHTTPHeaderField: "Dropbox-API-Arg")
        return r
    }

    static func uploadRequest(path: String, token: String, data: Data) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/upload")!)
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue(apiArg(["path": normalizedPath(path), "mode": "overwrite", "mute": true]),
                   forHTTPHeaderField: "Dropbox-API-Arg")
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        r.httpBody = data
        return r
    }

    /// Serialize a `Dropbox-API-Arg` header value. Dropbox requires it to be
    /// HTTP-header-safe ASCII, so non-ASCII (e.g. Unicode file names) is
    /// backslash-escaped as `\uXXXX`.
    static func apiArg(_ body: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        var out = ""
        for scalar in json.unicodeScalars {
            if scalar.value > 0x7F {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    // MARK: - Pure response parsing (unit-tested)

    static func parseListFolder(_ data: Data) throws -> [RemoteEntry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["entries"] as? [[String: Any]] else {
            throw RemoteStoreError.decoding("list_folder entries")
        }
        let formatter = ISO8601DateFormatter()
        return entries.compactMap { e in
            guard let tag = e[".tag"] as? String,
                  let name = e["name"] as? String,
                  let path = (e["path_display"] as? String) ?? (e["path_lower"] as? String)
            else { return nil }
            return RemoteEntry(
                path: path,
                name: name,
                isDirectory: tag == "folder",
                size: e["size"] as? Int ?? 0,
                modified: (e["server_modified"] as? String).flatMap { formatter.date(from: $0) },
                rev: e["rev"] as? String
            )
        }
    }

    // MARK: - OAuth (PKCE)

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

    static func authorizeURL(appKey: String, redirectURI: String, challenge: String) -> URL {
        var c = URLComponents(string: "https://www.dropbox.com/oauth2/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: appKey),
            .init(name: "response_type", value: "code"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "token_access_type", value: "offline"),
            .init(name: "redirect_uri", value: redirectURI),
        ]
        return c.url!
    }

    static func tokenExchangeRequest(code: String, verifier: String, appKey: String, redirectURI: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://api.dropboxapi.com/oauth2/token")!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [
            .init(name: "code", value: code),
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code_verifier", value: verifier),
            .init(name: "client_id", value: appKey),
            .init(name: "redirect_uri", value: redirectURI),
        ]
        r.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        return r
    }

    static func refreshTokenRequest(refreshToken: String, appKey: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://api.dropboxapi.com/oauth2/token")!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [
            .init(name: "grant_type", value: "refresh_token"),
            .init(name: "refresh_token", value: refreshToken),
            .init(name: "client_id", value: appKey),
        ]
        r.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        return r
    }

    @MainActor
    func authenticate() async throws {
        let key = appKey
        guard !key.isEmpty else {
            throw RemoteStoreError.notConfigured(
                "Add your Dropbox app key to Info.plist (DropboxAppKey) and register \(redirectURI) as a redirect URI.")
        }
        #if canImport(AuthenticationServices)
        let verifier = Self.makeCodeVerifier()
        let url = Self.authorizeURL(appKey: key, redirectURI: redirectURI,
                                    challenge: Self.codeChallenge(for: verifier))
        let callback = try await presentWebAuth(url: url, scheme: "hellonotes")
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw RemoteStoreError.cancelled
        }
        let data = try await send(Self.tokenExchangeRequest(
            code: code, verifier: verifier, appKey: key, redirectURI: redirectURI))
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw RemoteStoreError.decoding("token exchange")
        }
        RemoteTokenStore.setToken(access, for: Self.tokenAccount)
        // `token_access_type=offline` returns a refresh token too — persist it so
        // the session survives the access token's ~4h expiry.
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
extension DropboxStore: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        return NSApplication.shared.keyWindow ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}
#endif
