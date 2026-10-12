//
//  Waits.swift
//  HelloNotesTests
//
//  How long a test waits for something, counted in looks and not in seconds.
//
//  Ten suites each had an `eventually`: look, sleep ten milliseconds, look
//  again, and give up at a deadline on the clock. The deadline is the flaw.
//  The tests run together, most of them on the main actor, and a clock goes
//  on running while another test has it: on CI's three-core runner a wait
//  "for five seconds" came back from its first sleep with the five seconds
//  already spent — the work it was waiting for queued right behind it, never
//  having had a turn — and reported that typing "never settled"
//  (docs/implemented.md §51.48). On sixteen cores nothing holds the main
//  actor that long, which is why it passes here.
//
//  A wait is worth a number of looks instead: as many as its seconds hold
//  sleeps. Uncontended, that is the same wait. Contended, each look still
//  comes after a sleep of this test's own — a turn in which whatever it waits
//  for can run — however long the sleep took to come back.
//

import Foundation

nonisolated enum Waits {
    /// The looks `timeout` is worth, one every `step`.
    static func looks(in timeout: Duration, every step: Duration) -> Int {
        max(1, Int((timeout / step).rounded(.up)))
    }

    /// A wait's allowance, for a loop written out where it is used:
    ///
    ///     var patience = Waits.Patience(.seconds(10))
    ///     while !done, patience.lasts { try await Task.sleep(for: .milliseconds(10)) }
    ///
    /// which was `let deadline = ContinuousClock.now + .seconds(10)` and
    /// `ContinuousClock.now < deadline`. Each time it is asked is a look
    /// taken; it lasts for as many as its seconds hold ten-millisecond sleeps.
    struct Patience {
        private var looksLeft: Int

        init(_ timeout: Duration, every step: Duration = .milliseconds(10)) {
            looksLeft = Waits.looks(in: timeout, every: step)
        }

        /// Whether another look is left — and takes it.
        var lasts: Bool {
            mutating get {
                looksLeft -= 1
                return looksLeft >= 0
            }
        }
    }
}
