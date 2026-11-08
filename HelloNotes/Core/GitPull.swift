//
//  GitPull.swift
//  HelloNotes
//
//  Bring the remote's commits into the collection: fetch, then fast-forward —
//  or, when both sides have commits of their own, merge them, if nothing
//  conflicts.
//
//  The Git pane offered Push and Fetch, and Fetch moved only the remote's
//  branch inside `.git`: nothing of what had been pushed from another device
//  ever reached the notes, and there was no way in the app to make it (the
//  person, 2026-11-07: "there seems to be no way to manipulate git
//  collection, ie. pull latest version"). SwiftGitX has no merge, so this is
//  written against libgit2 itself, as `GitPush` and `GitFetch` are.
//
//  **A pull refuses before it writes.** The merge is worked out in memory
//  (`git_merge_commits`), so the same part of a file changed on both sides
//  stops it before anything is written — no conflict markers in a note, no
//  half-merged repository to clean up; changes to different parts of a file
//  are merged, as Git merges them. What it brings is then checked out the
//  safe way, which refuses before writing anything if it would write over a
//  change not yet committed, and only after that does the branch move.
//  Uncommitted changes to files the pull does not touch are left as they are.
//  A step that fails once the checkout has written is `Failure.partlyWritten`,
//  which says so (implemented.md §51.72).
//
//  Blocking, like every libgit2 call: run it on a thread of its own
//  (`GitThread.run`). The fetch stops at its next callback once cancelled, as
//  `GitFetch` says; the merge and checkout after it are local, and a cancel
//  that lands before them stops the pull with nothing changed.
//

import Foundation
import libgit2

nonisolated enum GitPull {

    /// What a pull did.
    enum Outcome: Equatable, Sendable {
        /// The remote had nothing this copy did not.
        case upToDate
        /// The remote's commits were added on top, `commits` of them.
        case fastForwarded(commits: Int)
        /// Both sides had commits; the remote's `commits` were merged with these.
        case merged(commits: Int)
    }

    enum Failure: Error, Equatable, LocalizedError, CustomStringConvertible {
        /// HEAD is not on a branch, so there is nothing to pull into.
        case detachedHead
        /// The branch has no counterpart on the remote.
        case noUpstream(branch: String)
        /// The same part of a file changed both here and on the remote —
        /// nothing was changed.
        case conflicts([String])
        /// The pull would write over changes not yet committed — nothing was
        /// changed.
        case uncommittedChanges([String])
        /// The task was cancelled before the pull changed anything.
        case cancelled
        /// The notes were written and a later step failed, so the branch did
        /// not move: what was written is in the folder, not committed.
        case partlyWritten(String)
        /// What libgit2 said.
        case libgit2(String)

        var errorDescription: String? {
            switch self {
            case .detachedHead:
                "Not on a branch — check out a branch to pull."
            case .noUpstream(let branch):
                "“\(branch)” has no branch on the remote to pull from."
            case .conflicts(let paths):
                "Nothing was pulled: \(Self.naming(paths)) changed both here and on the remote."
            case .uncommittedChanges(let paths):
                "Nothing was pulled: it would write over changes to \(Self.naming(paths)) that aren’t committed — commit them first."
            case .cancelled:
                "Pull cancelled."
            case .partlyWritten(let message):
                "The pull wrote its files but couldn’t finish — they’re in the folder, uncommitted: \(message)"
            case .libgit2(let message):
                message
            }
        }

        var description: String { errorDescription ?? "Pull failed." }

        /// “Note.md”, or “Note.md” and 3 more.
        private static func naming(_ paths: [String]) -> String {
            guard let first = paths.first else { return "files" }
            let name = "“\((first as NSString).lastPathComponent)”"
            return paths.count == 1 ? name : "\(name) and \(paths.count - 1) more"
        }
    }

    /// Pull the current branch of the repository at `url` from its upstream —
    /// the branch it tracks, or else the remote's branch of the same name on
    /// `origin`. Blocking: run it on a thread of its own (`GitThread.run`),
    /// and cancel the task waiting on it to stop it. A merge commit is signed
    /// with the repository's `user.name` and `user.email`
    /// (`GitService.ensureCommitIdentity` sets them first).
    static func pull(repositoryAt url: URL, cancel: GitCancel) throws -> Outcome {
        do {
            try GitFetch.fetch(repositoryAt: url, cancel: cancel)
        } catch where cancel.isSet {
            // Stopped while fetching, the part Stop is for: the pull's own
            // cancel — the fetch's, passed up, was shown as a failure (§51.72).
            throw Failure.cancelled
        }
        guard !cancel.isSet else { throw Failure.cancelled }

        git_libgit2_init()
        defer { git_libgit2_shutdown() }

        var repository: OpaquePointer?
        try check(git_repository_open(&repository, url.path))
        defer { git_repository_free(repository) }

        // The branch, born or not: a repository made here and never committed
        // to has a HEAD that names a branch that does not exist yet.
        var head: OpaquePointer?
        let headStatus = git_repository_head(&head, repository)
        defer { git_reference_free(head) }
        let branchRef: String
        if headStatus == GIT_EUNBORNBRANCH.rawValue {
            branchRef = try unbornBranch(of: repository)
        } else {
            try check(headStatus)
            guard git_reference_is_branch(head) == 1, let name = git_reference_name(head) else {
                throw Failure.detachedHead
            }
            branchRef = String(cString: name)
        }
        let branch = String(branchRef.dropFirst("refs/heads/".count))

        var upstream: OpaquePointer?
        if head == nil || git_branch_upstream(&upstream, head) != 0 {
            guard git_reference_lookup(&upstream, repository, "refs/remotes/origin/\(branch)") == 0 else {
                throw Failure.noUpstream(branch: branch)
            }
        }
        defer { git_reference_free(upstream) }

        var theirs: OpaquePointer?
        try check(git_annotated_commit_from_ref(&theirs, repository, upstream))
        defer { git_annotated_commit_free(theirs) }
        var theirOid = git_annotated_commit_id(theirs).pointee

        var analysis = git_merge_analysis_t(rawValue: 0)
        var preference = git_merge_preference_t(rawValue: 0)
        var heads: [OpaquePointer?] = [theirs]
        try check(git_merge_analysis(&analysis, &preference, repository, &heads, 1))
        let found = analysis.rawValue

        if found & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0 { return .upToDate }

        if head == nil || found & GIT_MERGE_ANALYSIS_UNBORN.rawValue != 0 {
            // Nothing here yet: the remote's branch, as it is.
            try checkOut(theirOid, in: repository)
            var made: OpaquePointer?
            try afterWriting { try check(git_reference_create(&made, repository, branchRef, &theirOid, 0, "pull: initial")) }
            git_reference_free(made)
            return .fastForwarded(commits: commitCount(of: theirOid, in: repository))
        }

        var ourOid = git_reference_target(head).pointee
        var ahead = 0, behind = 0
        try check(git_graph_ahead_behind(&ahead, &behind, repository, &ourOid, &theirOid))

        if found & GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue != 0 {
            try checkOut(theirOid, in: repository)
            try afterWriting { try move(head, to: &theirOid, message: "pull: fast-forward") }
            return .fastForwarded(commits: behind)
        }

        guard found & GIT_MERGE_ANALYSIS_NORMAL.rawValue != 0 else {
            throw Failure.libgit2("This branch and the remote’s can’t be merged.")
        }
        var merge = try mergeCommit(ours: &ourOid, theirs: &theirOid,
                                    message: "Merge remote-tracking branch '\(shorthand(of: upstream))'",
                                    in: repository)
        try checkOut(merge, in: repository)
        try afterWriting { try move(head, to: &merge, message: "pull: merge") }
        return .merged(commits: behind)
    }

    /// The branch an unborn HEAD names — `refs/heads/main` in a repository
    /// made here and never committed to.
    private static func unbornBranch(of repository: OpaquePointer?) throws -> String {
        var symbolic: OpaquePointer?
        try check(git_reference_lookup(&symbolic, repository, "HEAD"))
        defer { git_reference_free(symbolic) }
        guard let target = git_reference_symbolic_target(symbolic) else { throw Failure.detachedHead }
        return String(cString: target)
    }

    /// `origin/main`, for the merge commit's message.
    private static func shorthand(of reference: OpaquePointer?) -> String {
        git_reference_shorthand(reference).map { String(cString: $0) } ?? "upstream"
    }

    /// The commits reachable from `oid`, for a branch pulled into an empty
    /// repository.
    private static func commitCount(of oid: git_oid, in repository: OpaquePointer?) -> Int {
        var walker: OpaquePointer?
        guard git_revwalk_new(&walker, repository) == 0 else { return 0 }
        defer { git_revwalk_free(walker) }
        var start = oid
        guard git_revwalk_push(walker, &start) == 0 else { return 0 }
        var next = git_oid()
        var count = 0
        while git_revwalk_next(&next, walker) == 0 { count += 1 }
        return count
    }

    /// The merge of `theirs` into `ours`, worked out in memory and committed —
    /// with no branch moved, so a merge that is refused below changes nothing.
    private static func mergeCommit(ours: inout git_oid, theirs: inout git_oid, message: String,
                                    in repository: OpaquePointer?) throws -> git_oid {
        var ourCommit: OpaquePointer?, theirCommit: OpaquePointer?
        try check(git_commit_lookup(&ourCommit, repository, &ours))
        defer { git_commit_free(ourCommit) }
        try check(git_commit_lookup(&theirCommit, repository, &theirs))
        defer { git_commit_free(theirCommit) }

        var index: OpaquePointer?
        try check(git_merge_commits(&index, repository, ourCommit, theirCommit, nil))
        defer { git_index_free(index) }
        if git_index_has_conflicts(index) == 1 { throw Failure.conflicts(conflictedPaths(in: index)) }

        var treeOid = git_oid()
        try check(git_index_write_tree_to(&treeOid, index, repository))
        var tree: OpaquePointer?
        try check(git_tree_lookup(&tree, repository, &treeOid))
        defer { git_tree_free(tree) }

        var signature: UnsafeMutablePointer<git_signature>?
        try check(git_signature_default(&signature, repository))
        defer { git_signature_free(signature) }

        var merged = git_oid()
        var parents: [OpaquePointer?] = [ourCommit, theirCommit]
        try check(git_commit_create(&merged, repository, nil, signature, signature, "UTF-8", message,
                                    tree, 2, &parents))
        return merged
    }

    /// The paths a merge left in conflict.
    private static func conflictedPaths(in index: OpaquePointer?) -> [String] {
        var iterator: OpaquePointer?
        guard git_index_conflict_iterator_new(&iterator, index) == 0 else { return [] }
        defer { git_index_conflict_iterator_free(iterator) }
        var paths: [String] = []
        var ancestor: UnsafePointer<git_index_entry>?
        var ours: UnsafePointer<git_index_entry>?
        var theirs: UnsafePointer<git_index_entry>?
        while git_index_conflict_next(&ancestor, &ours, &theirs, iterator) == 0 {
            if let entry = ours ?? theirs ?? ancestor, let path = entry.pointee.path {
                paths.append(String(cString: path))
            }
        }
        return paths
    }

    /// Make the working tree and index `oid`'s tree — the safe way, which
    /// refuses before writing anything if it would write over a change not yet
    /// committed, and leaves alone changes to files it does not touch.
    private static func checkOut(_ oid: git_oid, in repository: OpaquePointer?) throws {
        var oid = oid
        var commit: OpaquePointer?
        try check(git_commit_lookup(&commit, repository, &oid))
        defer { git_commit_free(commit) }

        let refused = RefusedPaths()
        var options = git_checkout_options()
        try check(git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        options.notify_flags = GIT_CHECKOUT_NOTIFY_CONFLICT.rawValue
        options.notify_cb = { _, path, _, _, _, payload in
            if let path, let payload {
                Unmanaged<RefusedPaths>.fromOpaque(payload).takeUnretainedValue().paths.append(String(cString: path))
            }
            return 0
        }
        let status = withExtendedLifetime(refused) {
            options.notify_payload = Unmanaged.passUnretained(refused).toOpaque()
            return git_checkout_tree(repository, commit, &options)
        }
        if status == GIT_ECONFLICT.rawValue { throw Failure.uncommittedChanges(refused.paths) }
        // Any other failure can come partway, after some files are written.
        try afterWriting { try check(status) }
    }

    /// A step taken once notes may have been written: what fails there failed
    /// with the folder changed, and says so (`Failure.partlyWritten`), so the
    /// collection reads its folder again — on iOS nothing else would hear
    /// libgit2's writes (implemented.md §51.72).
    private static func afterWriting(_ step: () throws -> Void) throws {
        do { try step() } catch {
            throw Failure.partlyWritten((error as? Failure)?.description ?? error.localizedDescription)
        }
    }

    /// The paths a safe checkout would not write over, as it names them.
    private final class RefusedPaths: @unchecked Sendable {
        var paths: [String] = []
    }

    /// Move the branch `head` to `oid`.
    private static func move(_ head: OpaquePointer?, to oid: inout git_oid, message: String) throws {
        var moved: OpaquePointer?
        try check(git_reference_set_target(&moved, head, &oid, message))
        git_reference_free(moved)
    }

    private static func check(_ status: Int32) throws {
        guard status < 0 else { return }
        if let error = git_error_last(), let message = error.pointee.message {
            throw Failure.libgit2(String(cString: message))
        }
        throw Failure.libgit2("libgit2 error \(status)")
    }
}
