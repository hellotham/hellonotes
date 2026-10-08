//
//  LargeFolderPromptTests.swift
//  HelloNotesTests
//
//  Adding a folder too large to index without warning asks first, and waits
//  for the answer the shell brings back (`Library.openChecking`).
//

import Foundation
import Testing
@testable import HelloNotes

@MainActor
struct LargeFolderPromptTests {

    private static let large = Library.FolderSizeEstimate(itemsSeen: 9_000, directoriesRemaining: 40, isComplete: false)

    /// Whether `task` ends within `limit` — a caller left waiting forever
    /// fails the test rather than hanging it.
    private func finishes(_ task: Task<Void, Never>, within limit: Duration) async -> Bool {
        let done = Locked(false)
        Task { await task.value; done.set(true) }
        let deadline = ContinuousClock.now + limit
        while !done.value, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return done.value
    }

    private func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// A second large folder asked about while the first question is still up
    /// — two adds at once — answers the first for it, as Cancel. The question
    /// was replaced, its caller's continuation with it, and that caller waited
    /// forever. The control: the second question is the one up, and its own
    /// answer reaches its caller.
    @Test func aSecondQuestionAnswersTheFirst() async {
        let library = Library()
        let first = Task {
            await library.openChecking([URL(fileURLWithPath: "/hn-first")], estimate: { _ in Self.large })
        }
        await until { library.pendingLargeFolder != nil }
        let second = Task {
            await library.openChecking([URL(fileURLWithPath: "/hn-second")], estimate: { _ in Self.large })
        }
        await until { library.pendingLargeFolder?.url.lastPathComponent == "hn-second" }

        #expect(await finishes(first, within: .seconds(2)), "the first caller waits for an answer no one can give")
        #expect(library.pendingLargeFolder?.url.lastPathComponent == "hn-second")
        library.resolveLargeFolder(.cancel)
        #expect(await finishes(second, within: .seconds(2)))
        #expect(library.pendingLargeFolder == nil)
    }
}
