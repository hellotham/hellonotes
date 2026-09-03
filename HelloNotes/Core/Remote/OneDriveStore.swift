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

final class OneDriveStore: NSObject, RemoteStore, @unchecked Sendable {
    let providerName = "OneDrive"
    /// The Keychain keys for *this* account's tokens.
    ///
    /// Scoped by account id, because a person may hold more than one account
    /// on the same service — a personal and a work OneDrive is the ordinary
    /// case. Keyed by the provider alone, the second sign-in overwrote the
    /// first one's token and the app could hold exactly one account per
    /// provider with no way to name or choose between them.
    let accountID: String
    private var tokenAccount: String { "onedrive#\(accountID)" }
    private var refreshAccount: String { tokenAccount + "-refresh" }
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

    /// Every item under `path`, from Graph's `/delta` walked from the start.
    ///
    /// A delta with no token *is* a recursive listing: Graph replays the whole
    /// subtree in pages and then hands back a token for next time. That is the
    /// same call `changes(since: nil,)` makes, asked here for the items alone —
    /// so a vault of three hundred folders costs a few pages rather than three
    /// hundred `children` requests six at a time.
    func listRecursively(path: String) async throws -> [RemoteEntry]? {
        var entries: [RemoteEntry] = []
        var next: URL? = Self.deltaRequest(path: path, token: "").url
        while let url = next {
            let data: Data
            do {
                data = try await sendAuthed { Self.pageRequest(url: url, token: $0) }
            } catch RemoteStoreError.http(let code, _) where code == 410 {
                // The subtree changed under us mid-replay. Nothing partial is
                // worth returning: fall back to walking, which is correct.
                return nil
            }
            let page = Self.parseDeltaPage(data)
            entries += page.changed
            next = page.next.flatMap(URL.init(string:))
        }
        return entries
    }

    func changes(since cursor: String?, path: String) async throws -> RemoteChangeSet? {
        var result = RemoteChangeSet()
        // The cursor *is* the next URL: Graph hands back a complete deltaLink
        // rather than an opaque token to reassemble.
        var next: URL? = cursor.flatMap(URL.init(string:))
            ?? Self.deltaRequest(path: path, token: "").url

        while let url = next {
            let data: Data
            do {
                data = try await sendAuthed { Self.pageRequest(url: url, token: $0) }
            } catch RemoteStoreError.http(let code, _) where code == 410 {
                // resyncRequired — the delta token aged out.
                return RemoteChangeSet(requiresFullResync: true)
            }
            let page = Self.parseDeltaPage(data)
            result.changed += page.changed
            result.deleted += page.deleted
            if let delta = page.delta { result.cursor = delta }
            next = page.next.flatMap(URL.init(string:))
        }
        return result
    }

    func latestCursor(path: String) async throws -> String? {
        let data = try await sendAuthed { Self.latestDeltaRequest(path: path, token: $0) }
        return Self.parseDeltaPage(data).delta
    }

    /// `?token=latest` asks Graph for a deltaLink describing "now", with an
    /// empty value array — the whole point being that it transfers nothing.
    static func latestDeltaRequest(path: String, token: String) -> URLRequest {
        var components = URLComponents(url: itemURL(path: path, suffix: "/delta"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "token", value: "latest")]
        return pageRequest(url: components.url!, token: token)
    }

    func read(path: String) async throws -> Data {
        try await sendAuthed { Self.downloadRequest(path: path, token: $0) }
    }

    /// Graph's simple `PUT` is capped at 4 MB. Anything larger goes through an
    /// **upload session**: create one, then send the bytes as byte-range slices.
    ///
    /// Markdown never reaches this. Attachments do — an image pasted into a note
    /// or a PDF dropped into the folder — and before this they failed at the cap
    /// with a provider error rather than uploading.
    static let simpleUploadLimit = 4 * 1024 * 1024
    /// Graph requires every chunk but the last to be a multiple of 320 KiB.
    static let uploadChunkSize = 320 * 1024 * 10      // 3.2 MB

    func write(_ data: Data, to path: String) async throws {
        guard data.count > Self.simpleUploadLimit else {
            _ = try await sendAuthed { Self.uploadRequest(path: path, data: data, token: $0) }
            return
        }

        let sessionData = try await sendAuthed { Self.createUploadSessionRequest(path: path, token: $0) }
        guard let uploadURL = Self.parseUploadSessionURL(sessionData) else {
            throw RemoteStoreError.decoding("createUploadSession uploadUrl")
        }

        var offset = 0
        while offset < data.count {
            let end = min(offset + Self.uploadChunkSize, data.count)
            let slice = data[offset..<end]
            // The session URL is pre-authorised, so these carry no bearer token.
            _ = try await send(Self.uploadChunkRequest(uploadURL: uploadURL, chunk: Data(slice),
                                                       offset: offset, total: data.count))
            offset = end
        }
    }

    static func createUploadSessionRequest(path: String, token: String) -> URLRequest {
        var r = URLRequest(url: itemURL(path: path, suffix: "/createUploadSession"))
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(
            withJSONObject: ["item": ["@microsoft.graph.conflictBehavior": "replace"]])
        return r
    }

    static func parseUploadSessionURL(_ data: Data) -> URL? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let string = root["uploadUrl"] as? String else { return nil }
        return URL(string: string)
    }

    /// One byte-range slice. `Content-Range` is inclusive at both ends, which is
    /// the detail most easily got wrong — `bytes 0-9/10` is a complete 10-byte
    /// file, not `bytes 0-10/10`.
    static func uploadChunkRequest(uploadURL: URL, chunk: Data, offset: Int, total: Int) -> URLRequest {
        var r = URLRequest(url: uploadURL)
        r.httpMethod = "PUT"
        r.setValue("\(chunk.count)", forHTTPHeaderField: "Content-Length")
        r.setValue("bytes \(offset)-\(offset + chunk.count - 1)/\(total)",
                   forHTTPHeaderField: "Content-Range")
        r.httpBody = chunk
        return r
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
            guard let refresh = RemoteTokenStore.token(for: self.refreshAccount) else {
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
            RemoteTokenStore.setToken(access, for: self.tokenAccount)
            // Microsoft rotates refresh tokens — persist the new one when present.
            if let rotated = json["refresh_token"] as? String {
                RemoteTokenStore.setToken(rotated, for: self.refreshAccount)
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
    /// Graph's delta: `/delta` on a drive item issues an `@odata.deltaLink`, and
    /// calling that link later returns everything that changed since.
    static func deltaRequest(path: String, token: String) -> URLRequest {
        pageRequest(url: itemURL(path: path, suffix: "/delta"), token: token)
    }

    /// One page of a delta response.
    ///
    /// Graph is **id-keyed**, not path-keyed: a rename arrives as the same id at
    /// a new path, so the path has to be rebuilt from `parentReference.path`
    /// (`/drive/root:/Notes`) plus the item's own name. A `deleted` facet marks
    /// removals — they carry no other metadata, which is why they cannot simply
    /// be parsed as items.
    static func parseDeltaPage(_ data: Data)
        -> (changed: [RemoteEntry], deleted: [String], next: String?, delta: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["value"] as? [[String: Any]] else {
            return ([], [], nil, nil)
        }
        let formatter = ISO8601DateFormatter()
        var changed: [RemoteEntry] = []
        var deleted: [String] = []

        for item in items {
            guard let name = item["name"] as? String else { continue }
            let parent = (item["parentReference"] as? [String: Any])?["path"] as? String ?? ""
            // "/drive/root:/Notes" -> "/Notes"; the root itself -> "".
            let folder = parent.range(of: "root:").map { String(parent[$0.upperBound...]) } ?? ""
            let path = folder.isEmpty ? "/" + name : folder + "/" + name

            if item["deleted"] != nil {
                deleted.append(path)
                continue
            }
            changed.append(RemoteEntry(
                path: path,
                name: name,
                isDirectory: item["folder"] != nil,
                size: item["size"] as? Int ?? 0,
                modified: (item["lastModifiedDateTime"] as? String).flatMap { formatter.date(from: $0) },
                rev: (item["eTag"] as? String) ?? (item["cTag"] as? String)))
        }
        return (changed, deleted,
                root["@odata.nextLink"] as? String,
                root["@odata.deltaLink"] as? String)
    }

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
        RemoteTokenStore.setToken(access, for: self.tokenAccount)
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
extension OneDriveStore: ASWebAuthenticationPresentationContextProviding {
    // Shared with the other three providers: on iOS a bare `ASPresentationAnchor()`
    // is a scene-less `UIWindow`, which makes `start()` fail with
    // `presentationContextInvalid` and the login sheet never appear.
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        WebAuthAnchor.presentationAnchor()
    }
}
#endif
