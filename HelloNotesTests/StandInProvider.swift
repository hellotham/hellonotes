//
//  StandInProvider.swift
//  HelloNotesTests
//
//  A file provider of a test's own, for `FileIO.waitForDownload`: here or not,
//  slow to answer, silent until let go, or delivering when the test says —
//  and recording what it was asked, and on which thread.
//
//  **On lanes of its own.** The app's provider questions share sixteen lanes,
//  and a question held silent holds its lane: a test that held one of the
//  app's for a minute — waiting for something that, failing, never came —
//  held up whichever other test's note fell on that lane, one time in
//  sixteen, by a hash that differs per run (docs/implemented.md §51.52).
//

import Foundation
@testable import HelloNotes

nonisolated final class StandInProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var isHere: Bool
    private var questions = 0
    private var asks = 0
    private var onMain = 0
    private let firstAnswerTakes: TimeInterval
    private let silence: DispatchSemaphore?
    private let lanes = FileIO.ProviderCalls.makeLanes("test.stand-in.\(UUID().uuidString)")

    /// - Parameters:
    ///   - here: whether the file is here to begin with.
    ///   - firstAnswerTakes: how long the first question takes to answer.
    ///   - silent: every question waits until `release()`.
    init(here: Bool = false, firstAnswerTakes: TimeInterval = 0, silent: Bool = false) {
        isHere = here
        self.firstAnswerTakes = firstAnswerTakes
        silence = silent ? DispatchSemaphore(value: 0) : nil
    }

    var calls: FileIO.ProviderCalls {
        FileIO.ProviderCalls(
            isHere: { [self] _, _ in
                let n = lock.withLock {
                    questions += 1
                    if Thread.isMainThread { onMain += 1 }
                    return questions
                }
                silence?.wait()
                if n == 1, firstAnswerTakes > 0 { Thread.sleep(forTimeInterval: firstAnswerTakes) }
                return lock.withLock { isHere }
            },
            askFor: { [self] _ in
                lock.withLock {
                    asks += 1
                    if Thread.isMainThread { onMain += 1 }
                }
            },
            lanes: lanes)
    }

    /// The file has come.
    func arrive() { lock.withLock { isHere = true } }
    /// A silent provider answers from now on.
    func release() { for _ in 0..<512 { silence?.signal() } }

    var questionCount: Int { lock.withLock { questions } }
    var askCount: Int { lock.withLock { asks } }
    var mainThreadCalls: Int { lock.withLock { onMain } }
}
