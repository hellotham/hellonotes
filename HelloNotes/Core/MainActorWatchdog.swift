//
//  MainActorWatchdog.swift
//  HelloNotes
//
//  Created by Chris Tham on 18/8/2026.
//
//  Catch a blocked editor while it is blocked.
//
//  The golden rule of this app is that the main editor loop is never blocked —
//  not by a folder scan, an index rebuild, a search, a Git call or a model. The
//  rule was previously enforced by care, and care failed: an audit found
//  coordinated file reads on the main actor, a synchronous whole-vault walk on
//  the main actor, and O(notes) work inside view bodies re-running on every
//  keystroke. Worse, two attempts to fix the resulting freeze were validated by
//  reasoning rather than measurement, and both were wrong.
//
//  So this file exists to make a stall a thing the *app* reports, with evidence,
//  at the moment it happens. Two instruments:
//
//   1. `start()` — a background sampler that measures how long the main actor
//      takes to answer. It cannot be fooled by a theory about which code is
//      slow, because it does not know or care: it times the queue.
//   2. `measure(_:)` — a breadcrumb around work believed to be expensive, which
//      both times that work and tells the sampler what was running when a stall
//      began. A latency number alone says "something took 900ms"; the pairing
//      says which something.
//
//  Debug builds only and off unless `HN_STALL_LOG` asks for it, so an ordinary
//  run pays nothing. Writes a plain file readable with `cat`, following the
//  proven `hn-geom.log` pattern (`MarkdownTextView.dumpGeometry`) rather than
//  `os_log`, whose level/predicate behaviour has been unreliable for this app.
//

import Foundation

/// Watches the main actor's responsiveness and records anything that holds it.
enum MainActorWatchdog {

    /// A main-actor hop slower than this is a stall worth a line in the log.
    ///
    /// 100ms is roughly six dropped frames — comfortably past "a person notices"
    /// and well short of "an ordinary layout pass". The budget is not a target
    /// to sit under; anything appearing here at all is a bug.
    static let stallThreshold: Duration = .milliseconds(100)

    /// How often the sampler asks the main actor to answer.
    private static let sampleInterval: Duration = .milliseconds(50)

    static let isEnabled: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["HN_STALL_LOG"] != nil
        #else
        return false
        #endif
    }()

    // MARK: - Breadcrumb

    /// What the main actor is doing right now, if anything said so.
    ///
    /// `nonisolated(unsafe)` and guarded by its own lock: the sampler reads it
    /// from a background thread precisely *because* the main actor is stuck and
    /// cannot be asked. Hopping to the main actor to find out what is blocking
    /// the main actor would deadlock on the very condition being measured.
    private nonisolated(unsafe) static var breadcrumb: String?
    private static let breadcrumbLock = NSLock()

    private static func setBreadcrumb(_ value: String?) {
        breadcrumbLock.lock()
        breadcrumb = value
        breadcrumbLock.unlock()
    }

    private static func currentBreadcrumb() -> String {
        breadcrumbLock.lock()
        defer { breadcrumbLock.unlock() }
        return breadcrumb ?? "(unlabelled)"
    }

    // MARK: - Sampling

    private nonisolated(unsafe) static var sampler: Thread?

    /// Begin watching. Safe to call more than once; only the first starts a thread.
    static func start() {
        guard isEnabled, sampler == nil else { return }
        log("watchdog started — threshold \(stallThreshold.milliseconds)ms")

        let thread = Thread {
            while !Thread.current.isCancelled {
                let asked = ContinuousClock.now
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }

                // Wait generously; a real stall is the interesting case and we
                // must not give up before it ends or the duration is a floor
                // rather than a measurement.
                let deadline = DispatchTime.now() + .seconds(30)
                let timedOut = answered.wait(timeout: deadline) == .timedOut
                let waited = ContinuousClock.now - asked

                if timedOut {
                    log("STALL >30s while: \(currentBreadcrumb()) — main actor never answered")
                } else if waited > stallThreshold {
                    log("STALL \(waited.milliseconds)ms while: \(currentBreadcrumb())")
                }
                Thread.sleep(forTimeInterval: sampleInterval.seconds)
            }
        }
        thread.name = "com.hellotham.HelloNotes.watchdog"
        thread.qualityOfService = .utility
        sampler = thread
        thread.start()
    }

    static func stop() {
        sampler?.cancel()
        sampler = nil
    }

    // MARK: - Measuring a known-expensive operation

    /// Time `body`, label it for the sampler, and log it if it overruns.
    ///
    /// Returns `body`'s value and rethrows, so it can wrap an existing
    /// expression without restructuring the call site — the point is that
    /// instrumenting a suspect costs one line, so there is no reason to argue
    /// about whether it is slow instead of finding out.
    @discardableResult
    static func measure<T>(_ label: @autoclosure () -> String,
                           _ body: () throws -> T) rethrows -> T {
        guard isEnabled else { return try body() }
        let name = label()
        let previous = currentBreadcrumbOrNil()
        setBreadcrumb(name)
        defer { setBreadcrumb(previous) }

        let started = ContinuousClock.now
        let value = try body()
        let elapsed = ContinuousClock.now - started
        if elapsed > stallThreshold {
            log("SLOW \(elapsed.milliseconds)ms — \(name)")
        }
        return value
    }

    private static func currentBreadcrumbOrNil() -> String? {
        breadcrumbLock.lock()
        defer { breadcrumbLock.unlock() }
        return breadcrumb
    }

    // MARK: - Log

    private static let logURL: URL? = {
        (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true))?
            .appendingPathComponent("hn-stalls.log")
    }()

    private static let logLock = NSLock()

    private static func log(_ message: String) {
        guard isEnabled, let logURL else { return }
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        logLock.lock()
        defer { logLock.unlock() }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }
}

private extension Duration {
    var milliseconds: Int { Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000) }
    var seconds: TimeInterval { TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18 }
}
