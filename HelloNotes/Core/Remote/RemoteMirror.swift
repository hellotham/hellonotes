//
//  RemoteMirror.swift
//  HelloNotes
//
//  Created by Chris Tham on 21/7/2026.
//
//  Bridges a `RemoteStore` (Dropbox, …) into the app's filesystem-based
//  `Collection` model so a cloud account can be a *first-class collection* in the
//  sidebar. It mirrors the remote folder into a local cache directory; that cache
//  is opened as an ordinary `Collection`, so every existing surface — scan,
//  index, backlinks, the editor, `FileIO` — works unchanged.
//
//  Changes made here go back to the provider, one at a time and in the order
//  they were made (`sendSave`, `sendMove`, `sendDelete`, `sendFolder`): a
//  save is uploaded, a note made here is created there, a rename or a move is
//  a move there, a folder made here is made there. Walks of the provider's
//  folder take their turns among them. The manifest is the provider's record —
//  what it has, and where — so it changes as each change is made *there*.
//

import Foundation
import Synchronization

/// Live counts while a remote folder is being mirrored, so the UI can show what
/// is happening instead of an unexplained wait.
///
/// `nonisolated`, like the two below: a walk counts and reports them away from
/// the main actor (`RemoteMirror.walkProvider`).
nonisolated struct RemoteSyncProgress: Sendable, Equatable {
    var foldersListed = 0
    /// Files given a name and a place in the tree, whose content is fetched when
    /// something asks for it.
    var filesMirrored = 0
    /// The folder or note currently being fetched, for a status line.
    var currentPath = ""
}

/// One item the sync could not fetch. Recorded and reported rather than thrown,
/// so a single unreadable folder doesn't cost the user everything else.
nonisolated struct RemoteSyncFailure: Sendable, Equatable {
    var path: String
    var message: String
}

/// What a sync actually achieved.
///
/// `isComplete` is the important field: it is true **only** when the entire
/// remote tree was listed without cancellation or failure. Anything that
/// deletes local state must consult it — a partial pass has not seen the whole
/// remote folder, so a note "missing" from it may simply live in a subtree the
/// walk never reached.
nonisolated struct RemoteSyncOutcome: Sendable, Equatable {
    var progress = RemoteSyncProgress()
    var failures: [RemoteSyncFailure] = []
    var isComplete = false
}

final class RemoteMirror {
    let store: RemoteStore
    /// Local cache directory that stands in for the remote folder.
    let cacheRoot: URL
    /// Provider-absolute path of the mirrored folder ("" = provider root).
    let remoteRoot: String
    /// Shown in the sidebar (the remote folder's name, or the provider name at root).
    let displayName: String

    init(store: RemoteStore, cacheRoot: URL, remoteRoot: String, displayName: String) {
        self.store = store
        self.cacheRoot = cacheRoot
        self.remoteRoot = DropboxPath.normalize(remoteRoot)
        self.displayName = displayName
    }

    // MARK: - One mirror per cache

    /// The mirrors alive now, by cache, held weakly: a mirror goes when its
    /// collection and its last turn have.
    private static var live: [String: WeakMirror] = [:]

    private final class WeakMirror {
        weak var mirror: RemoteMirror?
        init(_ mirror: RemoteMirror) { self.mirror = mirror }
    }

    /// The mirror of the cache at `cacheRoot`: the one already open on it for
    /// this account and folder, or a new one. Never two. Adding a cloud folder
    /// that is already open made a second mirror of the same cache: each kept
    /// its own record and its own turns, the two wrote over each other's
    /// manifest, and a walk by the second could not see the changes still
    /// waiting in the first.
    /// `manifest`, when the caller has read it already — off the main actor,
    /// as a launch does — is the mirror's from the start, rather than read and
    /// decoded again on the main actor at its first use (implemented.md §51.36).
    static func open(store: RemoteStore, cacheRoot: URL, remoteRoot: String, displayName: String,
                     manifest: RemoteManifest? = nil) -> RemoteMirror {
        let key = cacheRoot.standardizedFileURL.path
        if let mirror = live[key]?.mirror,
           mirror.store.providerName == store.providerName, mirror.store.accountID == store.accountID,
           mirror.remoteRoot == DropboxPath.normalize(remoteRoot) {
            return mirror
        }
        let mirror = RemoteMirror(store: store, cacheRoot: cacheRoot, remoteRoot: remoteRoot, displayName: displayName)
        if let manifest { mirror.loadedManifest = manifest }
        live[key] = WeakMirror(mirror)
        return mirror
    }

    // MARK: - Path mapping

    /// The local cache URL for a provider-absolute path.
    func localURL(forRemotePath path: String) -> URL {
        let p = DropboxPath.normalize(path)
        var rel = p
        if !remoteRoot.isEmpty, p.hasPrefix(remoteRoot) {
            rel = String(p.dropFirst(remoteRoot.count))
        }
        rel = rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
        return cacheRoot.appendingPathComponent(rel)
    }

    /// The provider-absolute path for a local cache URL.
    func remotePath(forLocalURL url: URL) -> String {
        remotePath(forRelative: Self.relativePath(of: url, in: cacheRoot))
    }

    /// The provider-absolute path for a cache-relative one — by the formula a
    /// walk lists by (`RemoteTreeSource.remotePath(forRelative:)`), so a path
    /// recorded here is the path the next walk sees.
    func remotePath(forRelative relative: String) -> String {
        Self.remotePath(forRelative: relative, under: remoteRoot)
    }

    /// The same, for a walk away from the main actor (`WalkFindings`).
    nonisolated static func remotePath(forRelative relative: String, under remoteRoot: String) -> String {
        guard !relative.isEmpty else { return remoteRoot }
        return remoteRoot.isEmpty ? "/" + relative : remoteRoot + "/" + relative
    }

    // MARK: - Sync


    /// Upload a file saved here to the provider — outside the turns, for a
    /// caller that has made sure nothing else is changing it. The collection
    /// goes through `sendSave`.
    func upload(localURL url: URL, data: Data? = nil) async throws {
        try await upload(relative: Self.relativePath(of: url, in: cacheRoot), data: data)
    }

    /// A file's turn to go up.
    ///
    /// **One the provider has:** before writing, the provider's current
    /// revision is compared with the one recorded when this copy was fetched.
    /// If they differ the file changed elsewhere while we held it, and
    /// overwriting would destroy that change — so **both versions are kept**:
    /// the local edit stays where it is, and the provider's copy is saved
    /// beside it as a conflicted copy. The provider arbitrates by revision
    /// rather than by timestamp on purpose: comparing modification dates across
    /// devices means trusting two clocks to agree, which is exactly the weak
    /// point of every sync tool that does it.
    ///
    /// **One made here** — a new note, a copy, the conflicted copy an editor
    /// keeps — has no record: as far as this cache knows the provider has never
    /// had it. The folders above it the provider lacks are made first, the
    /// name is checked — another device may have put a file there since this
    /// cache last looked, and that is kept too — and the file is written and
    /// recorded, so it is an ordinary note from then on. It was refused, as
    /// though it were a placeholder, at every save.
    ///
    /// - Parameter given: what the save wrote. Sent as it was saved, whatever
    ///   has happened to the file since — a rename taking its turn after this
    ///   one has already moved it here. Without it the file is read now, and
    ///   one gone by now is skipped: whatever took it has a turn of its own.
    private func upload(relative: String, data given: Data?) async throws {
        let url = cacheRoot.appending(path: relative)
        let name = url.lastPathComponent
        if let misplaced = manifest.entries[relative], !misplaced.isDirectory, isMisplaced(misplaced, at: relative) {
            await reconcileName(of: relative)
        }
        let known = manifest.entries[relative]
        if let known {
            guard !known.isDirectory else { return }
            // **Never upload a file we never downloaded.** A placeholder is a
            // zero-byte stand-in for the provider's note; written back, it
            // would replace that note with nothing.
            guard known.hydrated else {
                throw RemoteMirrorError.notDownloaded(name: name, provider: store.providerName)
            }
            if let rev = known.rev, let live = try? await currentRevision(of: known.remotePath), live != rev {
                try await preserveConflict(remotePath: known.remotePath, localURL: url)
                // Adopt the revision we just diverged from, so the next save is
                // a clean write rather than an endless conflict.
                var current = manifest
                current.entries[relative]?.rev = live
                manifest = current
                throw RemoteMirrorError.conflict(name: name)
            }
        } else {
            try await createFolders(above: relative)
        }

        let data: Data
        if let given {
            data = given
        } else {
            guard let read = try await offMain({ try Self.readIfPresent(url) }) else { return }
            data = read
        }
        let target = known?.remotePath ?? remotePath(forRelative: relative)

        if known == nil, let theirs = try await providerEntry(at: target), !theirs.isDirectory {
            // The same bytes: this upload already happened, and its answer was
            // lost on the way back. Recorded, and nothing written.
            if theirs.size == data.count, (try? await store.read(path: target)) == data {
                record(.init(remotePath: target, isDirectory: false, size: data.count,
                             modified: theirs.modified, rev: theirs.rev, hydrated: true), at: relative)
                return
            }
            try await preserveConflict(remotePath: target, localURL: url)
            // Theirs is beside mine now; mine takes the name with its next
            // save, as after any conflict — and until then mine is here alone.
            record(.init(remotePath: target, isDirectory: false, size: theirs.size,
                         modified: theirs.modified, rev: theirs.rev, hydrated: true, unsent: true),
                   at: relative)
            throw RemoteMirrorError.madeElsewhereToo(name: name, provider: store.providerName)
        }

        try await store.write(data, to: target)
        let written = try? await providerEntry(at: target)
        record(.init(remotePath: target, isDirectory: false, size: data.count,
                     modified: written?.modified ?? Date(), rev: written?.rev, hydrated: true), at: relative)
    }

    /// The provider's revision for `remotePath`, or nil if it can't be read.
    private func currentRevision(of remotePath: String) async throws -> String? {
        try await providerEntry(at: remotePath)?.rev
    }

    /// What the provider has at `remotePath` now — nil for nothing there, or
    /// for a folder that is not there either (a 404, or Dropbox's 409
    /// `path/not_found`).
    private func providerEntry(at remotePath: String) async throws -> RemoteEntry? {
        let entries: [RemoteEntry]
        do {
            entries = try await store.list(path: RemoteBrowserModel.parent(of: remotePath))
        } catch RemoteStoreError.http(let code, _) where code == 404 || code == 409 {
            return nil
        }
        let wanted = DropboxPath.normalize(remotePath)
        return entries.first { DropboxPath.normalize($0.path) == wanted }
    }

    /// Save the provider's version alongside the local one, so neither is
    /// lost — and on the provider too. Mine takes the name there with its next
    /// save, and theirs kept on this device alone would be theirs lost
    /// everywhere else. If that upload fails the copy stays here, and goes up
    /// with the next refresh (`sendUnsent`).
    private func preserveConflict(remotePath: String, localURL url: URL) async throws {
        let theirs = try await store.read(path: remotePath)
        // Never over a file already there: it wrote a same-day name blind, so
        // a second conflict replaced the first's copy — or the copy of mine an
        // editor keeps beside a note with a conflict open.
        let copy = try FileIO.createConflictedCopy(beside: url, holding: theirs)
        try? await upload(relative: Self.relativePath(of: copy, in: cacheRoot), data: theirs)
    }

    /// `entry` as the manifest's record of `relative`, in the manifest as it is
    /// now — after whatever the awaits before it let happen.
    private func record(_ entry: RemoteManifest.Entry, at relative: String) {
        var current = manifest
        current.entries[relative] = entry
        manifest = current
        // A file made here waits no more once the provider's record has it.
        waitingToGo.cameUp(relative)
    }

    /// The file's bytes, or nil when it has gone.
    nonisolated private static func readIfPresent(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try FileIO.readData(at: url)
    }

    // MARK: - Metadata-first mirroring

    /// The cache's record of the remote folder. Loaded lazily; empty until the
    /// first metadata sync.
    private var loadedManifest: RemoteManifest?

    var manifest: RemoteManifest {
        get {
            if let loadedManifest { return loadedManifest }
            let loaded = RemoteManifest.load(fromCacheRoot: cacheRoot)
                ?? RemoteManifest(provider: store.providerName,
                                  accountID: store.accountID,
                                  remoteRoot: remoteRoot,
                                  displayName: displayName)
            loadedManifest = loaded
            return loaded
        }
        set {
            loadedManifest = newValue
            // Written away from the main actor, newest first (`ManifestWriter`).
            ManifestWriter.for(cacheRoot).save(newValue)
        }
    }

    /// Mirror the remote folder's **shape** — folders and placeholder files —
    /// without downloading a single byte of content.
    ///
    /// This is what makes a cloud root usable at all. The eager sync it
    /// replaced (deleted with its last caller) fetched every note, which is fine for a notes vault and hopeless for an account
    /// of any size; and it skipped non-Markdown files entirely, so a folder of
    /// PDFs mirrored to an empty collection. Here every file gets a real name at
    /// a real path immediately, and its content arrives when something actually
    /// needs it.
    ///
    /// Runs on the shared `ResumableTreeWalk`, so it is incremental,
    /// cancellable, resumable and per-directory fault-isolated for free — and
    /// in its turn among the changes made here: after every one asked for
    /// before it, and before any asked for while it walks.
    @discardableResult
    func syncMetadata(
        progress report: @escaping @Sendable (RemoteSyncProgress) -> Void = { _ in }
    ) async throws -> RemoteSyncOutcome {
        try await inTurn { [weak self] in
            guard let self else { return RemoteSyncOutcome() }
            return try await self.walk(progress: report)
        }
    }

    /// One walk of the provider's folder, applied to the manifest.
    ///
    /// **Walked away from the main actor** (`walkProvider`), and applied on
    /// it. The walk itself is the listings and, per file, a path worked out,
    /// the record looked up and up to three syscalls; it ran on the main
    /// thread, because this method is the mirror's and `ResumableTreeWalk.run`
    /// is a plain `nonisolated async` function, which runs where its caller
    /// is. Mirroring 2,000 files cost 0.97 s of main-thread CPU, and no
    /// warning said so. What stays here is the snapshot it starts from and the
    /// record it ends with — dictionary work, at the scale of what changed.
    ///
    /// **Applied to the manifest as it is when the walk ends, not as it was
    /// when it began.** A note is opened — downloaded — while a walk is under
    /// way, and a walk of a large account takes a while. The walk wrote back
    /// the record it started with, which still said "placeholder": the note's
    /// saves were refused from then on, and its next open downloaded it again
    /// over whatever was typed. An entry that changed here meanwhile is newer
    /// than anything the walk saw, and is kept.
    ///
    /// **What a change made here is waiting to take away is left alone** —
    /// the old path of a note renamed or moved here, a note deleted here —
    /// while the provider still lists it: a walk put it back, as a placeholder
    /// under the old name, beside the note that had moved.
    private func walk(
        progress report: @escaping @Sendable (RemoteSyncProgress) -> Void
    ) async throws -> RemoteSyncOutcome {
        let began = Date()
        let before = manifest
        let walked = try await Self.walkProvider(
            before: before, store: store, cacheRoot: cacheRoot, remoteRoot: remoteRoot,
            waiting: waitingToGo, progress: report)

        var outcome = RemoteSyncOutcome()
        outcome.progress = walked.findings.progress
        outcome.failures = walked.result.issues.map { RemoteSyncFailure(path: $0.path, message: $0.message) }
        outcome.isComplete = walked.result.isComplete

        var current = manifest
        // Not over a record that changed here since the walk began, nor at a
        // path a change made here has claimed since the walk listed it — a
        // note made under a name the walk had just seen on the provider.
        for (relative, entry) in walked.findings.found
        where current.entries[relative] == before.entries[relative] && !isWaitingToGo(relative) {
            current.entries[relative] = entry
        }
        var gone: [String] = []
        // Only an authoritative pass may delete — the same rule that protects a
        // cancelled local walk, and the one a delta must also respect — and
        // only what the provider stopped having: a record the walk did not
        // list, unchanged here since it began, and not waiting on a change made
        // here. A note made here has no record, so it is never among them; and
        // one with changes here the provider never received loses its record
        // but keeps its file, which goes up again as made here.
        if walked.result.isComplete {
            for (relative, entry) in walked.findings.unlisted
            where current.entries[relative] == entry && !isWaitingToGo(relative) {
                current.entries.removeValue(forKey: relative)
                if entry.unsent != true { gone.append(relative) }
            }
            if current.deltaCursor == nil { current.deltaCursor = walked.cursor }
            current.lastCompleteSync = Date()
        }
        current.lastRefresh = Date()
        manifest = current
        if !gone.isEmpty {
            let root = cacheRoot
            // `[gone]`: the list as it stands, not the variable — a `var`
            // captured by concurrently running code is a race the compiler can
            // only warn about here.
            await offMain { [gone] in Self.removeLocalItems(gone, in: root, unchangedSince: began) }
        }
        return outcome
    }

    /// The walk itself — every listing, and per file its record worked out and
    /// its folder or placeholder made here — away from the main actor.
    ///
    /// `@concurrent` is what moves it: called from the mirror's turn, a plain
    /// `nonisolated async` function would run on the main actor, as
    /// `ResumableTreeWalk.run` did. The cursor a complete walk takes is asked
    /// here too — before `walk` reads the record back, so no await falls
    /// between that and writing it.
    @concurrent
    nonisolated private static func walkProvider(
        before: RemoteManifest, store: RemoteStore, cacheRoot: URL, remoteRoot: String,
        waiting: WaitingToGo, progress report: @escaping @Sendable (RemoteSyncProgress) -> Void
    ) async throws -> (findings: WalkFindings, result: WalkResult, cursor: String?) {
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        var findings = WalkFindings(before: before, cacheRoot: cacheRoot, remoteRoot: remoteRoot, waiting: waiting)
        // One recursive listing for the whole tree where the provider has one,
        // consulted by every `children(of:)` below. The walk is unchanged — it
        // simply stops paying a round trip per folder. See
        // `RecursiveListingCache`.
        let source = RemoteTreeSource(
            store: store, remoteRoot: remoteRoot, cacheRoot: cacheRoot,
            prefetch: RecursiveListingCache(store: store, root: remoteRoot))
        let result = await ResumableTreeWalk.run(source: source) { batch in
            findings.add(batch)
            report(findings.progress)
        }
        if result.isComplete { findings.noteWhatWasNotListed() }

        // Take a cursor while we are here. A full sync has just seen the whole
        // folder, so "everything up to now" is exactly what it describes — and
        // acquiring it costs one metadata request instead of making the first
        // refresh re-list the folder purely to find its place.
        let cursor = result.isComplete && before.deltaCursor == nil
            ? try? await store.latestCursor(path: remoteRoot) : nil
        return (findings, result, cursor)
    }

    /// What one walk found, gathered away from the main actor and applied to
    /// the manifest on it (`walk`).
    ///
    /// `nonisolated` because it is nested in a main-actor class, which would
    /// otherwise make it main-actor too and pull the walk that calls `add` per
    /// directory back onto the main thread — `Collection.ScanAccumulator`'s
    /// trap, and the header of `ResumableTreeWalk.swift`.
    nonisolated struct WalkFindings: Sendable {
        /// The record as the walk began.
        let before: [String: RemoteManifest.Entry]
        let cacheRoot: URL
        let remoteRoot: String
        let waiting: WaitingToGo
        /// Records whose move the provider refused, by the provider path they
        /// hold — usually none. What the walk lists there is theirs, not a new
        /// file to record and give a placeholder under the old name.
        let claimed: Set<String>

        /// What the walk found that the record does not already say, by path
        /// here: the rest it would only write back as it was, and applying
        /// every listed item cost the main actor 10 ms at 20,000 files with
        /// nothing changed (the review of implemented.md §51.34).
        private(set) var found: [String: RemoteManifest.Entry] = [:]
        /// Provider paths listed — by path, not by place here: a record whose
        /// move the provider refused has its item at a path its place here does
        /// not name, and was taken for one the provider stopped having.
        private(set) var listed = Set<String>()
        /// The records whose provider paths the walk did not list, once it has
        /// listed everything (`noteWhatWasNotListed`).
        private(set) var unlisted: [String: RemoteManifest.Entry] = [:]
        private(set) var progress = RemoteSyncProgress()
        /// Counted once and then kept, rather than recounted per directory.
        /// `entries.values.count(where:)` walked the *whole* manifest on every
        /// batch, so a folder with D directories and E entries did D×E work for
        /// a number that changes by one at a time — quadratic in the size of
        /// the thing being synced, on the sync's own hot path.
        private var fileCount: Int

        init(before: RemoteManifest, cacheRoot: URL, remoteRoot: String, waiting: WaitingToGo) {
            self.before = before.entries
            self.cacheRoot = cacheRoot
            self.remoteRoot = remoteRoot
            self.waiting = waiting
            claimed = Set(before.entries.filter { RemoteMirror.isMisplaced($0.value, at: $0.key, under: remoteRoot) }
                .map { DropboxPath.normalize($0.value.remotePath) })
            fileCount = before.entries.values.count { !$0.isDirectory }
        }

        /// One directory's listing.
        mutating func add(_ batch: WalkBatch) {
            let waiting = self.waiting
            for child in batch.children {
                let relative = RemoteMirror.relativePath(of: child.url, in: cacheRoot)
                let remotePath = RemoteMirror.remotePath(forRelative: relative, under: remoteRoot)
                let remote = DropboxPath.normalize(remotePath)
                listed.insert(remote)
                guard !claimed.contains(remote) else { continue }
                // Asked and written under the lock a change made here is
                // reported under: the batch used to run whole on the main
                // actor, where no change could be reported between the
                // question and the write, and this keeps that true off it.
                waiting.unlessWaiting(relative) { take(child, at: relative, remotePath: remotePath) }
            }
            progress.foldersListed = batch.progress.directoriesVisited
            progress.filesMirrored = fileCount
            progress.currentPath = batch.directory
        }

        /// One listed item: its record, and its folder or placeholder here.
        private mutating func take(_ child: TreeChild, at relative: String, remotePath: String) {
            let fm = FileManager.default
            let existing = before[relative]
            let wasFile = existing.map { !$0.isDirectory } ?? false
            // Mine, not yet on the provider: left for the upload, whose own
            // check keeps both when the provider's copy changed meanwhile. The
            // walk made it a placeholder again — the save waiting its turn was
            // refused as one, and the next open downloaded theirs over it.
            if existing?.unsent == true { return }
            // Mine is owed a rename the provider refused because this name was
            // taken there — by this, another item. Recorded over mine, mine
            // would open theirs and save over it.
            if let existing, RemoteMirror.isMisplaced(existing, at: relative, under: remoteRoot) { return }

            if child.isDirectory {
                try? fm.createDirectory(at: child.url, withIntermediateDirectories: true)
                let entry = RemoteManifest.Entry(remotePath: remotePath, isDirectory: true)
                if entry != existing { found[relative] = entry }
                if wasFile { fileCount -= 1 }
                return
            }
            // A file here with no record and something in it was made here — a
            // note made while the provider could not be reached, whose name
            // another device has used since. Its upload meets theirs and keeps
            // both; recorded here as their placeholder, it was refused,
            // skipped, and downloaded over.
            if existing == nil, RemoteMirror.holdsContent(child.url) { return }
            // A note already downloaded stays downloaded — unless the provider
            // says it changed, or the download is no longer here.
            let hydrated = (existing?.hydrated ?? false) && Self.isUnchanged(existing, listed: child)
                && fm.fileExists(atPath: child.url.path)
            let entry = RemoteManifest.Entry(
                remotePath: remotePath,
                isDirectory: false,
                size: child.size,
                modified: child.modified,
                rev: child.rev,
                hydrated: hydrated)
            if entry != existing { found[relative] = entry }
            if !wasFile { fileCount += 1 }
            // Only where there is no file: never over a download that landed
            // while the walk was under way, nor a note saved here meanwhile.
            // The walk used to ask the record too, which away from the main
            // actor it cannot; whatever changes the record during a walk
            // leaves a file here, or is reported before it goes (`WaitingToGo`).
            if !hydrated { RemoteMirror.writePlaceholder(at: child.url) }
        }

        /// Whether the provider's item is the one the record describes
        /// (`RemoteMirror.isSameRevision`). With nothing to compare, a walk took
        /// every download for changed and made it a placeholder again, its
        /// bytes left in place: a note open in an editor had its saves refused,
        /// and opening it again downloaded the provider's copy over what was
        /// typed.
        static func isUnchanged(_ record: RemoteManifest.Entry?, listed child: TreeChild) -> Bool {
            guard let record else { return false }
            return RemoteMirror.isSameRevision(record, rev: child.rev, size: child.size, modified: child.modified)
        }

        /// What the walk did not list, out of the record it began with — asked
        /// only of a walk that listed everything.
        mutating func noteWhatWasNotListed() {
            let listed = self.listed
            unlisted = before.filter { !listed.contains(DropboxPath.normalize($0.value.remotePath)) }
        }
    }

    /// The paths a change made here owns until its turn: what a move or a
    /// delete will take away, and what a file made here will bring up —
    /// shared with a walk away from the main actor.
    ///
    /// A change is reported **before** its file changes — `willMove`,
    /// `willMake`, and `sendDelete(of:removing:failed:)`, which removes the
    /// file itself — and a walk asks about each file it lists, and writes that
    /// file's folder or placeholder, under this lock. So a walk that finds a
    /// path not waiting finds its file where it was, and writes nothing over
    /// it (a placeholder never replaces a file); one that finds it waiting
    /// passes it over. When the walk's batch ran whole on the main actor,
    /// nothing could be reported between the question and the write; the lock
    /// keeps that so.
    ///
    /// What goes away is worked out once each time the changes waiting do
    /// (`pending`): a walk asks about every file it lists, and following each
    /// question back through every waiting change was quadratic in them —
    /// 152 ms a 2,000-file batch with 50 moves waiting. What comes up is a file
    /// made here with no record yet — reported before it exists, and taken off
    /// when a record of it is written (`record`): until then a walk or a
    /// refresh that found the provider had an item of that name took the new,
    /// empty note for the provider's placeholder (implemented.md §51.36).
    nonisolated final class WaitingToGo: Sendable {
        nonisolated private struct Paths: Sendable {
            var goingAway: Set<String> = []
            var comingUp: Set<String> = []
        }

        private let paths = Mutex(Paths())

        func replace(with sources: Set<String>) {
            paths.withLock { $0.goingAway = sources }
        }

        /// `relative`, made here, waits to go up.
        func comingUp(_ relative: String) {
            paths.withLock { _ = $0.comingUp.insert(relative) }
        }

        /// `relative`, and anything under it, waits no more: recorded, or gone.
        func cameUp(_ relative: String) {
            paths.withLock { paths in
                paths.comingUp = paths.comingUp.filter { $0 != relative && !$0.hasPrefix(relative + "/") }
            }
        }

        /// A file made here moved before it went up: it waits under its new path.
        func moveComingUp(from: String, to: String) {
            paths.withLock { paths in
                paths.comingUp = Set(paths.comingUp.map {
                    $0 == from || $0.hasPrefix(from + "/") ? to + $0.dropFirst(from.count) : $0
                })
            }
        }

        /// Whether `recorded` — or a folder it is in — is waiting on a change
        /// made here.
        func contains(_ recorded: String) -> Bool {
            paths.withLock { Self.covers($0, recorded) }
        }

        /// `body`, unless `recorded` is waiting on a change made here — run
        /// under the lock, so no change is reported while it runs. Returns
        /// whether it ran.
        @discardableResult
        func unlessWaiting(_ recorded: String, _ body: () -> Void) -> Bool {
            paths.withLock { paths in
                guard !Self.covers(paths, recorded) else { return false }
                body()
                return true
            }
        }

        private static func covers(_ paths: Paths, _ recorded: String) -> Bool {
            if paths.comingUp.contains(recorded) { return true }
            guard !paths.goingAway.isEmpty else { return false }
            var path = Substring(recorded)
            while true {
                if paths.goingAway.contains(String(path)) { return true }
                guard let slash = path.lastIndex(of: "/") else { return false }
                path = path[..<slash]
            }
        }
    }

    /// The local files of records the provider stopped having, and their
    /// folders once empty — deepest first, away from the main actor, and never
    /// a file changed since the walk began: a note made at that path meanwhile
    /// is not the one the provider deleted.
    nonisolated private static func removeLocalItems(_ relatives: [String], in root: URL, unchangedSince began: Date) {
        let fm = FileManager.default
        for relative in relatives.sorted(by: { $0.split(separator: "/").count > $1.split(separator: "/").count }) {
            let url = root.appending(path: relative)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                if (try? fm.contentsOfDirectory(atPath: url.path))?.isEmpty == true { try? fm.removeItem(at: url) }
            } else {
                let changed = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard (changed ?? .distantPast) < began else { continue }
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Whether a file is here with something in it — not missing, and not a
    /// zero-byte stand-in.
    nonisolated private static func holdsContent(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0
    }

    /// Bring the cache up to date with the provider, in its turn.
    ///
    /// Uses the provider's own delta feed when it has one — one request for
    /// "everything since this cursor" instead of re-walking a tree that may be
    /// thousands of listings — and falls back to a full metadata sync otherwise,
    /// or when the provider says the cursor has expired.
    ///
    /// **A delta may never prune.** It reports what changed, not what exists, so
    /// an item absent from it is simply an item that did not change. Deletions
    /// come from the feed's own explicit list; anything else is only removed by
    /// a complete `syncMetadata`.
    @discardableResult
    func refresh() async throws -> RemoteSyncOutcome {
        try await inTurn { [weak self] in
            guard let self else { return RemoteSyncOutcome() }
            return try await self.applyChanges()
        }
    }

    private func applyChanges() async throws -> RemoteSyncOutcome {
        // **No cursor, no delta: a walk.** A cursor is taken only at the end
        // of a complete walk, so its absence says no walk has listed the whole
        // folder yet — one stopped short by a folder the provider refused, an
        // add cancelled, a quit — and only a walk can finish the job. Asked
        // for changes with no cursor, Dropbox and OneDrive answered with every
        // entry, applied one by one on the main actor (0.32 s for 2,000), and
        // Box and Drive with a position and nothing in it, which was kept: the
        // folder the walk missed was never listed, and the next refresh,
        // holding a cursor, recorded a complete walk that never happened
        // (implemented.md §51.36). A walk runs off the main actor, prunes only
        // when complete, and takes its own cursor when it is.
        guard let cursor = manifest.deltaCursor else { return try await walk(progress: { _ in }) }
        guard let delta = try await store.changes(since: cursor, path: remoteRoot) else {
            return try await walk(progress: { _ in })
        }
        if delta.requiresFullResync {
            var current = manifest
            current.deltaCursor = nil
            manifest = current
            return try await walk(progress: { _ in })
        }

        // Read after the request: a download may have landed while it was out.
        var current = manifest
        let source = RemoteTreeSource(store: store, remoteRoot: remoteRoot, cacheRoot: cacheRoot)
        var outcome = RemoteSyncOutcome()
        // Records whose move the provider refused, by the provider path they
        // hold (see `walk`).
        let claimed = Dictionary(current.entries.filter { isMisplaced($0.value, at: $0.key) }
            .map { (DropboxPath.normalize($0.value.remotePath), $0.key) }, uniquingKeysWith: { first, _ in first })

        for entry in delta.changed {
            let url = source.cacheURL(forRemotePath: entry.path)
            let relative = Self.relativePath(of: url, in: cacheRoot)
            guard !relative.isEmpty, !isWaitingToGo(relative),
                  claimed[DropboxPath.normalize(entry.path)] == nil else { continue }
            if entry.isDirectory {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                current.entries[relative] = RemoteManifest.Entry(remotePath: entry.path, isDirectory: true)
                continue
            }
            let existing = current.entries[relative]
            // Mine not yet sent, mine owed a rename to this name, or a file
            // made here under it: left alone, as a walk leaves them (`walk`).
            if existing?.unsent == true { continue }
            if let existing, isMisplaced(existing, at: relative) { continue }
            if existing == nil, Self.holdsContent(url) { continue }
            let unchanged = existing.map {
                Self.isSameRevision($0, rev: entry.rev, size: entry.size, modified: entry.modified)
            } ?? false
            current.entries[relative] = RemoteManifest.Entry(
                remotePath: entry.path,
                isDirectory: false,
                size: entry.size,
                modified: entry.modified,
                rev: entry.rev,
                hydrated: (existing?.hydrated ?? false) && unchanged)
            if !unchanged { Self.writePlaceholder(at: url) }
        }

        for path in delta.deleted {
            // Deleted elsewhere while this device holds it under a name the
            // provider refused: the record goes, and the file here goes up
            // again under its new name, as made here.
            if let holder = claimed[DropboxPath.normalize(path)] {
                current.entries.removeValue(forKey: holder)
                continue
            }
            let url = source.cacheURL(forRemotePath: path)
            let relative = Self.relativePath(of: url, in: cacheRoot)
            guard !relative.isEmpty, !isWaitingToGo(relative) else { continue }
            // Only what the provider had, and this item of it: a file here it
            // never had is one made here, under a name that was also someone
            // else's; a record owed a rename to this name holds another item.
            // And not mine unsent: its record goes, its file stays and goes up
            // as made here.
            guard let entry = current.entries[relative],
                  DropboxPath.normalize(entry.remotePath).lowercased() == DropboxPath.normalize(path).lowercased()
            else { continue }
            current.entries.removeValue(forKey: relative)
            if entry.unsent != true { try? FileManager.default.removeItem(at: url) }
        }

        // Holding a cursor proves a walk listed the whole folder — the record
        // a manifest written before `lastCompleteSync` does not have, and
        // without which nothing made here offline would ever be sent
        // (`sendUnsent`).
        if current.lastCompleteSync == nil { current.lastCompleteSync = Date() }
        current.deltaCursor = delta.cursor
        current.lastRefresh = Date()
        manifest = current

        outcome.isComplete = true
        outcome.progress.filesMirrored = current.entries.values.count { !$0.isDirectory }
        return outcome
    }

    /// Fetch one file's real content and mark it hydrated.
    ///
    /// Idempotent, so the editor can call it unconditionally on open. Asked of
    /// a note at its path here, which a move still waiting its turn has not
    /// yet made its path on the provider: fetched from where the provider has
    /// it.
    func hydrate(localURL url: URL) async throws {
        let local = Self.relativePath(of: url, in: cacheRoot)
        // A few tries, for a note that keeps changing on the provider while
        // its bytes are on their way; past them it is left a placeholder.
        for _ in 0..<3 {
            let recorded = recordedPath(of: local)
            guard let entry = manifest.entries[recorded], !entry.isDirectory, !entry.hydrated else { return }

            let data = try await store.read(path: entry.remotePath)
            // **Staged off the main actor**, and put in place by one rename
            // once the checks below have passed: the write is the download's
            // size, and it was made here, on the main actor (implemented.md
            // §51.36). A staged file not put in place is removed.
            let staged = try await offMain { try FileIO.stage(data, for: url) }
            defer { try? FileManager.default.removeItem(at: staged) }
            // Still this note, here? The bytes are written only where the note
            // is now — at `local`, with no move or delete made here since
            // taking it elsewhere — over its stand-in, and never over mine
            // unsent. An open begun under a name the note left while its bytes
            // were on their way wrote them there, recorded the download, and
            // the record — moved with the rename — called the empty placeholder
            // at the new name the note: it opened empty, and its first save put
            // that over the provider's copy.
            let now = recordedPath(of: local)
            guard let still = manifest.entries[now], !still.isDirectory, !still.hydrated, still.unsent != true,
                  currentPath(ofRecorded: now) == local,
                  FileManager.default.fileExists(atPath: url.path) else { return }
            // And still the revision that was read. A walk that recorded a
            // newer one while the bytes were on their way left the older bytes
            // marked as the newer, and the next save passed the conflict check
            // and wrote over the provider's newer copy (implemented.md §51.36).
            guard Self.sameRevision(still, entry) else { continue }
            try FileIO.putInPlace(staged, at: url)
            var current = manifest
            current.entries[now]?.hydrated = true
            manifest = current
            return
        }
    }

    /// Whether two records of one item describe the same revision of it
    /// (`isSameRevision`).
    nonisolated static func sameRevision(_ a: RemoteManifest.Entry, _ b: RemoteManifest.Entry) -> Bool {
        guard DropboxPath.normalize(a.remotePath) == DropboxPath.normalize(b.remotePath) else { return false }
        return isSameRevision(a, rev: b.rev, size: b.size, modified: b.modified)
    }

    /// Whether the provider's item, as listed, is the revision a record
    /// describes: by the provider's revision when both name one, and otherwise
    /// by size and date. Both sides need one — a record written before a
    /// provider's listing named revisions has none, and comparing it with the
    /// first listing that does called every download changed (implemented.md
    /// §51.36).
    nonisolated static func isSameRevision(_ record: RemoteManifest.Entry, rev: String?, size: Int,
                                           modified: Date?) -> Bool {
        if let recorded = record.rev, let listed = rev { return recorded == listed }
        return record.size == size && record.modified == modified
    }

    /// Whether the file at `url` holds its content — every file but a
    /// placeholder. A note made here is its own content: this said "no" for
    /// one, as it does for a stand-in, and the app offered to download it and
    /// counted it among the notes a search could not see.
    func isHydrated(localURL url: URL) -> Bool {
        !isPlaceholder(localURL: url)
    }

    /// Whether the file at `url` is a stand-in: a file the manifest knows, whose
    /// content has not been fetched — or has been dropped again (eviction). Not
    /// simply "the manifest says it is not downloaded", which is also true of a
    /// path it has never seen, such as a note just created here; that file is
    /// its own content.
    func isPlaceholder(localURL url: URL) -> Bool {
        guard let entry = manifest.entries[recordedPath(of: Self.relativePath(of: url, in: cacheRoot))]
        else { return false }
        return !entry.isDirectory && !entry.hydrated
    }

    /// Cache-relative paths whose content has not been fetched, for the scan —
    /// at their paths here, where a move still waiting its turn has put them.
    var dehydratedRelativePaths: Set<String> {
        guard !pending.isEmpty else { return manifest.dehydratedPaths }
        return Set(manifest.dehydratedPaths.compactMap(currentPath(ofRecorded:)))
    }

    /// `dehydratedRelativePaths` when only this mirror's state can answer it —
    /// a move or delete waiting, which renames records — and `nil` when the
    /// manifest alone can, so a scan folds it off the main actor
    /// (implemented.md §51.36).
    var dehydratedRelativePathsIfMoving: Set<String>? {
        pending.isEmpty ? nil : dehydratedRelativePaths
    }

    /// A zero-byte stand-in, so the file exists at its real path with its real
    /// name. **Never** written over a file that already has content: the whole
    /// hydration gate exists to keep a placeholder from being mistaken for an
    /// empty note.
    /// One stat instead of three.
    ///
    /// This runs once per file in the folder, so its cost is multiplied by the
    /// thing that makes a large folder large. It used to ask the file system
    /// three separate questions — a `resourceValues` for the size, a
    /// `createDirectory` for a parent the walk had already created moments
    /// earlier, and a `fileExists` for what the first call had already
    /// established. In the common case — a re-sync, where every file is already
    /// there — that is three syscalls per note to decide to do nothing.
    ///
    /// `nonisolated`: a walk writes these away from the main actor
    /// (`WalkFindings`). And made by an exclusive open, which fails when
    /// something is already there: `createFile` replaces a file, so a note
    /// moved or saved to this name between the check and the write — a moment
    /// the walk shares with the rest of the app — would have been emptied.
    nonisolated private static func writePlaceholder(at url: URL) {
        let fm = FileManager.default
        // Present either way — non-empty means hydrated, empty means the
        // placeholder is already there — and neither needs writing.
        guard !fm.fileExists(atPath: url.path) else { return }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: url, options: .withoutOverwriting)
    }

    /// `nonisolated`: the scan's accumulator calls this for every file of a
    /// mirrored collection from off the main actor, and as a main-actor method
    /// of this class each of those calls hopped to the main thread and back.
    nonisolated static func relativePath(of url: URL, in root: URL) -> String {
        let full = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        guard full.hasPrefix(base) else { return url.lastPathComponent }
        var relative = String(full.dropFirst(base.count))
        while relative.hasPrefix("/") { relative.removeFirst() }
        return relative
    }

    // MARK: - Changes made here

    /// The provider's turns: every change made here, and every walk of the
    /// provider's folder, one after another in the order they were asked for.
    ///
    /// **In order, because each change assumes the ones before it.** A note is
    /// made, named — a rename — and saved, all within a second; the save
    /// uploaded before the rename had its turn would have left the provider
    /// holding the note under both names, and two saves of one note in flight
    /// at once each checked the provider's revision against the one recorded
    /// before either landed, so the second took the first for a change made
    /// elsewhere. A walk takes its turn among them for the same reason: it
    /// reads the record they write.
    private var turns: Task<Void, Never>?

    /// A turn for `work`, after every one asked for before it.
    private func send(_ work: @escaping @MainActor () async -> Void) {
        let previous = turns
        turns = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// A turn for `work`, and what it made. Cancelling the caller cancels the
    /// work — a walk stops where it is, incomplete, as it always did.
    private func inTurn<T: Sendable>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = turns
        let task = Task { @MainActor () async throws -> T in
            await previous?.value
            return try await work()
        }
        turns = Task { @MainActor in _ = try? await task.value }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Every turn asked for so far, taken: each change made on the provider,
    /// or failed and reported.
    func changesSent() async {
        while let last = turns {
            await last.value
            if turns == last { return }
        }
    }

    /// A move or a delete made here whose turn on the provider has not come —
    /// handed back by `willMove`, so the collection can report a move before
    /// the file moves.
    struct PendingChange {
        let id = UUID()
        /// The item's path here when it was moved or deleted.
        let source: String
        /// Where it went — nil, deleted.
        let destination: String?
    }

    /// Oldest first. Until a move's turn comes, the manifest — the provider's
    /// record — still has the item under its old path, so a question about it
    /// at its new path is asked of the old one (`recordedPath`), and a walk
    /// still listing the old path leaves it alone (`isWaitingToGo`).
    private var pending: [PendingChange] = [] {
        didSet { waitingToGo.replace(with: Self.recordedSources(of: pending)) }
    }

    /// The manifest's paths the waiting changes will take away, shared with a
    /// walk away from the main actor (`WaitingToGo`).
    let waitingToGo = WaitingToGo()

    private static func recordedSources(of pending: [PendingChange]) -> Set<String> {
        Set(pending.indices.map { recorded(pending[$0].source, through: pending[..<$0]) })
    }

    /// `relative` followed back through the moves in `changes`, newest first.
    private static func recorded(_ relative: String, through changes: ArraySlice<PendingChange>) -> String {
        var path = relative
        for change in changes.reversed() {
            guard let destination = change.destination else { continue }
            if path == destination {
                path = change.source
            } else if path.hasPrefix(destination + "/") {
                path = change.source + path.dropFirst(destination.count)
            }
        }
        return path
    }

    /// The manifest's path for what is at `relative` here: followed back through
    /// every move still waiting, newest first.
    private func recordedPath(of relative: String) -> String {
        pending.isEmpty ? relative : Self.recorded(relative, through: pending[...])
    }

    /// Where an item the manifest records is here now — the other way — or nil
    /// when a delete made here is waiting to take it away.
    private func currentPath(ofRecorded relative: String) -> String? {
        guard !pending.isEmpty else { return relative }
        var path = relative
        for change in pending {
            let covers = path == change.source || path.hasPrefix(change.source + "/")
            guard covers else { continue }
            guard let destination = change.destination else { return nil }
            path = destination + path.dropFirst(change.source.count)
        }
        return path
    }

    /// Whether a move or a delete made here is waiting its turn to take the
    /// item the manifest records at `recorded` — or a folder it is in — away.
    func isWaitingToGo(_ recorded: String) -> Bool {
        waitingToGo.contains(recorded)
    }

    private func settle(_ change: PendingChange) {
        pending.removeAll { $0.id == change.id }
    }

    /// A file saved here — a note, a copy, an attachment — up in its turn:
    /// an ordinary upload for a file the provider has, the first for one made
    /// here (see `upload(relative:data:)`). `data` is what the save wrote;
    /// without it the file is read when its turn comes.
    ///
    /// Marked unsent at once, if the provider has it: from now until an upload
    /// lands, the file here holds something the provider has not — which
    /// trimming the cache, a walk and a download must all leave alone.
    func sendSave(of url: URL, data: Data?, failed: @escaping @MainActor (Error) -> Void) {
        let relative = Self.relativePath(of: url, in: cacheRoot)
        let recorded = recordedPath(of: relative)
        if let entry = manifest.entries[recorded] {
            if !entry.isDirectory, entry.hydrated, entry.unsent != true {
                var current = manifest
                current.entries[recorded]?.unsent = true
                manifest = current
            }
        } else {
            // Made here, and not yet on the provider: it waits to go up, and a
            // walk passes it over until its upload records it (`willMake`).
            waitingToGo.comingUp(relative)
        }
        send { [weak self] in
            guard let self else { return }
            do { try await self.upload(relative: relative, data: data) } catch { failed(error) }
        }
    }

    /// A move about to be made here, reported **before the file moves**: a walk
    /// under way that listed the old name in the moment between — the file
    /// gone from it, the move not yet reported — took the note for a
    /// placeholder that had lost its file and put an empty one back there.
    /// Hand the result to `sendMove` once the file has moved, or to `cancel`
    /// if it did not.
    func willMove(from source: URL, to destination: URL) -> PendingChange? {
        let from = Self.relativePath(of: source, in: cacheRoot)
        let to = Self.relativePath(of: destination, in: cacheRoot)
        guard from != to else { return nil }
        let change = PendingChange(source: from, destination: to)
        pending.append(change)
        // Made here and not yet up: it waits under the name it is going to.
        waitingToGo.moveComingUp(from: from, to: to)
        return change
    }

    /// The file did not move: nothing to take to the provider.
    func cancel(_ change: PendingChange) {
        if let destination = change.destination {
            waitingToGo.moveComingUp(from: destination, to: change.source)
        }
        settle(change)
    }

    /// A file about to be made here — reported **before it exists**, as a move
    /// is (`willMove`). Until its upload's turn records it, it has no record,
    /// and a walk or a refresh that found the provider had an item of the same
    /// name — two devices' "Untitled", today's daily note made on the phone —
    /// took the new, empty note for the provider's placeholder: its uploads
    /// were refused as never downloaded, and opening it, as the refusal
    /// advises, downloaded the provider's file over what was typed. Waiting,
    /// it is passed over (`WaitingToGo`); its upload finds the provider's item
    /// at the name and keeps both. Hand the same URL to `cancelMaking` if the
    /// file could not be made.
    func willMake(_ url: URL) {
        waitingToGo.comingUp(Self.relativePath(of: url, in: cacheRoot))
    }

    /// The file was not made: nothing waits to go up.
    func cancelMaking(_ url: URL) {
        waitingToGo.cameUp(Self.relativePath(of: url, in: cacheRoot))
    }

    /// Moved here — renamed, or put in another folder — and moved on the
    /// provider in its turn: one call, which keeps the item's history there,
    /// rather than an upload under the new name and a delete of the old.
    /// Nothing is downloaded; a placeholder moves as one.
    func sendMove(_ change: PendingChange, failed: @escaping @MainActor (Error) -> Void) {
        send { [weak self] in
            guard let self else { return }
            do { try await self.move(change) } catch { failed(error) }
            self.settle(change)
        }
    }

    /// Deleted here — by `remove`, run once the delete is reported — and on
    /// the provider in its turn, if the provider ever had it. A note made here
    /// and never sent is nobody else's, and a name it shares with one made
    /// elsewhere since is not this note.
    ///
    /// **Reported before the file goes**, as a move is (`willMove`). The file
    /// went first and the report after it, which was safe only while a walk's
    /// batch ran on the main actor, where nothing came between the two; a walk
    /// away from it that found the file gone and no delete waiting put an
    /// empty placeholder back at the note's name, which went up again as a note
    /// made here. If `remove` throws, nothing is reported and the error is the
    /// caller's.
    ///
    /// `remove` runs away from the main actor: a folder to the Trash is a file
    /// at a time, and on iOS, where an app's folder has no Trash, a removal of
    /// each (87 ms for 2,000 notes, timed on the Mac by the review of §51.34).
    func sendDelete(of url: URL, removing remove: @escaping @Sendable () throws -> Void,
                    failed: @escaping @MainActor (Error) -> Void) async throws {
        let change = PendingChange(source: Self.relativePath(of: url, in: cacheRoot), destination: nil)
        pending.append(change)
        do {
            try await offMain(remove)
        } catch {
            settle(change)
            throw error
        }
        // Made here and never sent: gone before it went up.
        waitingToGo.cameUp(change.source)
        send { [weak self] in
            guard let self else { return }
            do { try await self.delete(change.source) } catch { failed(error) }
            self.settle(change)
        }
    }

    /// A folder made here, made on the provider in its turn.
    func sendFolder(_ url: URL, failed: @escaping @MainActor (Error) -> Void) {
        let relative = Self.relativePath(of: url, in: cacheRoot)
        send { [weak self] in
            guard let self else { return }
            do { try await self.createFolder(relative: relative) } catch { failed(error) }
        }
    }

    /// Everything here the provider has not received — a note made while it
    /// could not be reached, an edit whose upload failed, mine kept after a
    /// conflict, a picture pasted into a note — up in its turn: whatever the
    /// manifest has no record of, and every record marked unsent, once every
    /// change asked for before has had its own.
    ///
    /// Only after a walk has listed the whole folder: before that, a file here
    /// with no record may be one the provider has and the walk has not
    /// reached. A provider out of reach ends the round, reported once rather
    /// than per file; a clash with one item — a conflict, a name taken — is
    /// said, and the round goes on.
    func sendUnsent(failed: @escaping @MainActor (Error) -> Void) {
        send { [weak self] in
            guard let self, self.manifest.lastCompleteSync != nil else { return }
            // Every record's two paths normalised and compared: folded off the
            // main actor, from the manifest as it is now (implemented.md §51.36).
            let snapshot = self.manifest
            let remoteRoot = self.remoteRoot
            let misplaced = await offMain {
                snapshot.entries
                    .filter { Self.isMisplaced($0.value, at: $0.key, under: remoteRoot) }
                    .map(\.key)
                    .sorted { $0.split(separator: "/").count < $1.split(separator: "/").count }
            }
            for relative in misplaced { await self.reconcileName(of: relative) }
            let root = self.cacheRoot
            let items = await offMain { Self.items(under: root) }
            var round: [String] = self.manifest.entries
                .filter { !$0.value.isDirectory && $0.value.unsent == true }
                .map(\.key)
            var madeHere: String?
            for item in items {
                if let madeHere, item.relative.hasPrefix(madeHere + "/") { continue }
                guard self.manifest.entries[self.recordedPath(of: item.relative)] == nil else { continue }
                madeHere = item.relative
                round.append(item.relative)
            }
            for relative in round {
                do {
                    if self.manifest.entries[relative] != nil {
                        try await self.upload(relative: relative, data: nil)
                    } else {
                        try await self.sendMadeHere(relative: relative)
                    }
                } catch let error as RemoteMirrorError {
                    failed(error)
                } catch {
                    failed(error)
                    return
                }
            }
        }
    }

    /// The move's turn. `change.source` is the manifest's path for the item
    /// now: every change made before it has had its turn.
    private func move(_ change: PendingChange) async throws {
        guard let to = change.destination else { return }
        let from = change.source
        guard let item = manifest.entries[from] else {
            // Never on the provider — made here, and its upload failed or has
            // not been asked for: it goes up under its new name.
            settle(change)
            return try await sendMadeHere(relative: to)
        }
        let target = remotePath(forRelative: to)
        do {
            try await moveOnProvider(item.remotePath, to: target, named: to)
        } catch {
            // The provider kept it where it was; here it has moved all the
            // same. The record follows it, still naming where the provider has
            // it — so it is still the note: a placeholder opens from there, a
            // save writes there, and a later save or refresh asks for the move
            // again (`reconcileName`). Left under its old path, the record
            // made the empty placeholder at the new name a new, empty note —
            // opened blank, and uploaded as one.
            rekey(from: from, to: to, remotePath: nil)
            settle(change)
            throw error
        }
        rekey(from: from, to: to, remotePath: (from: item.remotePath, to: target))
        settle(change)
        // A provider may issue a moved file a revision of its own.
        if !item.isDirectory, let rev = try? await currentRevision(of: target) {
            var current = manifest
            if current.entries[to]?.remotePath == target {
                current.entries[to]?.rev = rev
                manifest = current
            }
        }
    }

    /// Move `source` to `target` on the provider — the folders above the
    /// target made first, and never over something already there: Dropbox and
    /// OneDrive refuse, Box may, and Drive keeps two items of one name. A
    /// change of case alone is the same item.
    private func moveOnProvider(_ source: String, to target: String, named relative: String) async throws {
        try await createFolders(above: relative)
        if source.lowercased() != target.lowercased(), try await providerEntry(at: target) != nil {
            throw RemoteMirrorError.nameTaken(name: (relative as NSString).lastPathComponent,
                                              provider: store.providerName)
        }
        try await store.move(from: source, to: target)
    }

    /// The record follows a move: every entry at or under `from` is at `to`
    /// now — and, when the provider made the move too, its provider path with
    /// it; nil keeps the path the provider still has it at.
    private func rekey(from: String, to: String, remotePath: (from: String, to: String)?) {
        var current = manifest
        let moving = current.entries.filter { $0.key == from || $0.key.hasPrefix(from + "/") }
        for key in moving.keys { current.entries.removeValue(forKey: key) }
        for (key, entry) in moving {
            var moved = entry
            if let remotePath,
               entry.remotePath == remotePath.from || entry.remotePath.hasPrefix(remotePath.from + "/") {
                moved.remotePath = remotePath.to + entry.remotePath.dropFirst(remotePath.from.count)
            }
            current.entries[to + key.dropFirst(from.count)] = moved
        }
        manifest = current
    }

    /// Whether the provider has this record's item at a path other than the
    /// one its place here names — a move it refused, not yet made again.
    private func isMisplaced(_ entry: RemoteManifest.Entry, at relative: String) -> Bool {
        Self.isMisplaced(entry, at: relative, under: remoteRoot)
    }

    /// The same, for a walk away from the main actor (`WalkFindings`).
    nonisolated static func isMisplaced(_ entry: RemoteManifest.Entry, at relative: String,
                                        under remoteRoot: String) -> Bool {
        DropboxPath.normalize(entry.remotePath)
            != DropboxPath.normalize(remotePath(forRelative: relative, under: remoteRoot))
    }

    /// Ask again for a move the provider refused: `relative`'s item, and all
    /// that is recorded under it, to where its place here says. Returns whether
    /// it is there now. A refusal again leaves the record as it was: the
    /// content is safe where the provider has it, and the next save or refresh
    /// asks once more.
    @discardableResult
    private func reconcileName(of relative: String) async -> Bool {
        guard let entry = manifest.entries[relative], isMisplaced(entry, at: relative) else { return true }
        let target = remotePath(forRelative: relative)
        guard (try? await moveOnProvider(entry.remotePath, to: target, named: relative)) != nil else { return false }
        let old = entry.remotePath
        var current = manifest
        for (key, value) in current.entries where value.remotePath == old || value.remotePath.hasPrefix(old + "/") {
            current.entries[key]?.remotePath = target + value.remotePath.dropFirst(old.count)
        }
        manifest = current
        return true
    }

    /// The delete's turn: forgotten, with everything under it, and deleted on
    /// the provider. Forgotten first — a delete that fails there leaves the
    /// provider's copy, which the next walk shows again, rather than a record
    /// of a download no longer here.
    private func delete(_ relative: String) async throws {
        guard let item = manifest.entries[relative] else { return }
        var current = manifest
        for key in current.entries.keys.filter({ $0 == relative || $0.hasPrefix(relative + "/") }) {
            current.entries.removeValue(forKey: key)
        }
        manifest = current
        try await store.delete(path: item.remotePath)
    }

    /// A folder's turn: the folders above it made first, then the folder.
    private func createFolder(relative: String) async throws {
        try await createFolders(above: relative)
        try await makeFolder(relative: relative)
    }

    /// The folders above `relative` the provider does not have — made here,
    /// never listed there — made there, top-down.
    private func createFolders(above relative: String) async throws {
        var missing: [String] = []
        var folder = (relative as NSString).deletingLastPathComponent
        while !folder.isEmpty, manifest.entries[folder]?.isDirectory != true {
            missing.append(folder)
            folder = (folder as NSString).deletingLastPathComponent
        }
        for folder in missing.reversed() { try await makeFolder(relative: folder) }
    }

    /// One folder, in a folder the provider has: made there — or, when it
    /// already has one of that name, taken as it is.
    private func makeFolder(relative: String) async throws {
        guard manifest.entries[relative]?.isDirectory != true else { return }
        let target = remotePath(forRelative: relative)
        if let there = try await providerEntry(at: target) {
            guard there.isDirectory else {
                throw RemoteMirrorError.nameTaken(name: (relative as NSString).lastPathComponent,
                                                  provider: store.providerName)
            }
        } else {
            try await store.createFolder(path: target)
        }
        record(.init(remotePath: target, isDirectory: true), at: relative)
    }

    /// Up to the provider, an item made here that it has never had: a file
    /// uploaded; a folder made, and what is in it with it.
    private func sendMadeHere(relative: String) async throws {
        let url = cacheRoot.appending(path: relative)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        guard isDirectory.boolValue else { return try await upload(relative: relative, data: nil) }
        try await createFolder(relative: relative)
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for child in children {
            let path = relative + "/" + child.lastPathComponent
            if manifest.entries[path] == nil { try await sendMadeHere(relative: path) }
        }
    }

    /// Everything in the cache, top-down, as cache-relative paths — the
    /// manifest and other hidden files left out.
    nonisolated private static func items(under root: URL) -> [(relative: String, isDirectory: Bool)] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        var items: [(relative: String, isDirectory: Bool)] = []
        for case let url as URL in walker {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            items.append((relativePath(of: url, in: root), isDirectory))
        }
        return items
    }

    // MARK: - Bounding the cache

    /// How much downloaded content a mirror may hold before the least recently
    /// used bodies are dropped back to placeholders.
    ///
    /// A lazy cache that never lets go is only a slower version of downloading
    /// everything: open enough of a large account and you have mirrored it in
    /// full. Evicting costs nothing but a re-download on next open, which is the
    /// same cost the file had before it was ever opened.
    // `nonisolated`: a constant, and `evictIfNeeded`'s default argument —
    // which Swift 5 mode evaluates outside the main actor.
    nonisolated static let defaultCacheLimit = 256 * 1024 * 1024      // 256 MB

    /// This mirror's limit — `defaultCacheLimit`, unless a test needs a cache
    /// that is full after a note or two.
    var cacheLimit = RemoteMirror.defaultCacheLimit

    /// Total bytes of hydrated content.
    var hydratedBytes: Int {
        manifest.entries.values.reduce(0) { $0 + ($1.hydrated && !$1.isDirectory ? $1.size : 0) }
    }

    /// Drop least-recently-opened content until the cache fits `limit`.
    ///
    /// "Least recently used" is the filesystem's own access time, so a note read
    /// five minutes ago outranks one opened a month ago without the mirror having
    /// to keep its own log. `keeping` is never evicted — it is what the user is
    /// looking at.
    @discardableResult
    func evictIfNeeded(limit: Int = RemoteMirror.defaultCacheLimit,
                       keeping pinned: Set<String> = []) async -> Int {
        guard hydratedBytes > limit else { return 0 }
        let candidates = manifest.entries
            .filter { !$0.value.isDirectory && $0.value.hydrated && !pinned.contains($0.key) }
            .map(\.key)
        // **Each download's last use read off the main actor** — a stat per
        // download in the cache, which ran here (implemented.md §51.36).
        let root = cacheRoot
        let oldestFirst = await offMain {
            candidates.map { (path: $0, used: Self.lastUsed(root.appending(path: $0))) }
                .sorted { $0.used < $1.used }
                .map(\.path)
        }

        // The eviction itself is made here, each candidate asked again first
        // and no await between the asking and the write: a save landing
        // between the two would be emptied.
        var current = manifest
        var total = hydratedBytes
        var evicted = 0
        for path in oldestFirst where total > limit {
            guard let entry = current.entries[path], !entry.isDirectory, entry.hydrated,
                  // Nor one holding something the provider never received —
                  // mine kept after a conflict, an edit whose upload failed.
                  // Dropped back to a placeholder, it was gone everywhere.
                  entry.unsent != true, !pinned.contains(path),
                  // Not one a move or delete made here is still taking away:
                  // its record is under a path it no longer has here, and
                  // "evicting" it wrote an empty file back at that path.
                  !isWaitingToGo(path), currentPath(ofRecorded: path) == path
            else { continue }
            let url = cacheRoot.appending(path: path)
            // Back to a placeholder rather than gone: the name must stay, or the
            // note would vanish from the collection entirely.
            guard (try? Data().write(to: url, options: .atomic)) != nil else { continue }
            current.entries[path]?.hydrated = false
            total -= entry.size
            evicted += 1
        }
        if evicted > 0 { manifest = current }
        return evicted
    }

    private nonisolated static func lastUsed(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey])
        return values?.contentAccessDate ?? values?.contentModificationDate ?? .distantPast
    }

    // MARK: - Cache location

    /// A stable per-provider/per-folder cache directory in Application Support
    /// (not Caches — the system may purge Caches, and this is the working copy).
    static func cacheDirectory(provider: String, folder: String) -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let safeFolder = folder.isEmpty ? "root" : folder
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return base
            .appendingPathComponent("RemoteMirror", isDirectory: true)
            .appendingPathComponent(provider.lowercased(), isDirectory: true)
            .appendingPathComponent(safeFolder.isEmpty ? "root" : safeFolder, isDirectory: true)
    }
}

enum RemoteMirrorError: LocalizedError {
    case conflict(name: String)
    /// A file made here under a name another device gave one of its own since
    /// this cache last looked.
    case madeElsewhereToo(name: String, provider: String)
    case notDownloaded(name: String, provider: String)
    /// Something is already at the name a move or a new folder wants.
    case nameTaken(name: String, provider: String)

    var errorDescription: String? {
        switch self {
        case .conflict(let name):
            return "“\(name)” also changed on the provider. Your version is kept here, "
                 + "and theirs was saved beside it as a conflicted copy."
        case .madeElsewhereToo(let name, let provider):
            return "“\(name)” was also made on \(provider). Yours is kept here, "
                 + "and theirs was saved beside it as a conflicted copy."
        case .notDownloaded(let name, let provider):
            return "“\(name)” hasn't been downloaded from \(provider) yet, so it wasn't uploaded. Open it first."
        case .nameTaken(let name, let provider):
            return "\(provider) already has something named “\(name)” there."
        }
    }
}

/// Small Dropbox-style path helpers (shared with DropboxStore's conventions).
/// `nonisolated`: a walk normalises every path it lists, away from the main
/// actor.
nonisolated enum DropboxPath {
    static func normalize(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespaces)
        if p == "/" || p.isEmpty { return "" }
        if !p.hasPrefix("/") { p = "/" + p }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
