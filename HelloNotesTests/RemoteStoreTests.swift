//
//  RemoteStoreTests.swift
//  HelloNotesTests
//
//  Pure-logic coverage for the Phase-4 direct-API pilot (DropboxStore). The
//  network calls and OAuth need a real Dropbox app key, but path handling,
//  request construction, header escaping, PKCE, and response parsing are pure
//  and tested here.
//

import Testing
import Foundation
@testable import HelloNotes

struct DropboxStoreTests {

    @Test func normalizesPaths() {
        #expect(DropboxStore.normalizedPath("") == "")
        #expect(DropboxStore.normalizedPath("/") == "")
        #expect(DropboxStore.normalizedPath("Notes/Idea.md") == "/Notes/Idea.md")
        #expect(DropboxStore.normalizedPath("/Notes/Idea.md") == "/Notes/Idea.md")
        #expect(DropboxStore.normalizedPath("/Notes/") == "/Notes")
        #expect(DropboxStore.normalizedPath("  /Notes/Sub/  ") == "/Notes/Sub")
    }

    @Test func listFolderRequestIsWellFormed() throws {
        let r = DropboxStore.listFolderRequest(path: "/Notes", token: "Tok")
        #expect(r.httpMethod == "POST")
        #expect(r.url?.absoluteString == "https://api.dropboxapi.com/2/files/list_folder")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer Tok")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(r.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["path"] as? String == "/Notes")
        #expect(json["recursive"] as? Bool == false)
    }

    @Test func uploadRequestCarriesArgHeaderAndBody() {
        let payload = Data("hello".utf8)
        let r = DropboxStore.uploadRequest(path: "x.md", token: "T", data: payload)
        #expect(r.url?.absoluteString == "https://content.dropboxapi.com/2/files/upload")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        #expect(r.httpBody == payload)
        let arg = r.value(forHTTPHeaderField: "Dropbox-API-Arg") ?? ""
        #expect(arg.contains("\"path\""))
        #expect(arg.contains("/x.md"))
        #expect(arg.contains("overwrite"))
    }

    @Test func apiArgEscapesNonASCII() {
        // Header values must be ASCII-safe: a Unicode filename becomes \uXXXX.
        let arg = DropboxStore.apiArg(["path": "/café.md"])
        #expect(arg.contains("\\u00e9"))
        #expect(!arg.contains("é"))
    }

    @Test func parsesListFolderResponse() throws {
        let fixture = """
        {"entries":[
          {".tag":"file","name":"Idea.md","path_display":"/Notes/Idea.md","size":42,"server_modified":"2026-07-21T00:00:00Z","rev":"abc"},
          {".tag":"folder","name":"Sub","path_display":"/Notes/Sub"}
        ]}
        """
        let entries = try DropboxStore.parseListFolder(Data(fixture.utf8))
        #expect(entries.count == 2)
        let file = entries[0]
        #expect(file.name == "Idea.md")
        #expect(file.path == "/Notes/Idea.md")
        #expect(file.isDirectory == false)
        #expect(file.size == 42)
        #expect(file.rev == "abc")
        #expect(file.modified != nil)
        let folder = entries[1]
        #expect(folder.isDirectory == true)
        #expect(folder.name == "Sub")
    }

    @Test func pkceChallengeIsDeterministicBase64URL() {
        let verifier = "test-verifier-12345"
        let a = DropboxStore.codeChallenge(for: verifier)
        let b = DropboxStore.codeChallenge(for: verifier)
        #expect(a == b)                                   // deterministic
        #expect(!a.isEmpty)
        #expect(!a.contains("+") && !a.contains("/") && !a.contains("="))  // base64url
    }

    @Test func authorizeURLHasPKCEParams() throws {
        let url = DropboxStore.authorizeURL(appKey: "KEY", redirectURI: "hellonotes://dropbox-auth", challenge: "CHAL")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ n: String) -> String? { items.first { $0.name == n }?.value }
        #expect(url.host == "www.dropbox.com")
        #expect(value("client_id") == "KEY")
        #expect(value("response_type") == "code")
        #expect(value("code_challenge") == "CHAL")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("redirect_uri") == "hellonotes://dropbox-auth")
        #expect(value("token_access_type") == "offline")
    }

    @Test func tokenExchangeRequestIsFormEncoded() {
        let r = DropboxStore.tokenExchangeRequest(code: "CODE", verifier: "VER", appKey: "KEY",
                                                  redirectURI: "hellonotes://dropbox-auth")
        #expect(r.httpMethod == "POST")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = String(data: r.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code=CODE"))
        #expect(body.contains("code_verifier=VER"))
    }

    @Test func refreshTokenRequestIsFormEncoded() {
        let r = DropboxStore.refreshTokenRequest(refreshToken: "RT", appKey: "KEY")
        #expect(r.url?.absoluteString == "https://api.dropboxapi.com/oauth2/token")
        let body = String(data: r.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("refresh_token=RT"))
        #expect(body.contains("client_id=KEY"))
    }
}

/// End-to-end coverage of the direct-API browse/open/edit/save flow against an
/// in-memory store — the same protocol DropboxStore implements. Proves the UI
/// model's wiring without a live provider.
@MainActor
struct RemoteBrowserModelTests {

    @Test func connectListsRoot() async {
        let model = RemoteBrowserModel(store: MockRemoteStore())
        #expect(model.isAuthenticated == false)
        await model.connect()
        #expect(model.isAuthenticated)
        #expect(model.entries.contains { $0.name == "Welcome.md" && !$0.isDirectory })
        #expect(model.entries.contains { $0.name == "Notes" && $0.isDirectory })
    }

    @Test func navigateOpenEditSavePersists() async throws {
        let model = RemoteBrowserModel(store: MockRemoteStore())
        await model.connect()

        // Into the "Notes" folder.
        let notes = try #require(model.entries.first { $0.name == "Notes" })
        await model.open(notes)
        #expect(model.path == "/Notes")
        #expect(model.canGoUp)

        // Open a note, edit, save.
        let idea = try #require(model.entries.first { $0.name == "Idea.md" })
        await model.open(idea)
        #expect(model.openPath == "/Notes/Idea.md")
        #expect(model.openText.contains("Idea"))
        model.openText = "# Edited\n\nnew body"
        await model.save()
        #expect(model.didSave)
        #expect(model.error == nil)

        // Re-open → the edit persisted through the store.
        model.closeNote()
        #expect(model.openPath == nil)
        await model.open(idea)
        #expect(model.openText == "# Edited\n\nnew body")

        // Back up to root.
        await model.goUp()
        #expect(model.path == "")
        #expect(!model.canGoUp)
    }

    @Test func listBeforeAuthSurfacesError() async {
        let model = RemoteBrowserModel(store: MockRemoteStore())
        await model.load("")   // not connected yet
        #expect(model.entries.isEmpty)
        #expect(model.error != nil)
    }
}

/// Pure-logic coverage for the Box provider. Box's API is folder/file-ID based;
/// these tests pin the path conventions, request shapes (incl. the multipart
/// upload and the client-secret token exchange), and response parsing.
struct BoxStoreTests {

    @Test func normalizesPathsAndParents() {
        #expect(BoxStore.normalizedPath("") == "")
        #expect(BoxStore.normalizedPath("/") == "")
        #expect(BoxStore.normalizedPath("Notes/Idea.md") == "/Notes/Idea.md")
        #expect(BoxStore.normalizedPath("/Notes/") == "/Notes")
        #expect(BoxStore.parentPath(of: "/Notes/Idea.md") == "/Notes")
        #expect(BoxStore.parentPath(of: "/Idea.md") == "")
        #expect(BoxStore.parentPath(of: "") == "")
    }

    @Test func authorizeURLHasRequiredParams() throws {
        let url = BoxStore.authorizeURL(clientID: "CID", redirectURI: "hellonotes://box-auth", state: "S1")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ n: String) -> String? { items.first { $0.name == n }?.value }
        #expect(url.host == "account.box.com")
        #expect(url.path == "/api/oauth2/authorize")
        #expect(value("client_id") == "CID")
        #expect(value("response_type") == "code")
        #expect(value("redirect_uri") == "hellonotes://box-auth")
        #expect(value("state") == "S1")
    }

    @Test func tokenExchangeUsesClientSecret() {
        let r = BoxStore.tokenExchangeRequest(code: "C", clientID: "ID", clientSecret: "SEC")
        #expect(r.url?.absoluteString == "https://api.box.com/oauth2/token")
        #expect(r.httpMethod == "POST")
        let body = String(data: r.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code=C"))
        #expect(body.contains("client_secret=SEC"))
    }

    @Test func refreshRequestCarriesRefreshGrant() {
        let r = BoxStore.refreshRequest(refreshToken: "RT", clientID: "ID", clientSecret: "SEC")
        let body = String(data: r.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("refresh_token=RT"))
        #expect(body.contains("client_secret=SEC"))
    }

    @Test func listItemsRequestIsWellFormed() {
        let r = BoxStore.listItemsRequest(folderID: "42", token: "T")
        let s = r.url?.absoluteString ?? ""
        #expect(s.hasPrefix("https://api.box.com/2.0/folders/42/items"))
        #expect(s.contains("fields=id,type,name,size,modified_at"))
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer T")
    }

    @Test func parsesFolderItemsSkippingWebLinks() throws {
        let fixture = """
        {"total_count":3,"entries":[
          {"type":"file","id":"111","name":"Idea.md","size":42,"modified_at":"2026-07-21T10:00:00-07:00"},
          {"type":"folder","id":"222","name":"Sub"},
          {"type":"web_link","id":"333","name":"Link"}
        ]}
        """
        let items = try BoxStore.parseItems(Data(fixture.utf8), parentPath: "/Notes")
        #expect(items.count == 2)   // web_link skipped
        #expect(items[0].entry.path == "/Notes/Idea.md")
        #expect(items[0].id == "111")
        #expect(items[0].entry.isDirectory == false)
        #expect(items[0].entry.size == 42)
        #expect(items[0].entry.modified != nil)
        #expect(items[1].entry.isDirectory == true)
        #expect(items[1].id == "222")
    }

    @Test func uploadNewRequestIsMultipartWithAttributes() {
        let r = BoxStore.uploadNewRequest(name: "x.md", parentID: "0", data: Data("hi".utf8),
                                          token: "T", boundary: "BND")
        #expect(r.url?.absoluteString == "https://upload.box.com/api/2.0/files/content")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=BND")
        let body = String(data: r.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("name=\"attributes\""))
        #expect(body.contains("\"parent\":{\"id\":\"0\"}"))
        #expect(body.contains("name=\"file\"; filename=\"x.md\""))
        #expect(body.contains("hi"))
        #expect(body.hasSuffix("--BND--\r\n"))
    }

    @Test func uploadUpdateTargetsFileID() {
        let r = BoxStore.uploadUpdateRequest(fileID: "999", filename: "x.md", data: Data("v2".utf8),
                                             token: "T", boundary: "BND")
        #expect(r.url?.absoluteString == "https://upload.box.com/api/2.0/files/999/content")
        let body = String(data: r.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(!body.contains("name=\"attributes\""))   // update needs no attributes part
        #expect(body.contains("v2"))
    }

    @Test func parsesUploadedFileID() {
        let fixture = #"{"total_count":1,"entries":[{"type":"file","id":"555","name":"x.md"}]}"#
        #expect(BoxStore.parseUploadedFileID(Data(fixture.utf8)) == "555")
    }
}

/// The mirror that promotes a RemoteStore to a first-class collection: it must
/// pull the remote tree into a local cache and push edits back.
@MainActor
struct RemoteMirrorTests {

    @Test func syncDownThenUploadRoundTrips() async throws {
        let store = MockRemoteStore(preAuthenticated: true)
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("hn-mirror-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }

        let mirror = RemoteMirror(store: store, cacheRoot: cache, remoteRoot: "", displayName: "Demo")
        try await mirror.syncDown()

        // The remote tree landed in the local cache (incl. the nested folder).
        let welcome = cache.appendingPathComponent("Welcome.md")
        let idea = cache.appendingPathComponent("Notes/Idea.md")
        #expect(FileManager.default.fileExists(atPath: welcome.path))
        #expect(FileManager.default.fileExists(atPath: idea.path))

        // Path mapping round-trips.
        #expect(mirror.remotePath(forLocalURL: idea) == "/Notes/Idea.md")
        #expect(mirror.localURL(forRemotePath: "/Notes/Idea.md").standardizedFileURL == idea.standardizedFileURL)

        // Edit the cached copy, upload, and confirm the store now serves the edit.
        try FileIO.write("# Changed in the mirror", to: idea)
        try await mirror.upload(localURL: idea)
        let readBack = try await store.read(path: "/Notes/Idea.md")
        #expect(String(decoding: readBack, as: UTF8.self) == "# Changed in the mirror")
    }

    @Test func remoteRootIsStrippedInMapping() {
        let store = MockRemoteStore()
        let cache = URL(fileURLWithPath: "/tmp/cacheRoot")
        let mirror = RemoteMirror(store: store, cacheRoot: cache, remoteRoot: "/Vault", displayName: "Vault")
        // A remote path under the mirrored subfolder maps to a cache-relative path.
        #expect(mirror.localURL(forRemotePath: "/Vault/Sub/Note.md").path == "/tmp/cacheRoot/Sub/Note.md")
        #expect(mirror.remotePath(forLocalURL: cache.appendingPathComponent("Sub/Note.md")) == "/Vault/Sub/Note.md")
    }
}
