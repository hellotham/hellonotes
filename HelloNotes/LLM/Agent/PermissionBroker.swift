//
//  PermissionBroker.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Gates side-effectful tools (write / edit / delete). A tool calls `confirm`,
//  which suspends until the user approves or denies via the UI. "Allow all this
//  session" switches to auto-approve. Modelled on OpenCode's capability gating.
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

    private(set) var prompt: Prompt?
    private(set) var allowAllThisSession = false

    private var continuation: CheckedContinuation<Bool, Never>?

    /// Suspend until the user decides. Auto-approves once "Allow all" is chosen
    /// — except deletions, which always require an explicit click: losing a note
    /// (even to the Trash) is high-consequence enough to confirm every time,
    /// including when an injected tool-call drives it under a broad grant.
    func confirm(title: String, detail: String, diff: EditDiff? = nil) async -> Bool {
        if allowAllThisSession, diff?.isDeletion != true { return true }
        // If a prompt is somehow already pending, deny the new one to avoid deadlock.
        if continuation != nil { return false }
        return await withCheckedContinuation { cont in
            continuation = cont
            prompt = Prompt(title: title, detail: detail, diff: diff)
        }
    }

    func respond(approved: Bool, allowAll: Bool = false) {
        if allowAll { allowAllThisSession = true }
        prompt = nil
        let cont = continuation
        continuation = nil
        cont?.resume(returning: approved)
    }

    func reset() {
        allowAllThisSession = false
        prompt = nil
        continuation?.resume(returning: false)
        continuation = nil
    }
}
