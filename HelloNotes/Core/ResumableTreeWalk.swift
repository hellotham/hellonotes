//
//  ResumableTreeWalk.swift
//  HelloNotes
//
//  Created by Chris Tham on 15/8/2026.
//
//  Walking a folder we do not control, in a way that survives being interrupted.
//
//  `FileManager.enumerator` is a black box: it returns when it is finished, it
//  cannot be checkpointed, and cancelling it yields nothing. That was tolerable
//  while every collection was a local notes vault and a walk took milliseconds.
//  It stops being tolerable the moment a collection can be an entire cloud root,
//  where a walk is thousands of network-backed directory listings — and it was
//  never really true on iOS, where the OS suspends the app mid-walk as a matter
//  of routine and the walk simply started again from nothing next launch.
//
//  So the walk is an explicit **frontier**: a queue of directories not yet
//  visited, popped one at a time. Everything asked of it falls out of that shape
//  rather than being bolted on — the frontier is a list of paths, so it
//  checkpoints to disk trivially; each directory yields its children as soon as
//  it is listed, so results are incremental; and a failure is confined to the
//  one directory that produced it.
//

import Foundation
import UniformTypeIdentifiers

// MARK: - The source

/// One entry in a directory listing, flattened to what a scan actually needs.
///
/// `isMarkdown` is decided by the source rather than the caller: the source is
/// already holding the resource values, and asking twice is a second `stat`.
// **Everything in this file is `nonisolated`, and that is load-bearing.**
//
// The app target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so an
// unannotated type is `@MainActor`. That made `LocalTreeSource` main-actor
// isolated, so `await source.children(of:)` hopped the walk *onto* the main
// actor from inside the very `Task.detached` that existed to keep it off —
// "detached" governs priority, task-locals and cancellation, not isolation.
//
// The cost was invisible on a local folder and severe on a cloud one: on the
// reported 2,000-note iCloud vault every directory listing became a synchronous
// XPC round-trip to `fileproviderd` (`FPDaemonConnection valuesForAttributes:`)
// on the main thread, and the watchdog caught the editor blocked for five
// seconds at a time with exactly that stack. Two earlier fixes reasoned about
// which code was "off the main actor", were locally right, and changed nothing,
// because the isolation was decided by a build setting rather than by the code.

nonisolated struct TreeChild: Sendable, Equatable {
    var url: URL
    var isDirectory: Bool
    /// A bundle presented as a single item (`.rtfd`, `.app`). Never descended
    /// into — matching `.skipsPackageDescendants` on the old enumerator.
    var isPackage: Bool = false
    var isMarkdown: Bool = false
    var modified: Date = .distantPast
    var size: Int = 0
    /// A cloud file whose contents are not local yet.
    var isOnlineOnly: Bool = false
    /// The provider's revision id, for sources that have one.
    var rev: String? = nil
}

/// A tree that can be listed one directory at a time.
///
/// The one operation that differs between a local folder and a provider's API.
/// Everything else — frontier, checkpointing, progress, cancellation, resumption,
/// error isolation — is written once, above this.
nonisolated protocol TreeSource: Sendable {
    /// Why the tree can't be read at all right now, or `nil` when it can.
    /// Checked by the walk itself so an unreadable root is never mistaken for an
    /// empty one.
    func unavailability() -> CollectionState.UnavailableReason?

    /// The immediate children of `directory`, a root-relative path
    /// (`""` is the root itself).
    func children(of directory: String) async throws -> DirectoryListing

    /// How many listings this source can usefully have in flight at once.
    ///
    /// The walk is **latency-bound, not CPU-bound**, and the two kinds of source
    /// sit at opposite ends of that. A local directory listing is a syscall
    /// against a warm cache, so overlapping them buys nothing and costs seek
    /// contention — the default is 1, and the local path therefore behaves
    /// exactly as it always has. A provider listing is a network round trip in
    /// which the app is doing nothing at all, so a folder tree of N directories
    /// costs N latencies laid end to end. That is the whole cost of adding a
    /// large cloud folder.
    var listingConcurrency: Int { get }
}

nonisolated extension TreeSource {
    /// Serial unless a source says otherwise, so nothing changes for a source
    /// that has not thought about it.
    var listingConcurrency: Int { 1 }
}

/// One directory's contents.
nonisolated struct DirectoryListing: Sendable {
    var children: [TreeChild] = []
    /// Files the source declined to return because non-note files are excluded.
    /// **Counted rather than simply dropped**: a folder of PDFs that shows as
    /// empty is how someone concludes their documents failed to import. The
    /// listing already had to look at them, so counting is free.
    var omittedFiles: Int = 0
}

// MARK: - Progress, checkpoints, results

/// Where a walk had got to. Small enough to write often, complete enough to
/// resume from exactly.
nonisolated struct WalkCheckpoint: Codable, Sendable, Equatable {
    /// Directories listed but not yet visited, root-relative.
    var frontier: [String]
    var directoriesVisited: Int
    var itemsSeen: Int
    /// How many directories the last *complete* walk of this tree found. Absent
    /// on a first run, which is why the first pass shows an indeterminate bar
    /// and later ones can show a real percentage.
    var previousTotalDirectories: Int?

    var isEmpty: Bool { frontier.isEmpty }
}

/// Live counts, emitted per directory.
nonisolated struct WalkProgress: Sendable, Equatable {
    var directoriesVisited = 0
    var directoriesRemaining = 0
    var itemsSeen = 0
    /// Non-note files skipped because the collection is hiding them.
    var filesOmitted = 0
    var currentPath = ""
    /// A real 0…1 only when a previous complete run told us the size.
    var fraction: Double?
}

/// One directory's worth of results.
nonisolated struct WalkBatch: Sendable {
    var directory: String
    var children: [TreeChild]
    var progress: WalkProgress
}

/// One listing's result, carried back from a detached fetch.
///
/// The failure case is an already-rendered message rather than an `Error`: a
/// `Task`'s value must be `Sendable` and `any Error` is not, and the message is
/// all the walk ever wanted from it.
nonisolated enum ListingOutcome: Sendable {
    case listed(DirectoryListing)
    case failed(String)
}

nonisolated struct WalkIssue: Sendable, Equatable {
    var path: String
    var message: String
}

/// What a walk achieved.
///
/// `isComplete` is the field that matters: **only a complete walk may be used to
/// delete anything.** A walk that was cancelled, suspended, or that skipped a
/// directory it could not read has not seen the whole tree, so an item missing
/// from it may simply live somewhere the walk never reached.
nonisolated struct WalkResult: Sendable {
    var isComplete = false
    var issues: [WalkIssue] = []
    var progress = WalkProgress()
    /// Non-nil when the walk stopped early and can be resumed.
    var checkpoint: WalkCheckpoint?
    /// Set when the tree could not be read at all.
    var unavailable: CollectionState.UnavailableReason?
}

// MARK: - The walk

nonisolated enum ResumableTreeWalk {

    /// Walk `source`, emitting each directory as it is listed.
    ///
    /// Breadth-first on purpose: shallow items arrive first, so a tree fills from
    /// the top the way a person reads it, instead of diving to the bottom of the
    /// first branch. The frontier is an array with a moving head rather than a
    /// queue with `removeFirst()`, which would be O(n) per directory and turn a
    /// 100k-item walk quadratic.
    ///
    /// - Parameters:
    ///   - resuming: a checkpoint from an interrupted walk, to continue from.
    ///   - checkpointEvery: directories between checkpoint callbacks.
    ///   - onCheckpoint: called on the walk's executor; persist it somewhere cheap.
    ///   - onBatch: called per directory, in order.
    static func run(
        source: some TreeSource,
        resuming checkpoint: WalkCheckpoint? = nil,
        checkpointEvery: Int = 32,
        onCheckpoint: (@Sendable (WalkCheckpoint) -> Void)? = nil,
        onBatch: (WalkBatch) async -> Void
    ) async -> WalkResult {

        if let reason = source.unavailability() {
            return WalkResult(isComplete: false, unavailable: reason)
        }

        var frontier = checkpoint?.frontier ?? [""]
        var head = 0
        var visited = checkpoint?.directoriesVisited ?? 0
        var itemsSeen = checkpoint?.itemsSeen ?? 0
        var filesOmitted = 0
        let previousTotal = checkpoint?.previousTotalDirectories
        var issues: [WalkIssue] = []
        var sinceCheckpoint = 0

        func snapshot() -> WalkCheckpoint {
            WalkCheckpoint(frontier: Array(frontier[head...]),
                           directoriesVisited: visited,
                           itemsSeen: itemsSeen,
                           previousTotalDirectories: previousTotal)
        }

        func progress(_ path: String) -> WalkProgress {
            let remaining = frontier.count - head
            return WalkProgress(
                directoriesVisited: visited,
                directoriesRemaining: remaining,
                itemsSeen: itemsSeen,
                filesOmitted: filesOmitted,
                currentPath: path,
                // Guarded against a tree that grew since the last run: a bar
                // that reaches 100% and keeps going is worse than none.
                fraction: previousTotal.map { total in
                    total > 0 ? min(1, Double(visited) / Double(total)) : 1
                })
        }

        //
        //  Listings run ahead; results are applied strictly in order.
        //
        //  `head` still means **the next directory to apply**, and that is the
        //  load-bearing detail. A listing that is in flight has been *fetched*
        //  past `head` but not *applied*, so it is still inside
        //  `frontier[head...]` — which is exactly what `snapshot()` writes. The
        //  checkpoint therefore keeps meaning what it meant when the walk was
        //  serial: everything from `head` on is unvisited, and resuming replays
        //  the in-flight directories rather than losing them.
        //
        //  Applying in order also keeps `onBatch`'s contract. It is not
        //  `@Sendable` and it mutates the caller's accumulator, so it must never
        //  be re-entered concurrently — only the *fetching* overlaps.
        //
        let width = max(1, source.listingConcurrency)
        var inFlight: [Task<ListingOutcome, Never>] = []
        // Unstructured tasks outlive the scope that made them, so every exit
        // from here — cancellation, completion, a `throw` above — must reclaim
        // them or a cancelled walk keeps talking to the provider.
        defer { for task in inFlight { task.cancel() } }
        var fetchHead = 0

        /// Top the window up. `inFlight[i]` is always the listing for
        /// `frontier[head + i]`: both consume the frontier in order and the
        /// queue is FIFO, so the correspondence cannot drift.
        ///
        /// Nothing runs here in the serial case — see `listing(of:)`.
        func fill() {
            guard width > 1 else { return }
            while inFlight.count < width, fetchHead < frontier.count {
                let directory = frontier[fetchHead]
                fetchHead += 1
                inFlight.append(Task {
                    do { return .listed(try await source.children(of: directory)) }
                    catch {
                        return .failed((error as? LocalizedError)?.errorDescription
                                        ?? error.localizedDescription)
                    }
                })
            }
        }

        /// One directory's listing, awaited directly when serial.
        ///
        /// **The serial path must not pay for the concurrent machinery.** A
        /// local vault is thousands of small directories over a warm cache, so
        /// the listing itself costs almost nothing and an unstructured `Task`
        /// per directory — an allocation and two hops — is most of the work.
        /// Routing the default width through the window made the local walk
        /// roughly four times slower, which the enumerator benchmark caught
        /// immediately. Concurrency here is a fix for network latency and
        /// nothing else; where there is no latency to hide, there is nothing to
        /// win and a measurable amount to lose.
        func outcome(for directory: String) async -> ListingOutcome {
            if width > 1 { return await inFlight.removeFirst().value }
            do { return .listed(try await source.children(of: directory)) }
            catch {
                return .failed((error as? LocalizedError)?.errorDescription
                                ?? error.localizedDescription)
            }
        }

        while head < frontier.count {
            if Task.isCancelled {
                // Everything from `head` on is still unvisited, so the snapshot
                // resumes exactly here. Results already emitted are the caller's
                // to keep — cancelling costs the remainder, not the work done.
                return WalkResult(isComplete: false, issues: issues,
                                  progress: progress(""), checkpoint: snapshot())
            }

            // Breadth-first means the window is narrow at the root and widens as
            // soon as the first listing reveals its siblings — which is the
            // shape that actually wants parallelism.
            fill()

            let directory = frontier[head]
            head += 1

            let listing: DirectoryListing
            switch await outcome(for: directory) {
            case .listed(let found):
                listing = found
            case .failed(let message):
                // One unreadable directory costs its own subtree, not the walk.
                issues.append(WalkIssue(path: directory, message: message))
                continue
            }

            visited += 1
            itemsSeen += listing.children.count
            filesOmitted += listing.omittedFiles
            for child in listing.children where child.isDirectory && !child.isPackage {
                frontier.append(Self.join(directory, child.url.lastPathComponent))
            }

            await onBatch(WalkBatch(directory: directory, children: listing.children,
                                    progress: progress(directory)))

            sinceCheckpoint += 1
            if sinceCheckpoint >= checkpointEvery {
                sinceCheckpoint = 0
                onCheckpoint?(snapshot())
            }
        }

        // Complete means the frontier drained *and* nothing was skipped. A walk
        // that couldn't read three folders has not seen the tree.
        return WalkResult(isComplete: issues.isEmpty, issues: issues,
                          progress: progress(""), checkpoint: nil)
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory.isEmpty ? name : directory + "/" + name
    }
}

// MARK: - Local source

/// A folder on disk, listed one level at a time.
nonisolated struct LocalTreeSource: TreeSource {
    let root: URL

    /// How many listings to keep in flight.
    ///
    /// **A folder on a File Provider is not a local folder wearing a path.**
    /// The default of 1 is right for a real directory — a listing there is a
    /// syscall over a warm cache and overlapping them buys nothing. It is
    /// exactly wrong for iCloud Drive or any other Files provider, where
    /// `contentsOfDirectory` is an XPC round trip into the provider's extension
    /// and, for a folder it has not enumerated yet, a network fetch behind that.
    /// Those are latencies with the app doing nothing at all, so a tree of N
    /// folders cost N of them laid end to end — which is how adding a large
    /// cloud vault came to take minutes.
    ///
    /// The classification was the bug: such a vault reaches
    /// `LocalTreeSource` because it *has* a file path, inherited the serial
    /// default meant for warm-cache syscalls, and so was walked one directory
    /// at a time. `RemoteTreeSource` had already worked this out for the
    /// direct-API providers and overlaps six.
    ///
    /// Nothing changes for an ordinary folder, which is the point: the width is
    /// 1 unless the root is demonstrably provider-backed.
    var listingConcurrency: Int { Self.isProviderBacked(root) ? 6 : 1 }

    /// Whether `url` lives behind a file provider rather than on the disk.
    ///
    /// Two shapes, both by path, and deliberately not by asking the provider —
    /// the question is asked once per scan and must not itself be a round trip:
    ///
    ///   * `…/Library/Mobile Documents/…` — iCloud Drive, including another
    ///     app's ubiquity container, which is where an Obsidian vault lives.
    ///   * `…/Library/CloudStorage/…` — every other Files provider on macOS
    ///     (Dropbox, Google Drive, OneDrive, Box).
    ///
    /// `FileManager.isUbiquitousItem` would answer the first case and not the
    /// second, and answers it by asking the coordinator — so it is both
    /// narrower and more expensive than looking at the path.
    static func isProviderBacked(_ url: URL) -> Bool {
        let path = url.path
        return path.contains("/Library/Mobile Documents/")
            || path.contains("/Library/CloudStorage/")
    }
    /// When false, non-Markdown files are dropped during the listing rather than
    /// collected and filtered later — the difference between reading and
    /// discarding a hundred thousand names, and ignoring them.
    var includesNonNoteFiles: Bool = true

    /// What the walk asks about every child.
    ///
    /// **`.contentTypeKey` is deliberately absent, and that is a fix, not an
    /// oversight.** Asking for it materialises a LaunchServices record per file,
    /// and LaunchServices tears those records down on the *main thread*
    /// (`Record::detachRecordsOnMainThread`). So a walk that is correctly off
    /// the main actor still posted thousands of main-thread releases as a side
    /// effect — measured at **3.5 seconds** of blocked main thread on a
    /// 2,000-note vault, caught by the watchdog with that symbol at the top of
    /// the stack. `Collection.isMarkdown` falls back to the filename extension,
    /// which resolves one `UTType` per distinct extension instead of one record
    /// per file.
    static let resourceKeys: [URLResourceKey] = [
        .contentModificationDateKey, .isRegularFileKey,
        .isDirectoryKey, .fileSizeKey,
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
    ]

    /// Asked only of directories, because `.isPackageKey` goes through
    /// LaunchServices too and a vault has orders of magnitude fewer folders
    /// than files.
    static let directoryKeys: Set<URLResourceKey> = [.isPackageKey]

    func unavailability() -> CollectionState.UnavailableReason? {
        Collection.unavailability(of: root)
    }

    func children(of directory: String) async throws -> DirectoryListing {
        let url = directory.isEmpty ? root : root.appending(path: directory)

        // **`contentsOfDirectory(at:)` refuses a symlink at the end of the path
        // with ENOTDIR**, even when the link points at a perfectly good
        // directory. The `atPath:` variant does not, which is why nothing else
        // in the app ever noticed: `Collection.unavailability` uses that one and
        // reported the folder as fine, so a vault reached through a symlink —
        // `~/Notes` pointing into iCloud Drive is the usual shape — passed every
        // availability check and then failed its very first listing. The
        // collection opened empty and said nothing.
        //
        // Resolved for the **enumeration only**. The resource values still come
        // from the URLs the enumeration returned, so they stay pre-cached and no
        // file pays an extra `stat`; only the URL that gets *stored* is rewritten
        // back to the collection's own spelling of the path. That matters
        // because every URL comparison in `Collection` — selection, drop
        // targets, the index cache — is written against `rootURL`, and handing
        // it a resolved path here would swap one spelling mismatch for another.
        let resolved = url.resolvingSymlinksInPath()
        let viaLink = resolved.standardizedFileURL.path != url.standardizedFileURL.path
        let contents = try FileManager.default.contentsOfDirectory(
            at: viaLink ? resolved : url,
            includingPropertiesForKeys: Self.resourceKeys,
            options: [.skipsHiddenFiles])

        var listing = DirectoryListing()
        listing.children.reserveCapacity(contents.count)
        for entry in contents {
            guard let values = try? entry.resourceValues(forKeys: Set(Self.resourceKeys)) else { continue }
            let child = viaLink ? url.appending(path: entry.lastPathComponent) : entry
            if values.isDirectory == true {
                let isPackage = (try? entry.resourceValues(forKeys: Self.directoryKeys))?.isPackage == true
                listing.children.append(TreeChild(url: child, isDirectory: true,
                                                  isPackage: isPackage))
                continue
            }
            // A symlink reports `isDirectory == false` *and*
            // `isRegularFile == false`, so a symlinked **sub**folder is skipped
            // here rather than walked. That is deliberate for now: following one
            // needs cycle detection that survives the walk's checkpoint, and a
            // loop would be an unbounded walk of someone's vault. The root is
            // the case that occurs in practice and it is handled above.
            guard values.isRegularFile == true else { continue }
            let isMarkdown = Collection.isMarkdown(child, contentType: nil)
            guard isMarkdown || includesNonNoteFiles else {
                listing.omittedFiles += 1
                continue
            }
            listing.children.append(TreeChild(
                url: child,
                isDirectory: false,
                isMarkdown: isMarkdown,
                modified: values.contentModificationDate ?? .distantPast,
                size: values.fileSize ?? 0,
                isOnlineOnly: values.isUbiquitousItem == true
                    && values.ubiquitousItemDownloadingStatus == .notDownloaded))
        }
        return listing
    }
}

// MARK: - Checkpoint storage

/// Where interrupted walks are remembered.
///
/// Application Support rather than Caches: the system may purge Caches at any
/// time, and losing a checkpoint means a 100k-item walk starts from zero.
nonisolated enum WalkCheckpointStore {

    static func save(_ checkpoint: WalkCheckpoint, for collectionID: String) {
        guard let url = fileURL(for: collectionID),
              let data = try? JSONEncoder().encode(checkpoint) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func load(for collectionID: String) -> WalkCheckpoint? {
        guard let url = fileURL(for: collectionID),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WalkCheckpoint.self, from: data)
    }

    static func remove(for collectionID: String) {
        guard let url = fileURL(for: collectionID) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Record what a *complete* walk cost, so the next one can show a real
    /// percentage instead of a spinner.
    static func rememberTotal(_ directories: Int, for collectionID: String) {
        save(WalkCheckpoint(frontier: [], directoriesVisited: 0, itemsSeen: 0,
                            previousTotalDirectories: directories),
             for: collectionID)
    }

    private static func fileURL(for collectionID: String) -> URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
        else { return nil }
        // A path makes a terrible filename; its hash makes a fine one.
        let name = String(format: "%016llx", UInt64(bitPattern: Int64(collectionID.stableHash)))
        return base
            .appendingPathComponent("ScanCheckpoints", isDirectory: true)
            .appendingPathComponent("\(name).json")
    }
}

private extension String {
    /// A stable hash across launches. `Hashable` is deliberately *not* stable —
    /// Swift seeds it per process — so using it for a filename would orphan every
    /// checkpoint on relaunch, which is precisely when they are needed.
    var stableHash: Int {
        var hash: UInt64 = 0xcbf29ce484222325            // FNV-1a
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(bitPattern: UInt(truncatingIfNeeded: hash))
    }
}
