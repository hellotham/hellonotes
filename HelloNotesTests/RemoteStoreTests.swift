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
}
