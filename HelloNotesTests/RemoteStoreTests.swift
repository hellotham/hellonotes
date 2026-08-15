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

    /// Opening the browser with a token already in the Keychain skips
    /// `connect()` entirely. Nothing else listed the root, so the window came up
    /// "signed in" and completely empty — no files, no error, nothing to act on.
    @Test func anAlreadyAuthenticatedBrowserListsTheRootByItself() async {
        let model = RemoteBrowserModel(store: MockRemoteStore(preAuthenticated: true))
        #expect(model.isAuthenticated)
        #expect(model.entries.isEmpty)      // nothing has been listed yet

        await model.loadRootIfNeeded()

        #expect(model.entries.contains { $0.name == "Welcome.md" })
        #expect(model.error == nil)

        // Idempotent: re-running (a re-entrant `.task`) must not re-list.
        await model.loadRootIfNeeded()
        #expect(model.entries.filter { $0.name == "Welcome.md" }.count == 1)
    }

    /// A stored token the provider rejects must offer a way back in, rather than
    /// presenting as an empty account.
    @Test func aRejectedTokenAsksToSignInAgain() async {
        // `preAuthenticated: false` makes every call throw `.notAuthenticated`,
        // standing in for an expired or revoked token.
        let store = MockRemoteStore()
        let model = RemoteBrowserModel(store: store)
        await model.load("")

        #expect(model.error != nil)
        #expect(model.entries.isEmpty)
        #expect(model.needsReauthentication)
    }

    /// …but an ordinary unreadable folder is not an auth problem, and must not
    /// invite the user to sign in again for no reason.
    @Test func aForbiddenFolderIsNotAnAuthFailure() async {
        let store = ForbiddenFolderStore()
        let model = RemoteBrowserModel(store: store)
        await model.load("/Locked")

        #expect(model.error != nil)
        #expect(model.needsReauthentication == false)
    }
}

/// Authenticates fine, but 403s every listing — a restricted shared folder.
private final class ForbiddenFolderStore: RemoteStore, @unchecked Sendable {
    let providerName = "Forbidden"
    var isAuthenticated: Bool { true }
    func authenticate() async throws {}
    func signOut() {}
    func list(path: String) async throws -> [RemoteEntry] {
        throw RemoteStoreError.http(403, "access_denied")
    }
    func read(path: String) async throws -> Data { Data() }
    func write(_ data: Data, to path: String) async throws {}
    func delete(path: String) async throws {}
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

/// Pure-logic coverage for the Google Drive provider: reversed-client-id
/// redirect derivation, PKCE authorize/token shapes, the `q` listing query,
/// Drive's string-typed sizes, native-Doc skipping, and both upload shapes.
struct GoogleDriveStoreTests {

    private let cid = "123456789012-abc123.apps.googleusercontent.com"

    @Test func derivesReversedRedirectFromClientID() {
        #expect(GoogleDriveStore.redirectScheme(clientID: cid) == "com.googleusercontent.apps.123456789012-abc123")
        #expect(GoogleDriveStore.redirectURI(clientID: cid) == "com.googleusercontent.apps.123456789012-abc123:/oauth2redirect")
    }

    @Test func authorizeURLHasPKCEAndDriveScope() throws {
        let url = GoogleDriveStore.authorizeURL(clientID: cid, challenge: "CHAL", state: "S1")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ n: String) -> String? { items.first { $0.name == n }?.value }
        #expect(url.host == "accounts.google.com")
        #expect(value("client_id") == cid)
        #expect(value("response_type") == "code")
        #expect(value("scope") == "https://www.googleapis.com/auth/drive")
        #expect(value("code_challenge") == "CHAL")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("redirect_uri") == GoogleDriveStore.redirectURI(clientID: cid))
        #expect(value("state") == "S1")
    }

    @Test func tokenExchangeIsPKCEWithoutSecret() {
        let r = GoogleDriveStore.tokenExchangeRequest(code: "C", verifier: "V", clientID: cid)
        #expect(r.url?.absoluteString == "https://oauth2.googleapis.com/token")
        let body = String(data: r.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code_verifier=V"))
        #expect(!body.contains("client_secret"))
    }

    @Test func listRequestQueriesParentAndSkipsTrash() {
        let r = GoogleDriveStore.listRequest(folderID: "root", token: "T")
        let s = r.url?.absoluteString ?? ""
        #expect(s.hasPrefix("https://www.googleapis.com/drive/v3/files"))
        #expect(s.contains("in%20parents") || s.contains("in+parents"))
        #expect(s.contains("trashed"))
        // `fields` must request the file properties *and* nextPageToken (the
        // pager needs it; Drive omits it unless explicitly selected).
        #expect(s.contains("id,name,mimeType,size,modifiedTime"))
        #expect(s.contains("nextPageToken"))
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer T")
    }

    @Test func parsesFileListWithStringSizesAndSkipsNativeDocs() throws {
        let fixture = """
        {"files":[
          {"id":"F1","name":"Idea.md","mimeType":"text/markdown","size":"42","modifiedTime":"2026-07-21T10:00:00.123Z"},
          {"id":"D1","name":"Sub","mimeType":"application/vnd.google-apps.folder"},
          {"id":"G1","name":"A Google Doc","mimeType":"application/vnd.google-apps.document"}
        ]}
        """
        let items = try GoogleDriveStore.parseFileList(Data(fixture.utf8), parentPath: "/Notes")
        #expect(items.count == 2)                       // native Doc skipped
        #expect(items[0].entry.path == "/Notes/Idea.md")
        #expect(items[0].entry.size == 42)              // string "42" → 42
        #expect(items[0].entry.modified != nil)
        #expect(items[0].id == "F1")
        #expect(items[1].entry.isDirectory == true)
    }

    @Test func createRequestIsMultipartRelated() {
        let r = GoogleDriveStore.createRequest(name: "x.md", parentID: "root",
                                               data: Data("hi".utf8), token: "T", boundary: "BND")
        #expect(r.url?.absoluteString.hasPrefix("https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart") == true)
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "multipart/related; boundary=BND")
        let body = String(data: r.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"name\":\"x.md\""))
        #expect(body.contains("\"parents\":[\"root\"]"))
        #expect(body.contains("hi"))
        #expect(body.hasSuffix("--BND--\r\n"))
    }

    @Test func updateRequestPatchesMedia() {
        let r = GoogleDriveStore.updateRequest(fileID: "F9", data: Data("v2".utf8), token: "T")
        #expect(r.httpMethod == "PATCH")
        #expect(r.url?.absoluteString == "https://www.googleapis.com/upload/drive/v3/files/F9?uploadType=media")
        #expect(r.httpBody == Data("v2".utf8))
    }

    @Test func parsesCreatedFileID() {
        #expect(GoogleDriveStore.parseFileID(Data(#"{"id":"NEW1"}"#.utf8)) == "NEW1")
    }
}

/// Pure-logic coverage for the OneDrive (Microsoft Graph) provider: the
/// `root:/{path}:` URL building (incl. percent-encoding), PKCE OAuth shapes on
/// the common authority, and folder/file facet parsing.
struct OneDriveStoreTests {

    @Test func buildsGraphPathURLs() {
        // Root uses /root; a path uses the root:/…: addressing.
        #expect(OneDriveStore.itemURL(path: "", suffix: "/children").absoluteString
            == "https://graph.microsoft.com/v1.0/me/drive/root/children")
        #expect(OneDriveStore.itemURL(path: "/Notes", suffix: "/children").absoluteString
            == "https://graph.microsoft.com/v1.0/me/drive/root:/Notes:/children")
        #expect(OneDriveStore.itemURL(path: "/Notes/Idea.md", suffix: "/content").absoluteString
            == "https://graph.microsoft.com/v1.0/me/drive/root:/Notes/Idea.md:/content")
        // Spaces in a component are percent-encoded; separators stay literal.
        #expect(OneDriveStore.itemURL(path: "/My Notes/A B.md", suffix: "").absoluteString
            == "https://graph.microsoft.com/v1.0/me/drive/root:/My%20Notes/A%20B.md:")
    }

    @Test func uploadIsSimplePutOfBytes() {
        let r = OneDriveStore.uploadRequest(path: "/Notes/Idea.md", data: Data("hi".utf8), token: "T")
        #expect(r.httpMethod == "PUT")
        #expect(r.url?.absoluteString == "https://graph.microsoft.com/v1.0/me/drive/root:/Notes/Idea.md:/content")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        #expect(r.httpBody == Data("hi".utf8))
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer T")
    }

    @Test func listRequestSelectsFacets() {
        let r = OneDriveStore.listRequest(path: "", token: "T")
        let s = r.url?.absoluteString ?? ""
        #expect(s.contains("me/drive/root/children"))
        #expect(s.contains("folder") && s.contains("file") && s.contains("lastModifiedDateTime"))
    }

    @Test func authorizeUsesCommonAuthorityAndPKCE() throws {
        let url = OneDriveStore.authorizeURL(clientID: "CID", redirectURI: "hellonotes://onedrive-auth",
                                             challenge: "CHAL", state: "S1")
        #expect(url.absoluteString.hasPrefix("https://login.microsoftonline.com/common/oauth2/v2.0/authorize"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ n: String) -> String? { items.first { $0.name == n }?.value }
        #expect(value("client_id") == "CID")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("redirect_uri") == "hellonotes://onedrive-auth")
        #expect(value("scope")?.contains("Files.ReadWrite") == true)
        #expect(value("scope")?.contains("offline_access") == true)
    }

    @Test func tokenExchangeIsPKCEWithScope() {
        let r = OneDriveStore.tokenExchangeRequest(code: "C", verifier: "V", clientID: "CID",
                                                   redirectURI: "hellonotes://onedrive-auth")
        #expect(r.url?.absoluteString == "https://login.microsoftonline.com/common/oauth2/v2.0/token")
        let body = String(data: r.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code_verifier=V"))
        #expect(!body.contains("client_secret"))
        #expect(body.contains("offline_access"))
    }

    @Test func parsesChildrenByFacet() throws {
        let fixture = """
        {"value":[
          {"name":"Idea.md","size":42,"file":{"mimeType":"text/markdown"},"lastModifiedDateTime":"2026-07-21T10:00:00Z","eTag":"e1"},
          {"name":"Sub","size":0,"folder":{"childCount":2},"lastModifiedDateTime":"2026-07-20T09:00:00Z"}
        ]}
        """
        let entries = try OneDriveStore.parseChildren(Data(fixture.utf8), parentPath: "/Notes")
        #expect(entries.count == 2)
        #expect(entries[0].path == "/Notes/Idea.md")
        #expect(entries[0].isDirectory == false)
        #expect(entries[0].size == 42)
        #expect(entries[0].rev == "e1")
        #expect(entries[0].modified != nil)
        #expect(entries[1].isDirectory == true)   // has a folder facet
    }
}

/// Pagination: every provider pages its folder listing, and dropping the
/// continuation cursor silently truncates big folders (and, for the ID-based
/// providers, makes the missing notes unreadable). These pin the cursor
/// plumbing on each parser + request builder.
struct RemoteListPaginationTests {

    @Test func dropboxSurfacesCursorAndHasMore() throws {
        let page1 = #"{"entries":[{".tag":"file","name":"a.md","path_display":"/a.md"}],"cursor":"CUR1","has_more":true}"#
        let p1 = try DropboxStore.parseListFolderPage(Data(page1.utf8))
        #expect(p1.entries.count == 1)
        #expect(p1.cursor == "CUR1")
        #expect(p1.hasMore == true)

        let page2 = #"{"entries":[{".tag":"file","name":"b.md","path_display":"/b.md"}],"cursor":"CUR2","has_more":false}"#
        let p2 = try DropboxStore.parseListFolderPage(Data(page2.utf8))
        #expect(p2.hasMore == false)

        // The continue request carries the cursor to the right endpoint.
        let r = DropboxStore.listFolderContinueRequest(cursor: "CUR1", token: "T")
        #expect(r.url?.absoluteString == "https://api.dropboxapi.com/2/files/list_folder/continue")
        let httpBody = try #require(r.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        #expect(body["cursor"] as? String == "CUR1")
    }

    @Test func boxPagesByOffsetUsingRawCount() throws {
        // A full page whose entries include a web_link: the *raw* count must
        // drive paging, or the walk would stop early on the filtered count.
        let fixture = """
        {"entries":[
          {"type":"file","id":"1","name":"a.md"},
          {"type":"web_link","id":"2","name":"link"}
        ]}
        """
        let page = try BoxStore.parseItemsPage(Data(fixture.utf8), parentPath: "")
        #expect(page.items.count == 1)     // web_link filtered out
        #expect(page.rawCount == 2)        // but paging sees both

        let r = BoxStore.listItemsRequest(folderID: "0", token: "T", offset: 1000)
        let s = r.url?.absoluteString ?? ""
        #expect(s.contains("offset=1000"))
        #expect(s.contains("limit=\(BoxStore.pageSize)"))
    }

    @Test func googleDriveSurfacesNextPageToken() throws {
        let fixture = #"{"files":[{"id":"F1","name":"a.md","mimeType":"text/markdown"}],"nextPageToken":"NPT1"}"#
        let page = try GoogleDriveStore.parseFileListPage(Data(fixture.utf8), parentPath: "")
        #expect(page.items.count == 1)
        #expect(page.nextPageToken == "NPT1")

        let last = #"{"files":[{"id":"F2","name":"b.md","mimeType":"text/markdown"}]}"#
        #expect(try GoogleDriveStore.parseFileListPage(Data(last.utf8), parentPath: "").nextPageToken == nil)

        // nextPageToken must be requested in `fields`, and the token forwarded.
        let r = GoogleDriveStore.listRequest(folderID: "root", token: "T", pageToken: "NPT1")
        let s = r.url?.absoluteString ?? ""
        #expect(s.contains("nextPageToken"))
        #expect(s.contains("pageToken=NPT1"))
    }

    @Test func oneDriveSurfacesODataNextLink() throws {
        let fixture = """
        {"value":[{"name":"a.md","size":1,"file":{}}],
         "@odata.nextLink":"https://graph.microsoft.com/v1.0/me/drive/root/children?$skiptoken=ABC"}
        """
        let page = try OneDriveStore.parseChildrenPage(Data(fixture.utf8), parentPath: "")
        #expect(page.entries.count == 1)
        #expect(page.nextLink?.absoluteString.contains("skiptoken=ABC") == true)

        let last = #"{"value":[{"name":"b.md","size":1,"file":{}}]}"#
        #expect(try OneDriveStore.parseChildrenPage(Data(last.utf8), parentPath: "").nextLink == nil)

        // The continuation URL is fetched verbatim, with auth attached.
        let url = try #require(page.nextLink)
        let r = OneDriveStore.pageRequest(url: url, token: "T")
        #expect(r.url == url)
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer T")
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

    /// A note deleted on the provider must disappear from the mirror on the next
    /// sync. Otherwise it lingers in the sidebar and the next save re-uploads
    /// (resurrects) it.
    @Test func syncDownPrunesNotesDeletedRemotely() async throws {
        let store = MockRemoteStore(preAuthenticated: true)
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("hn-mirror-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }

        let mirror = RemoteMirror(store: store, cacheRoot: cache, remoteRoot: "", displayName: "Demo")
        try await mirror.syncDown()
        let tasks = cache.appendingPathComponent("Notes/Tasks.md")
        #expect(FileManager.default.fileExists(atPath: tasks.path))

        // Deleted on the provider (e.g. from another device) …
        try await store.delete(path: "/Notes/Tasks.md")
        try await mirror.syncDown()

        // … so it must be gone locally too, while its siblings survive.
        #expect(!FileManager.default.fileExists(atPath: tasks.path))
        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("Notes/Idea.md").path))
        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("Welcome.md").path))
    }

    @Test func remoteRootIsStrippedInMapping() {
        let store = MockRemoteStore()
        let cache = URL(fileURLWithPath: "/tmp/cacheRoot")
        let mirror = RemoteMirror(store: store, cacheRoot: cache, remoteRoot: "/Vault", displayName: "Vault")
        // A remote path under the mirrored subfolder maps to a cache-relative path.
        #expect(mirror.localURL(forRemotePath: "/Vault/Sub/Note.md").path == "/tmp/cacheRoot/Sub/Note.md")
        #expect(mirror.remotePath(forLocalURL: cache.appendingPathComponent("Sub/Note.md")) == "/Vault/Sub/Note.md")
    }

    // MARK: - Partial syncs

    /// One unreadable folder — a restricted share, a rate limit — used to abort
    /// the whole sync and (because the caller discarded the error) leave the
    /// user with nothing and no explanation. It must now cost only its own
    /// subtree, and say so.
    @Test func aFailedSubfolderCostsItsSubtreeNotTheWholeSync() async throws {
        let store = FaultyRemoteStore()
        store.failingFolders = ["/Notes"]
        let cache = Self.tempCache()
        defer { try? FileManager.default.removeItem(at: cache) }

        let mirror = RemoteMirror(store: store, cacheRoot: cache, remoteRoot: "", displayName: "Demo")
        let outcome = try await mirror.syncDown()

        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("Welcome.md").path))
        #expect(!FileManager.default.fileExists(atPath: cache.appendingPathComponent("Notes/Idea.md").path))
        #expect(outcome.isComplete == false)
        #expect(outcome.failures.map(\.path) == ["/Notes"])
    }

    /// The invariant everything else rests on: **only a pass that saw the whole
    /// remote tree may delete.** A note absent from a partial listing may simply
    /// live in a subtree the sync never reached, and pruning it would destroy a
    /// local copy the provider still has.
    @Test func anIncompleteSyncPrunesNothing() async throws {
        let store = FaultyRemoteStore()
        let cache = Self.tempCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = RemoteMirror(store: store, cacheRoot: cache, remoteRoot: "", displayName: "Demo")

        // A complete pass first, so the cache holds the whole tree.
        let full = try await mirror.syncDown()
        #expect(full.isComplete)
        let idea = cache.appendingPathComponent("Notes/Idea.md")
        #expect(FileManager.default.fileExists(atPath: idea.path))

        // Now the subfolder becomes unreadable. Its notes are missing from this
        // pass's listing — but they are NOT deleted remotely, and must survive.
        store.failingFolders = ["/Notes"]
        let partial = try await mirror.syncDown()
        #expect(partial.isComplete == false)
        #expect(FileManager.default.fileExists(atPath: idea.path))
        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("Notes/Tasks.md").path))
    }

    /// Cancellation returns what was fetched, marked incomplete — and, being
    /// incomplete, deletes nothing.
    @Test func aCancelledSyncIsIncompleteAndPrunesNothing() async throws {
        let store = FaultyRemoteStore()
        let cache = Self.tempCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = RemoteMirror(store: store, cacheRoot: cache, remoteRoot: "", displayName: "Demo")

        try await mirror.syncDown()
        // A file the provider does not have: a *complete* sync would prune it.
        let orphan = cache.appendingPathComponent("Orphan.md")
        try FileIO.write("# left over", to: orphan)

        let outcome = try await Task {
            // Cancel before syncDown's first cancellation check, so the test is
            // deterministic rather than a race with the network stub.
            withUnsafeCurrentTask { $0?.cancel() }
            return try await mirror.syncDown()
        }.value

        #expect(outcome.isComplete == false)
        #expect(outcome.progress.foldersListed == 0)
        #expect(FileManager.default.fileExists(atPath: orphan.path))
    }

    /// The root listing failing means we have nothing at all — an expired token
    /// or a bad path. That has to reach the user as an error, not arrive as a
    /// silently empty collection.
    @Test func rootListingFailureIsFatalRatherThanAnEmptyCollection() async throws {
        let store = FaultyRemoteStore(preAuthenticated: false)   // every call 401s
        let cache = Self.tempCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = RemoteMirror(store: store, cacheRoot: cache, remoteRoot: "", displayName: "Demo")

        await #expect(throws: RemoteStoreError.notAuthenticated) {
            try await mirror.syncDown()
        }
    }

    /// The action reported nothing at all while it ran. Progress has to be
    /// observable, or a long sync is indistinguishable from a dead button.
    @Test func syncDownReportsProgressAsItGoes() async throws {
        let store = FaultyRemoteStore()
        let cache = Self.tempCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = RemoteMirror(store: store, cacheRoot: cache, remoteRoot: "", displayName: "Demo")

        let collector = ProgressCollector()
        let outcome = try await mirror.syncDown { collector.record($0) }

        #expect(outcome.isComplete)
        #expect(outcome.progress.foldersListed == 2)          // root + /Notes
        #expect(outcome.progress.notesDownloaded == 3)
        let seen = collector.values
        #expect(seen.count >= 4)                              // 2 listings + 3 downloads
        #expect(seen.last?.notesDownloaded == 3)
        // Counts only ever climb — a progress bar that goes backwards is a lie.
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0.notesDownloaded <= $1.notesDownloaded })
    }

    /// A folder with no Markdown in it syncs to an empty collection. The sync
    /// has to say so — an unexplained empty collection reads as a broken app.
    @Test func nonMarkdownFilesAreCountedNotSilentlyIgnored() async throws {
        let store = FaultyRemoteStore()
        // A "Resume" folder: real documents, not a note in sight.
        try await store.write(Data("pdf".utf8), to: "/Resume/Resume.pdf")
        try await store.write(Data("doc".utf8), to: "/Resume/Cover Letter.docx")
        let cache = Self.tempCache()
        defer { try? FileManager.default.removeItem(at: cache) }

        let mirror = RemoteMirror(store: store, cacheRoot: cache,
                                  remoteRoot: "/Resume", displayName: "Resume")
        let outcome = try await mirror.syncDown()

        #expect(outcome.isComplete)
        #expect(outcome.progress.notesDownloaded == 0)
        #expect(outcome.progress.otherFilesSkipped == 2)
        #expect(outcome.skippedExamples.contains("Resume.pdf"))
    }

    // MARK: - Metadata-first mirroring

    /// The shape of the folder arrives without a byte of content being fetched —
    /// and **every** file, not just Markdown, so a Resume folder of PDFs is a
    /// collection with files in it rather than an unexplained empty one.
    @Test func metadataSyncCreatesTheTreeWithoutDownloadingAnything() async throws {
        let store = CountingRemoteStore()
        try await store.write(Data("pdf".utf8), to: "/Resume.pdf")
        let cache = Self.tempCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = RemoteMirror(store: store, cacheRoot: cache, remoteRoot: "", displayName: "Demo")

        let outcome = try await mirror.syncMetadata()

        #expect(outcome.isComplete)
        #expect(store.reads == 0, "metadata only — nothing downloaded")
        // Names exist at their real paths, Markdown and otherwise.
        for name in ["Welcome.md", "Notes/Idea.md", "Notes/Tasks.md", "Resume.pdf"] {
            #expect(FileManager.default.fileExists(atPath: cache.appending(path: name).path),
                    "\(name) should exist as a placeholder")
        }
        // …and every one of them is a placeholder, not content.
        #expect(mirror.dehydratedRelativePaths.contains("Welcome.md"))
        #expect(mirror.isHydrated(localURL: cache.appending(path: "Welcome.md")) == false)
    }

    @Test func hydratingFetchesExactlyOneFile() async throws {
        let store = CountingRemoteStore()
        let cache = Self.tempCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = RemoteMirror(store: store, cacheRoot: cache, remoteRoot: "", displayName: "Demo")
        try await mirror.syncMetadata()

        let welcome = cache.appending(path: "Welcome.md")
        try await mirror.hydrate(localURL: welcome)

        #expect(store.reads == 1)
        #expect(mirror.isHydrated(localURL: welcome))
        #expect(try String(contentsOf: welcome, encoding: .utf8).contains("Welcome"))
        #expect(!mirror.dehydratedRelativePaths.contains("Welcome.md"))

        // Idempotent — the editor calls this on every open.
        try await mirror.hydrate(localURL: welcome)
        #expect(store.reads == 1)
    }

    /// A hydrated note keeps its content across a re-sync; only a note whose
    /// revision moved is dropped back to a placeholder.
    @Test func resyncKeepsHydratedContentUnlessTheRevisionMoved() async throws {
        let store = CountingRemoteStore()
        let cache = Self.tempCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = RemoteMirror(store: store, cacheRoot: cache, remoteRoot: "", displayName: "Demo")
        try await mirror.syncMetadata()
        let welcome = cache.appending(path: "Welcome.md")
        try await mirror.hydrate(localURL: welcome)

        try await mirror.syncMetadata()
        #expect(mirror.isHydrated(localURL: welcome), "unchanged remotely, so still downloaded")

        // Someone edits it on another device: new revision.
        try await store.write(Data("# Changed elsewhere".utf8), to: "/Welcome.md")
        try await mirror.syncMetadata()
        #expect(mirror.isHydrated(localURL: welcome) == false, "changed remotely, so stale")
    }

    /// The last line of defence. A placeholder is a file that exists with no
    /// content; uploading one would replace the real note with nothing.
    @Test func aPlaceholderIsNeverUploadedOverTheRealNote() async throws {
        let store = CountingRemoteStore()
        let cache = Self.tempCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = RemoteMirror(store: store, cacheRoot: cache, remoteRoot: "", displayName: "Demo")
        try await mirror.syncMetadata()

        let welcome = cache.appending(path: "Welcome.md")
        #expect(try Data(contentsOf: welcome).isEmpty, "it really is a zero-byte stand-in")
        #expect(mirror.isHydrated(localURL: welcome) == false)

        // The collection-level guard refuses; prove the mirror agrees about the
        // state that guard reads.
        let remaining = try await store.read(path: "/Welcome.md")
        #expect(String(decoding: remaining, as: UTF8.self).contains("Welcome"),
                "the provider's copy is untouched")
    }

    /// Two-sided edit: keep both, and say so.
    @Test func aRemoteChangeDuringAnEditProducesAConflictedCopy() async throws {
        let store = CountingRemoteStore()
        let cache = Self.tempCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = RemoteMirror(store: store, cacheRoot: cache, remoteRoot: "", displayName: "Demo")
        try await mirror.syncMetadata()
        let welcome = cache.appending(path: "Welcome.md")
        try await mirror.hydrate(localURL: welcome)

        // They edit on another device (bumping the rev); we edit locally.
        try await store.write(Data("# Theirs".utf8), to: "/Welcome.md")
        try FileIO.write("# Mine", to: welcome)

        await #expect(throws: (any Error).self) { try await mirror.upload(localURL: welcome) }

        // Mine is untouched…
        #expect(try String(contentsOf: welcome, encoding: .utf8) == "# Mine")
        // …theirs is beside it…
        let siblings = try FileManager.default.contentsOfDirectory(atPath: cache.path)
        let conflicted = try #require(siblings.first { $0.contains("conflicted copy") })
        #expect(try String(contentsOf: cache.appending(path: conflicted), encoding: .utf8) == "# Theirs")
        // …and the provider still has theirs, not a silent overwrite.
        #expect(String(decoding: try await store.read(path: "/Welcome.md"), as: UTF8.self) == "# Theirs")
    }

    // MARK: - Refresh

    /// A delta reports what *changed*, not what exists, so an item absent from
    /// it is an item that did not change — never one that was deleted. Pruning
    /// on a delta would remove the whole untouched vault.
    @Test func aDeltaRefreshNeverPrunesWhatItDidNotMention() async throws {
        let store = DeltaRemoteStore()
        let cache = Self.tempCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = RemoteMirror(store: store, cacheRoot: cache, remoteRoot: "", displayName: "Demo")
        try await mirror.syncMetadata()
        #expect(FileManager.default.fileExists(atPath: cache.appending(path: "Notes/Idea.md").path))

        // The provider reports one changed file and nothing else.
        store.nextChanges = RemoteChangeSet(
            changed: [RemoteEntry(path: "/Welcome.md", name: "Welcome.md", isDirectory: false,
                                  size: 9, modified: nil, rev: "r99")],
            deleted: [], cursor: "c2")
        try await mirror.refresh()

        #expect(FileManager.default.fileExists(atPath: cache.appending(path: "Notes/Idea.md").path),
                "an untouched note must survive a delta")
        #expect(FileManager.default.fileExists(atPath: cache.appending(path: "Notes/Tasks.md").path))
    }

    /// Deletions come from the feed's own explicit list, and those *are* applied.
    @Test func aDeltaAppliesTheDeletionsItDoesReport() async throws {
        let store = DeltaRemoteStore()
        let cache = Self.tempCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = RemoteMirror(store: store, cacheRoot: cache, remoteRoot: "", displayName: "Demo")
        try await mirror.syncMetadata()

        store.nextChanges = RemoteChangeSet(changed: [], deleted: ["/Notes/Tasks.md"], cursor: "c2")
        try await mirror.refresh()

        #expect(!FileManager.default.fileExists(atPath: cache.appending(path: "Notes/Tasks.md").path))
        #expect(FileManager.default.fileExists(atPath: cache.appending(path: "Notes/Idea.md").path))
    }

    /// An expired cursor is an instruction to start over, not a failure.
    @Test func anExpiredCursorFallsBackToAFullSync() async throws {
        let store = DeltaRemoteStore()
        let cache = Self.tempCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = RemoteMirror(store: store, cacheRoot: cache, remoteRoot: "", displayName: "Demo")
        try await mirror.syncMetadata()

        store.nextChanges = RemoteChangeSet(requiresFullResync: true)
        let outcome = try await mirror.refresh()

        #expect(outcome.isComplete)
        #expect(FileManager.default.fileExists(atPath: cache.appending(path: "Welcome.md").path))
    }

    /// Dropbox marks removals with a `deleted` tag and no metadata, so the
    /// entry parser drops them — they need reading separately or a delta would
    /// silently never delete anything.
    @Test func dropboxDeletionsAreParsedSeparatelyFromEntries() {
        let fixture = """
        {"entries":[
          {".tag":"file","name":"A.md","path_display":"/A.md","size":1,"rev":"r1"},
          {".tag":"deleted","name":"B.md","path_display":"/B.md"}
        ],"cursor":"c","has_more":false}
        """
        let deleted = DropboxStore.parseDeletions(Data(fixture.utf8))
        #expect(deleted == ["/B.md"])
        let entries = try? DropboxStore.parseListFolder(Data(fixture.utf8))
        #expect(entries?.count == 1)
        #expect(entries?.first?.name == "A.md")
    }

    // MARK: - Bounding the cache

    /// A lazy cache that never lets go is only a slower way of downloading
    /// everything. Eviction returns content to placeholders — the names stay, so
    /// nothing disappears from the collection.
    @Test func evictionDropsTheLeastRecentlyUsedContentBackToPlaceholders() async throws {
        let store = CountingRemoteStore()
        let cache = Self.tempCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = RemoteMirror(store: store, cacheRoot: cache, remoteRoot: "", displayName: "Demo")
        try await mirror.syncMetadata()

        let welcome = cache.appending(path: "Welcome.md")
        let idea = cache.appending(path: "Notes/Idea.md")
        try await mirror.hydrate(localURL: welcome)
        try await mirror.hydrate(localURL: idea)
        #expect(mirror.hydratedBytes > 0)

        // Welcome was read long ago; Idea just now.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: welcome.path)

        // A limit small enough to force one out, keeping what is on screen.
        let evicted = mirror.evictIfNeeded(limit: 1, keeping: ["Notes/Idea.md"])

        #expect(evicted == 1)
        #expect(mirror.isHydrated(localURL: welcome) == false, "the stale one went")
        #expect(mirror.isHydrated(localURL: idea), "the pinned one stayed")
        #expect(FileManager.default.fileExists(atPath: welcome.path),
                "its name must remain — the note may not vanish from the collection")
        #expect(try Data(contentsOf: welcome).isEmpty)
    }

    @Test func evictionDoesNothingWhenTheCacheFits() async throws {
        let store = CountingRemoteStore()
        let cache = Self.tempCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = RemoteMirror(store: store, cacheRoot: cache, remoteRoot: "", displayName: "Demo")
        try await mirror.syncMetadata()
        try await mirror.hydrate(localURL: cache.appending(path: "Welcome.md"))

        #expect(mirror.evictIfNeeded(limit: 100 * 1024 * 1024) == 0)
        #expect(mirror.isHydrated(localURL: cache.appending(path: "Welcome.md")))
    }

    /// The manifest describes the cache completely, so a mirror can be rebuilt
    /// from the directory alone — which is what makes restoring on launch safe.
    @Test func aMirrorCanBeRebuiltFromItsCacheDirectory() async throws {
        let store = CountingRemoteStore()
        let cache = Self.tempCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let first = RemoteMirror(store: store, cacheRoot: cache, remoteRoot: "", displayName: "Demo")
        try await first.syncMetadata()
        try await first.hydrate(localURL: cache.appending(path: "Welcome.md"))

        // A fresh process: nothing but the directory on disk.
        let manifest = try #require(RemoteManifest.load(fromCacheRoot: cache))
        #expect(manifest.displayName == "Demo")
        #expect(manifest.provider == store.providerName)

        let rebuilt = RemoteMirror(store: store, cacheRoot: cache,
                                   remoteRoot: manifest.remoteRoot,
                                   displayName: manifest.displayName)
        #expect(rebuilt.isHydrated(localURL: cache.appending(path: "Welcome.md")))
        #expect(rebuilt.dehydratedRelativePaths.contains("Notes/Idea.md"))
    }

    /// Graph's simple PUT caps at 4 MB. Anything larger has to go through an
    /// upload session, in byte ranges — and `Content-Range` is inclusive at both
    /// ends, which is the detail most easily got wrong.
    @Test func graphChunkRangesAreInclusiveAndCoverTheWholeFile() {
        let url = URL(string: "https://graph/upload/session")!
        let first = OneDriveStore.uploadChunkRequest(uploadURL: url, chunk: Data(count: 10),
                                                     offset: 0, total: 25)
        #expect(first.value(forHTTPHeaderField: "Content-Range") == "bytes 0-9/25")
        #expect(first.httpMethod == "PUT")
        // Pre-authorised session URL: sending a bearer token here is wrong.
        #expect(first.value(forHTTPHeaderField: "Authorization") == nil)

        let last = OneDriveStore.uploadChunkRequest(uploadURL: url, chunk: Data(count: 5),
                                                    offset: 20, total: 25)
        #expect(last.value(forHTTPHeaderField: "Content-Range") == "bytes 20-24/25")
    }

    @Test func graphChunksAreAMultipleOfTheRequiredSize() {
        // Graph requires every chunk but the last to be a multiple of 320 KiB.
        #expect(OneDriveStore.uploadChunkSize % (320 * 1024) == 0)
        #expect(OneDriveStore.uploadChunkSize <= OneDriveStore.simpleUploadLimit)
    }

    @Test func graphUploadSessionURLIsParsed() {
        let data = Data(#"{"uploadUrl":"https://graph/session/abc","expirationDateTime":"x"}"#.utf8)
        #expect(OneDriveStore.parseUploadSessionURL(data)?.absoluteString == "https://graph/session/abc")
        #expect(OneDriveStore.parseUploadSessionURL(Data("{}".utf8)) == nil)
    }

    private static func tempCache() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hn-mirror-\(UUID().uuidString)")
    }
}

/// `MockRemoteStore` that counts content downloads and issues a fresh revision
/// on every write, so a test can tell metadata from content and detect a
/// two-sided edit the way a real provider would.
private final class CountingRemoteStore: RemoteStore, @unchecked Sendable {
    private let inner = MockRemoteStore(preAuthenticated: true)
    private let lock = NSLock()
    private var readCount = 0
    private var revisions: [String: Int] = [:]

    var reads: Int { lock.lock(); defer { lock.unlock() }; return readCount }

    var providerName: String { inner.providerName }
    var isAuthenticated: Bool { inner.isAuthenticated }
    func authenticate() async throws { try await inner.authenticate() }
    func signOut() { inner.signOut() }

    func list(path: String) async throws -> [RemoteEntry] {
        try await inner.list(path: path).map { entry in
            var stamped = entry
            lock.lock()
            stamped.rev = entry.isDirectory ? nil : "r\(revisions[entry.path] ?? 0)"
            lock.unlock()
            return stamped
        }
    }
    func read(path: String) async throws -> Data {
        lock.lock(); readCount += 1; lock.unlock()
        return try await inner.read(path: path)
    }
    func write(_ data: Data, to path: String) async throws {
        try await inner.write(data, to: path)
        lock.lock(); revisions[path, default: 0] += 1; lock.unlock()
    }
    func delete(path: String) async throws { try await inner.delete(path: path) }
}

/// Delta parsing for the three providers whose feeds cannot be exercised
/// without a live account. Fixtures pin the shapes, per this file's convention
/// for every other provider request and response.
struct ProviderDeltaTests {

    // MARK: OneDrive / Graph

    @Test func graphDeltaRebuildsPathsAndSeparatesDeletions() {
        let fixture = """
        {"value":[
          {"name":"Idea.md","size":42,"lastModifiedDateTime":"2026-08-15T00:00:00Z","eTag":"e1",
           "parentReference":{"path":"/drive/root:/Notes"}},
          {"name":"Sub","folder":{},"parentReference":{"path":"/drive/root:"}},
          {"name":"Gone.md","deleted":{"state":"deleted"},
           "parentReference":{"path":"/drive/root:/Notes"}}
        ],"@odata.deltaLink":"https://graph/next"}
        """
        let page = OneDriveStore.parseDeltaPage(Data(fixture.utf8))

        #expect(page.changed.count == 2)
        #expect(page.changed[0].path == "/Notes/Idea.md")
        #expect(page.changed[0].rev == "e1")
        #expect(page.changed[1].path == "/Sub")
        #expect(page.changed[1].isDirectory)
        // A deletion must not arrive as an ordinary item, or a refresh would
        // resurrect the very note that was deleted elsewhere.
        #expect(page.deleted == ["/Notes/Gone.md"])
        #expect(page.delta == "https://graph/next")
    }

    @Test func graphDeltaRequestTargetsTheMirroredFolder() {
        let root = OneDriveStore.deltaRequest(path: "", token: "T")
        #expect(root.url?.absoluteString == "https://graph.microsoft.com/v1.0/me/drive/root/delta")
        #expect(root.value(forHTTPHeaderField: "Authorization") == "Bearer T")

        let sub = OneDriveStore.deltaRequest(path: "/Notes", token: "T")
        #expect(sub.url?.absoluteString.contains("root:/Notes:/delta") == true)
    }

    // MARK: Box

    @Test func boxEventsBuildPathsFromThePathCollection() {
        let fixture = """
        {"entries":[
          {"event_type":"ITEM_UPLOAD","source":{"type":"file","name":"Idea.md","size":42,
            "modified_at":"2026-08-15T00:00:00+00:00","etag":"7",
            "path_collection":{"entries":[{"name":"All Files"},{"name":"Notes"}]}}},
          {"event_type":"ITEM_TRASH","source":{"type":"file","name":"Old.md",
            "path_collection":{"entries":[{"name":"All Files"}]}}}
        ],"next_stream_position":12345}
        """
        let page = BoxStore.parseEvents(Data(fixture.utf8))

        #expect(page.changed.count == 1)
        #expect(page.changed[0].path == "/Notes/Idea.md", "the invisible All Files root is dropped")
        #expect(page.changed[0].rev == "7")
        #expect(page.deleted == ["/Old.md"])
        #expect(page.position == "12345")
    }

    @Test func boxEventsRequestAsksTheChangesStream() {
        let r = BoxStore.eventsRequest(streamPosition: "now", token: "T")
        let url = r.url?.absoluteString ?? ""
        #expect(url.hasPrefix("https://api.box.com/2.0/events"))
        #expect(url.contains("stream_type=changes"))
        #expect(url.contains("stream_position=now"))
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer T")
    }

    // MARK: Google Drive

    @Test func driveChangesSeparateRemovalsFromEdits() {
        let fixture = """
        {"changes":[
          {"fileId":"f1","file":{"id":"f1","name":"Idea.md","mimeType":"text/markdown",
            "size":"42","modifiedTime":"2026-08-15T00:00:00Z","version":"9"}},
          {"fileId":"f2","removed":true},
          {"fileId":"f3","file":{"id":"f3","name":"Trashed.md","mimeType":"text/markdown","trashed":true}}
        ],"newStartPageToken":"tok2"}
        """
        let page = GoogleDriveStore.parseChangesPage(Data(fixture.utf8))

        #expect(page.changed.count == 1)
        #expect(page.changed[0].id == "f1")
        #expect(page.changed[0].entry.name == "Idea.md")
        #expect(page.changed[0].entry.size == 42, "Drive reports sizes as strings")
        // Trashed counts as removed — the file is gone from where it was.
        #expect(Set(page.removed) == ["f2", "f3"])
        #expect(page.newStart == "tok2")
    }

    @Test func driveChangesRequestCarriesTheTokenAndFields() {
        let r = GoogleDriveStore.changesRequest(pageToken: "tok", token: "T")
        let url = r.url?.absoluteString ?? ""
        #expect(url.hasPrefix("https://www.googleapis.com/drive/v3/changes"))
        #expect(url.contains("pageToken=tok"))
        #expect(url.contains("newStartPageToken"))
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer T")
    }

    @Test func driveStartPageTokenIsParsed() {
        #expect(GoogleDriveStore.parseStartPageToken(Data(#"{"startPageToken":"99"}"#.utf8)) == "99")
    }
}

/// A store with a scriptable delta feed, so refresh behaviour can be tested
/// without a provider.
private final class DeltaRemoteStore: RemoteStore, @unchecked Sendable {
    private let inner = MockRemoteStore(preAuthenticated: true)
    private let lock = NSLock()
    private var scripted: RemoteChangeSet?

    var nextChanges: RemoteChangeSet? {
        get { lock.lock(); defer { lock.unlock() }; return scripted }
        set { lock.lock(); scripted = newValue; lock.unlock() }
    }

    var providerName: String { inner.providerName }
    var isAuthenticated: Bool { inner.isAuthenticated }
    func authenticate() async throws { try await inner.authenticate() }
    func signOut() { inner.signOut() }
    func list(path: String) async throws -> [RemoteEntry] { try await inner.list(path: path) }
    func read(path: String) async throws -> Data { try await inner.read(path: path) }
    func write(_ data: Data, to path: String) async throws { try await inner.write(data, to: path) }
    func delete(path: String) async throws { try await inner.delete(path: path) }
    func changes(since cursor: String?, path: String) async throws -> RemoteChangeSet? { nextChanges }
}

/// Collects progress reports from the sync's executor for assertion on the test's.
private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RemoteSyncProgress] = []
    func record(_ p: RemoteSyncProgress) { lock.lock(); storage.append(p); lock.unlock() }
    var values: [RemoteSyncProgress] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// `MockRemoteStore` with the failure modes a real provider actually produces:
/// a folder you may not list (403 on a restricted share) and a file that comes
/// back rate-limited (429). The mirror has to survive both.
private final class FaultyRemoteStore: RemoteStore, @unchecked Sendable {
    private let inner: MockRemoteStore
    var failingFolders: Set<String> = []
    var failingFiles: Set<String> = []

    init(preAuthenticated: Bool = true) {
        inner = MockRemoteStore(preAuthenticated: preAuthenticated)
    }

    var providerName: String { inner.providerName }
    var isAuthenticated: Bool { inner.isAuthenticated }
    func authenticate() async throws { try await inner.authenticate() }
    func signOut() { inner.signOut() }

    func list(path: String) async throws -> [RemoteEntry] {
        if failingFolders.contains(path) { throw RemoteStoreError.http(403, "access_denied") }
        return try await inner.list(path: path)
    }
    func read(path: String) async throws -> Data {
        if failingFiles.contains(path) { throw RemoteStoreError.http(429, "too_many_requests") }
        return try await inner.read(path: path)
    }
    func write(_ data: Data, to path: String) async throws { try await inner.write(data, to: path) }
    func delete(path: String) async throws { try await inner.delete(path: path) }
}
