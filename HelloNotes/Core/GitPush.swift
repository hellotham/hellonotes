//
//  GitPush.swift
//  HelloNotes
//
//  A push that stops when its task is cancelled.
//
//  SwiftGitX's `push()` ends in `git_remote_push(remote, nil, nil)` — no
//  options, so no progress callback, and nothing through which a cancel can
//  reach libgit2. Its *clone* installs `transfer_progress` and answers
//  `Task.isCancelled` there, which is why Clone has had a working Stop while
//  Push spun on `isBusy` until the network gave up (and why Create's Stop could
//  stop everything but the push it ends in). This is the same push — the
//  current branch, to its upstream's remote or else `origin`, with a push
//  refspec for the branch added when there is none — written against libgit2
//  itself, with callbacks that answer "stop" once the task is cancelled.
//
//  libgit2 is SwiftGitX's own dependency, pinned to exactly one version, so the
//  module is always there to import. What a callback cannot stop is a connect
//  that never completes: libgit2 calls nothing while it waits for a socket, so
//  a cancel lands when the connection opens or times out. Everything after —
//  the pack being built, sent and the references updated — stops at the next
//  callback.
//

import Foundation
import libgit2

nonisolated enum GitPush {

    enum Failure: Error, Equatable, LocalizedError {
        /// HEAD is not on a branch, so there is nothing to push.
        case detachedHead
        /// Neither the branch's upstream nor `origin` names a remote.
        case noRemote
        /// The task was cancelled and libgit2 stopped at a callback.
        case cancelled
        /// What libgit2 said.
        case libgit2(String)

        var errorDescription: String? {
            switch self {
            case .detachedHead: "Not on a branch — check out a branch to push."
            case .noRemote: "No remote to push to — add one named “origin”."
            case .cancelled: "Push cancelled."
            case .libgit2(let message): message
            }
        }
    }

    /// Push the current branch of the repository at `url`.
    ///
    /// Synchronous and blocking, like every libgit2 call: run it detached, and
    /// cancel *that* task to stop it.
    static func push(repositoryAt url: URL) throws {
        git_libgit2_init()
        defer { git_libgit2_shutdown() }

        var repository: OpaquePointer?
        try check(git_repository_open(&repository, url.path))
        defer { git_repository_free(repository) }

        var head: OpaquePointer?
        try check(git_repository_head(&head, repository))
        defer { git_reference_free(head) }
        guard git_reference_is_branch(head) == 1, let name = git_reference_name(head) else {
            throw Failure.detachedHead
        }
        let branch = String(cString: name)

        // The upstream's remote, else `origin` — SwiftGitX's rule.
        var remoteName = "origin"
        var upstream = git_buf()
        if git_branch_upstream_remote(&upstream, repository, branch) == 0, let ptr = upstream.ptr {
            remoteName = String(cString: ptr)
        }
        git_buf_dispose(&upstream)

        var remote: OpaquePointer?
        guard git_remote_lookup(&remote, repository, remoteName) == 0 else { throw Failure.noRemote }
        if !hasPushRefspec(remote, for: branch) {
            git_remote_free(remote)
            remote = nil
            try check(git_remote_add_push(repository, remoteName, "\(branch):\(branch)"))
            // Looked up again: the refspec was added to the configuration, not
            // to the remote already loaded.
            guard git_remote_lookup(&remote, repository, remoteName) == 0 else { throw Failure.noRemote }
        }
        defer { git_remote_free(remote) }

        var options = git_push_options()
        try check(git_push_options_init(&options, UInt32(GIT_PUSH_OPTIONS_VERSION)))
        // Every callback a push makes, answering "stop" once cancelled: the
        // pack being built, sent, and what the server says as it goes. The pack
        // is built on this thread (`pb_parallelism` left at its default of
        // one), because a callback on one of libgit2's own threads has no task
        // to ask whether it was cancelled.
        options.callbacks.pack_progress = { _, _, _, _ in Task.isCancelled ? -1 : 0 }
        options.callbacks.push_transfer_progress = { _, _, _, _ in Task.isCancelled ? -1 : 0 }
        options.callbacks.sideband_progress = { _, _, _ in Task.isCancelled ? -1 : 0 }

        let status = git_remote_push(remote, nil, &options)
        // Checked whatever the status: a callback's "stop" comes back as an
        // error, and a cancel that landed after the last callback still means
        // the person asked for it to stop — but only if it did not finish.
        if status != 0, Task.isCancelled { throw Failure.cancelled }
        try check(status)
    }

    /// Does `remote` already push `branch` somewhere?
    private static func hasPushRefspec(_ remote: OpaquePointer?, for branch: String) -> Bool {
        let count = git_remote_refspec_count(remote)
        for index in 0..<count {
            guard let refspec = git_remote_get_refspec(remote, index) else { continue }
            if git_refspec_direction(refspec) == GIT_DIRECTION_PUSH,
               git_refspec_src_matches(refspec, branch) == 1 {
                return true
            }
        }
        return false
    }

    private static func check(_ status: Int32) throws {
        guard status < 0 else { return }
        if let error = git_error_last(), let message = error.pointee.message {
            throw Failure.libgit2(String(cString: message))
        }
        throw Failure.libgit2("libgit2 error \(status)")
    }
}
