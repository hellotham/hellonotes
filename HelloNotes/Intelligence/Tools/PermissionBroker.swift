//
//  PermissionBroker.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Gates side-effectful tools (write / edit / delete). A tool calls `confirm`,
//  which suspends until the person approves or denies in the UI. "Allow all this
//  session" switches to auto-approve. Modelled on OpenCode's capability gating.
//
//  Requests **queue**. Foundation Models runs the tool calls a model issues in
//  one step concurrently — asked to look up four things, the on-device model
//  emitted all four calls at once and they ran in parallel — so two edits can
//  ask for approval at the same moment. The broker used to deny any prompt
//  raised while another was showing, "to avoid deadlock", which under parallel
//  calls meant the second of two edits failed for no reason the person could
//  see. Now each waits its turn and is shown in order.
//

import Foundation
import Observation

/// A proposed change to a file, shown for approval.
struct EditDiff: Equatable, Sendable {
    var path: String
    var before: String
    var after: String
    var isCreation: Bool = false
    var isDeletion: Bool = false
}

@MainActor
@Observable
final class PermissionBroker {
    struct Prompt: Identifiable, Sendable {
        let id = UUID()
        let title: String
        let detail: String
        let diff: EditDiff?
    }

    /// The request on screen, if any.
    private(set) var prompt: Prompt?
    private(set) var allowAllThisSession = false

    /// How many requests are waiting behind the one on screen.
    var queuedCount: Int { waiting.count }

    private var current: CheckedContinuation<Bool, Never>?
    private var waiting: [(prompt: Prompt, continuation: CheckedContinuation<Bool, Never>)] = []

    /// Suspend until the person decides. Auto-approves once "Allow all" is
    /// chosen — except deletions, which always require an explicit click:
    /// losing a note (even to the Trash) is high-consequence enough to confirm
    /// every time, including when an injected tool call drives it under a
    /// broad grant.
    func confirm(title: String, detail: String, diff: EditDiff? = nil) async -> Bool {
        if allowAllThisSession, diff?.isDeletion != true { return true }
        let request = Prompt(title: title, detail: detail, diff: diff)
        return await withCheckedContinuation { continuation in
            if current == nil {
                current = continuation
                prompt = request
            } else {
                waiting.append((request, continuation))
            }
        }
    }

    func respond(approved: Bool, allowAll: Bool = false) {
        if allowAll { allowAllThisSession = true }
        let answered = current
        current = nil
        prompt = nil
        answered?.resume(returning: approved)
        showNext()
    }

    /// Deny everything pending — the one on screen and the queue — without
    /// touching the session's grant. For a stopped response: its tools must not
    /// sit waiting on a question nobody is going to answer.
    func cancelPending() {
        current?.resume(returning: false)
        current = nil
        prompt = nil
        for entry in waiting { entry.continuation.resume(returning: false) }
        waiting.removeAll()
    }

    /// End the session's grant as well. A blanket "Allow all" must not carry
    /// into a new conversation, where injected content could drive mutating
    /// tools without a fresh approval.
    func reset() {
        allowAllThisSession = false
        cancelPending()
    }

    private func showNext() {
        while !waiting.isEmpty {
            let next = waiting.removeFirst()
            // A grant given on the prompt just answered covers what queued
            // behind it — deletions excepted, as always.
            if allowAllThisSession, next.prompt.diff?.isDeletion != true {
                next.continuation.resume(returning: true)
                continue
            }
            current = next.continuation
            prompt = next.prompt
            return
        }
    }
}
