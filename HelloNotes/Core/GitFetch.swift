//
//  GitFetch.swift
//  HelloNotes
//
//  A clone and a fetch that stop when asked, on a thread of their own.
//
//  SwiftGitX's clone answered "stop" from its transfer-progress callback by
//  asking `Task.isCancelled`, which means nothing on a thread that is not a
//  task's; and its fetch gave libgit2 no options at all, so nothing could stop
//  it. These are the same clone — libgit2's defaults and a safe checkout — and
//  the same fetch — from the current branch's upstream's remote, else `origin`,
//  by its configured refspecs — written against libgit2 itself, as `GitPush`
//  is, with callbacks that read the waiting task's flag (`GitCancel`). Like a
//  push, what they cannot stop is a connection that is open and silent:
//  libgit2 calls nothing while it waits on a socket (`GitPush`), so a cancel
//  lands when the server answers or the connection ends. A clone's checkout,
//  once the transfer is done, is not stopped either, as SwiftGitX's was not.
//

import Foundation
import libgit2

nonisolated enum GitFetch {

    enum Failure: Error, Equatable, LocalizedError, CustomStringConvertible {
        /// Neither the branch's upstream nor `origin` names a remote.
        case noRemote
        /// The task was cancelled and libgit2 stopped at a callback.
        case cancelled
        /// What libgit2 said.
        case libgit2(String)

        var errorDescription: String? {
            switch self {
            case .noRemote: "No remote to fetch from — add one named “origin”."
            case .cancelled: "Cancelled."
            case .libgit2(let message): message
            }
        }

        var description: String { errorDescription ?? "Git failed." }
    }

    /// Clone `remoteURL` into `localURL`. Synchronous and blocking, like every
    /// libgit2 call: run it on a thread of its own (`GitThread.run`), and
    /// cancel the task waiting on it to stop it.
    static func clone(from remoteURL: URL, to localURL: URL, cancel: GitCancel) throws {
        git_libgit2_init()
        defer { git_libgit2_shutdown() }

        var options = git_clone_options()
        try check(git_clone_options_init(&options, UInt32(GIT_CLONE_OPTIONS_VERSION)))
        options.checkout_opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        options.fetch_opts.callbacks.transfer_progress = { _, payload in GitCancel.isSet(payload) ? 1 : 0 }
        options.fetch_opts.callbacks.sideband_progress = { _, _, payload in GitCancel.isSet(payload) ? -1 : 0 }
        options.fetch_opts.callbacks.payload = cancel.payload

        var repository: OpaquePointer?
        let status = git_clone(&repository, remoteURL.absoluteString, localURL.path, &options)
        git_repository_free(repository)
        // A callback's "stop" comes back as an error; a cancel that landed
        // after the last callback still means stop — but only if it did not
        // finish.
        if status != 0, cancel.isSet { throw Failure.cancelled }
        try check(status)
    }

    /// Fetch the repository at `url` from its current branch's upstream's
    /// remote, else `origin` — SwiftGitX's rule. Blocking, as `clone` is.
    static func fetch(repositoryAt url: URL, cancel: GitCancel) throws {
        git_libgit2_init()
        defer { git_libgit2_shutdown() }

        var repository: OpaquePointer?
        try check(git_repository_open(&repository, url.path))
        defer { git_repository_free(repository) }

        var remoteName = "origin"
        var head: OpaquePointer?
        if git_repository_head(&head, repository) == 0, git_reference_is_branch(head) == 1,
           let name = git_reference_name(head) {
            var upstream = git_buf()
            if git_branch_upstream_remote(&upstream, repository, name) == 0, let ptr = upstream.ptr {
                remoteName = String(cString: ptr)
            }
            git_buf_dispose(&upstream)
        }
        git_reference_free(head)

        var remote: OpaquePointer?
        guard git_remote_lookup(&remote, repository, remoteName) == 0 else { throw Failure.noRemote }
        defer { git_remote_free(remote) }

        var options = git_fetch_options()
        try check(git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION)))
        options.callbacks.transfer_progress = { _, payload in GitCancel.isSet(payload) ? 1 : 0 }
        options.callbacks.sideband_progress = { _, _, payload in GitCancel.isSet(payload) ? -1 : 0 }
        options.callbacks.payload = cancel.payload

        let status = git_remote_fetch(remote, nil, &options, nil)
        if status != 0, cancel.isSet { throw Failure.cancelled }
        try check(status)
    }

    private static func check(_ status: Int32) throws {
        guard status < 0 else { return }
        if let error = git_error_last(), let message = error.pointee.message {
            throw Failure.libgit2(String(cString: message))
        }
        throw Failure.libgit2("libgit2 error \(status)")
    }
}
