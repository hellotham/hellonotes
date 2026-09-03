//
//  CloudWalkConcurrencyTests.swift
//  HelloNotesTests
//
//  Opening a large cloud collection took minutes, and the cause was a
//  classification rather than an algorithm.
//
//  `ResumableTreeWalk` is latency-bound, and it already knew that: a source
//  says how many listings it can usefully have in flight, `RemoteTreeSource`
//  says six, and the default is one because a real directory listing is a
//  syscall over a warm cache that gains nothing from overlapping.
//
//  A vault on iCloud Drive has a file path, so it goes through
//  `LocalTreeSource` and inherited that serial default — but every listing is
//  an XPC round trip into the provider's extension, and a network fetch behind
//  that for a folder it has not enumerated. N folders, N latencies, end to end.
//

import Foundation
import Testing
@testable import HelloNotes

struct CloudWalkConcurrencyTests {

    /// A source with a provider's latency profile: each listing costs time the
    /// app spends waiting rather than working.
    private struct SlowSource: TreeSource {
        let breadth: Int
        let depth: Int
        let delay: Duration
        let width: Int
        var listingConcurrency: Int { width }

        func unavailability() -> CollectionState.UnavailableReason? { nil }

        func children(of directory: String) async throws -> DirectoryListing {
            try? await Task.sleep(for: delay)
            let level = directory.isEmpty ? 0 : directory.split(separator: "/").count
            var listing = DirectoryListing()
            if level < depth {
                for i in 0..<breadth {
                    let name = directory.isEmpty ? "d\(i)" : "\(directory)/d\(i)"
                    listing.children.append(TreeChild(
                        url: URL(filePath: "/vault/\(name)"), isDirectory: true))
                }
            }
            listing.children.append(TreeChild(
                url: URL(filePath: "/vault/\(directory)/note.md"),
                isDirectory: false, isMarkdown: true,
                modified: .distantPast, size: 1))
            return listing
        }
    }

    private func walk(width: Int) async -> (Duration, Int) {
        let source = SlowSource(breadth: 3, depth: 3, delay: .milliseconds(20), width: width)
        var files = 0
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            _ = await ResumableTreeWalk.run(source: source) { batch in
                files += batch.children.count(where: { !$0.isDirectory })
            }
        }
        return (elapsed, files)
    }

    /// Overlapping the listings is materially faster, and finds the same tree.
    ///
    /// 40 directories at 20 ms each is 800 ms serially. This asserts a wide
    /// walk beats a serial one by a clear margin rather than a precise ratio:
    /// the point is that the latencies overlap at all, and a strict speed-up
    /// figure would be a CI flake waiting to happen.
    @Test func overlappingListingsIsFasterAndFindsTheSameTree() async {
        let (serial, serialFiles) = await walk(width: 1)
        let (wide, wideFiles) = await walk(width: 6)

        #expect(serialFiles == wideFiles, "the wide walk must find exactly the same files")
        #expect(wideFiles == 40, "3^0+3^1+3^2+3^3 directories, one note each")
        #expect(wide < serial / 2,
                "expected overlapping to at least halve the wall clock; serial \(serial), wide \(wide)")
    }

    /// The classification itself — the actual defect.
    @Test func aProviderBackedRootIsNotTreatedAsALocalOne() {
        let iCloud = URL(filePath: "/Users/x/Library/Mobile Documents/iCloud~md~obsidian/Documents/My Vault")
        let dropbox = URL(filePath: "/Users/x/Library/CloudStorage/Dropbox/Notes")
        let plain = URL(filePath: "/Users/x/Documents/Notes")

        #expect(LocalTreeSource.isProviderBacked(iCloud))
        #expect(LocalTreeSource.isProviderBacked(dropbox))
        #expect(!LocalTreeSource.isProviderBacked(plain))

        #expect(LocalTreeSource(root: iCloud).listingConcurrency > 1)
        #expect(LocalTreeSource(root: dropbox).listingConcurrency > 1)
    }

    /// **An ordinary folder must not change.** The serial default is deliberate
    /// there — overlapping warm-cache syscalls buys nothing and costs seek
    /// contention, and `theWalkIsCompetitiveWithTheEnumeratorOnARealisticVault`
    /// exists because routing width-1 through the concurrency window once made
    /// the local walk about four times slower.
    @Test func anOrdinaryFolderStaysSerial() {
        #expect(LocalTreeSource(root: URL(filePath: "/Users/x/Notes")).listingConcurrency == 1)
        #expect(LocalTreeSource(root: URL(filePath: "/Volumes/Big/Vault")).listingConcurrency == 1)
    }
}

/// Opening a direct-API cloud collection: one request for the tree, not one
/// per folder.
struct RecursiveListingTests {

    /// A provider that counts what it is asked, and can be told to support the
    /// recursive call or not.
    private final class CountingStore: RemoteStore, @unchecked Sendable {
        let providerName = "Counting"
        let accountID = "count"
        let supportsRecursive: Bool
        private(set) var listCalls = 0
        private(set) var recursiveCalls = 0
        private let tree: [RemoteEntry]

        init(folders: Int, filesPerFolder: Int, supportsRecursive: Bool) {
            self.supportsRecursive = supportsRecursive
            var entries: [RemoteEntry] = []
            for f in 0..<folders {
                entries.append(RemoteEntry(path: "/f\(f)", name: "f\(f)",
                                           isDirectory: true, size: 0))
                for n in 0..<filesPerFolder {
                    entries.append(RemoteEntry(path: "/f\(f)/n\(n).md", name: "n\(n).md",
                                               isDirectory: false, size: 10))
                }
            }
            self.tree = entries
        }

        func list(path: String) async throws -> [RemoteEntry] {
            listCalls += 1
            let parent = path.isEmpty ? "" : path
            return tree.filter { ($0.path as NSString).deletingLastPathComponent == (parent.isEmpty ? "/" : parent) }
        }

        func listRecursively(path: String) async throws -> [RemoteEntry]? {
            guard supportsRecursive else { return nil }
            recursiveCalls += 1
            return tree
        }

        var isAuthenticated: Bool { true }
        func authenticate() async throws {}
        func signOut() {}
        func read(path: String) async throws -> Data { Data() }
        func write(_ data: Data, to path: String) async throws {}
        func delete(path: String) async throws {}
    }

    private func walk(_ store: CountingStore, prefetching: Bool) async -> Int {
        let cache = prefetching ? RecursiveListingCache(store: store, root: "") : nil
        let source = RemoteTreeSource(store: store, remoteRoot: "",
                                      cacheRoot: URL(filePath: "/tmp/mirror"),
                                      prefetch: cache)
        var files = 0
        _ = await ResumableTreeWalk.run(source: source) { batch in
            files += batch.children.count(where: { !$0.isDirectory })
        }
        return files
    }

    /// **The whole point.** Twenty folders cost twenty-one listings without the
    /// prefetch and one recursive request with it — and both find the same
    /// files. On a real provider each of those listings is a network round trip.
    @Test func oneRequestReplacesOnePerFolder() async {
        let without = CountingStore(folders: 20, filesPerFolder: 5, supportsRecursive: true)
        let with = CountingStore(folders: 20, filesPerFolder: 5, supportsRecursive: true)

        let plainFiles = await walk(without, prefetching: false)
        let fastFiles = await walk(with, prefetching: true)

        #expect(plainFiles == fastFiles, "the prefetched walk must find the same files")
        #expect(plainFiles == 100)
        #expect(without.listCalls == 21, "root plus one per folder")
        #expect(with.recursiveCalls == 1, "one recursive request for the whole tree")
        #expect(with.listCalls == 0, "and no per-folder listings at all")
    }

    /// A provider without the call is unaffected — it walks as it always did.
    @Test func aProviderWithoutItFallsBackToWalking() async {
        let store = CountingStore(folders: 5, filesPerFolder: 2, supportsRecursive: false)
        let files = await walk(store, prefetching: true)
        #expect(files == 10)
        #expect(store.listCalls == 6, "root plus one per folder, exactly as before")
    }

    /// The recursive call is attempted once. A provider that refused will refuse
    /// again, and retrying per directory would be slower than never trying.
    @Test func theRecursiveCallIsAttemptedOnce() async {
        let store = CountingStore(folders: 8, filesPerFolder: 1, supportsRecursive: false)
        let cache = RecursiveListingCache(store: store, root: "")
        for _ in 0..<5 { _ = await cache.children(of: "/f0") }
        #expect(store.listCalls == 0)
    }
}

/// Every provider has answered the recursive-listing question.
struct RecursiveListingCoverageTests {

    private static func source(_ name: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "HelloNotes/Core/Remote/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// **Consistency is the point, not universality.** Two of these can return a
    /// subtree in a few requests and two cannot, so the rule is not "everyone
    /// implements it" — it is that nobody inherits the default silently. A
    /// provider that walks should say it walks, and why, where the next person
    /// will read it.
    @Test func everyProviderStatesItsAnswer() throws {
        for store in ["DropboxStore.swift", "OneDriveStore.swift",
                      "GoogleDriveStore.swift", "BoxStore.swift"] {
            let text = try Self.source(store)
            #expect(text.contains("func listRecursively"),
                    "\(store) inherits the default silently — implement it, or override it and say why not")
        }
    }

    /// Box's decline carries its reason, so it reads as a decision.
    @Test func boxExplainsWhyItDeclines() throws {
        // Comment markers stripped *and* whitespace normalised: the assertion is
        // that the reason is stated, not that a sentence happens to wrap in a
        // particular place. The first two runs failed on
        // "*eventually\n    /// consistent*" — a true sentence and a false
        // negative, twice.
        let box = try Self.source("BoxStore.swift")
            .replacingOccurrences(of: "///", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // A local, so a failure prints the verdict rather than the whole file.
        let statesTheReason = box.contains("eventually consistent")
        #expect(statesTheReason,
                "the reason Box cannot use search for an authoritative listing must be stated")
    }
}

/// Google Drive assembles a subtree from two queries; these check the parsing
/// that makes that possible, which needs no network.
struct GoogleDriveTreeParsingTests {

    @Test func aFolderPageYieldsIdsNamesAndParents() throws {
        let json = Data("""
        {"nextPageToken":"tok","files":[
          {"id":"a","name":"Vault","parents":["root"]},
          {"id":"b","name":"Daily","parents":["a"]},
          {"id":"c","name":"Orphan"}
        ]}
        """.utf8)
        let page = try GoogleDriveStore.parseFolderTreePage(json)
        #expect(page.nextPageToken == "tok")
        #expect(page.folders.count == 3)
        #expect(page.folders[1].parent == "a")
        #expect(page.folders[2].parent == nil, "a folder with no parents must not invent one")
    }

    /// Google-native documents have no bytes to download, so they are not notes
    /// — the same rule the ordinary listing applies, applied here too.
    @Test func nativeGoogleDocsAreSkippedButFoldersAreNot() throws {
        let json = Data("""
        {"files":[
          {"id":"1","name":"Note.md","mimeType":"text/markdown","size":"12","parents":["a"]},
          {"id":"2","name":"Sheet","mimeType":"application/vnd.google-apps.spreadsheet","parents":["a"]},
          {"id":"3","name":"Sub","mimeType":"application/vnd.google-apps.folder","parents":["a"]}
        ]}
        """.utf8)
        let page = try GoogleDriveStore.parseFilesInParentsPage(json)
        #expect(page.items.map(\.name) == ["Note.md", "Sub"])
        #expect(page.items[0].size == 12, "Drive returns size as a string")
        #expect(page.items[1].isFolder)
    }

    /// The `or` chain is how one request covers many folders.
    @Test func theParentsQueryAsksAboutEveryFolderInTheChunk() {
        let request = GoogleDriveStore.filesInParentsRequest(parents: ["a", "b", "c"], token: "t")
        let query = request.url?.query?.removingPercentEncoding ?? ""
        #expect(query.contains("'a' in parents or 'b' in parents or 'c' in parents"))
        #expect(query.contains("trashed=false"))
    }
}
