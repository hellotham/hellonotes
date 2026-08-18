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
///
/// **`nonisolated` on purpose, and load-bearing.** This target builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so an unannotated type is
/// `@MainActor` — which for *this* type would be self-defeating twice over: the
/// sampler must read the breadcrumb precisely when the main actor cannot answer,
/// and a probe that hops to the main actor to report on it would both deadlock
/// and inflate every number it produced.
nonisolated enum MainActorWatchdog {

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
        // Called on the main actor, so this *is* the main thread's port. Kept
        // for the process's lifetime (never deallocated) because the sampler
        // needs it precisely when the main thread cannot be asked for anything.
        mainThreadPort = mach_thread_self()
        log("watchdog started — threshold \(stallThreshold.milliseconds)ms")

        let thread = Thread {
            while !Thread.current.isCancelled {
                let asked = ContinuousClock.now
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }

                // Poll rather than wait once.
                //
                // A single `wait(timeout:)` returns when the stall *ends*, so a
                // stack captured there shows what the main thread picked up
                // next — the same "sample it after the freeze" mistake that
                // read an idle stack as "nothing wrong" earlier. Polling lets
                // the capture happen while the main thread is still stuck, and
                // taking several shows how the stall progresses instead of one
                // arbitrary instant inside it.
                var samples = 0
                var timedOut = false
                while answered.wait(timeout: .now() + .milliseconds(250)) == .timedOut {
                    let waited = ContinuousClock.now - asked
                    if waited > .seconds(30) { timedOut = true; break }
                    guard waited > stackThreshold, samples < maxStacksPerStall else { continue }
                    samples += 1
                    logMainThreadStack(prefix: "  stalled \(waited.milliseconds)ms, sample \(samples):")
                }
                let waited = ContinuousClock.now - asked

                if timedOut {
                    log("STALL >30s while: \(currentBreadcrumb()) — main actor never answered")
                    logMainThreadStack(prefix: "  main thread:")
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

    /// Record a one-off observation — which branch was taken, and why.
    ///
    /// A duration alone says an operation was slow. When the expensive path is
    /// chosen by a condition, the useful fact is usually *which condition* and
    /// *what its operands were*, because the bug is generally that a comparison
    /// nobody expected to fail is failing every time.
    static func note(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        log("NOTE \(message())")
    }

    private static func currentBreadcrumbOrNil() -> String? {
        breadcrumbLock.lock()
        defer { breadcrumbLock.unlock() }
        return breadcrumb
    }

    // MARK: - Where, not just when

    /// A stall over this gets its stack captured as well as its duration.
    private static let stackThreshold: Duration = .milliseconds(500)

    /// How many stacks one stall may contribute. Capturing suspends the main
    /// thread for the length of a register read and a pointer walk, so a few is
    /// free and a stream of them would be an instrument that perturbs.
    private static let maxStacksPerStall = 4

    private nonisolated(unsafe) static var mainThreadPort: mach_port_t = 0

    /// Pre-allocated so capture allocates nothing.
    ///
    /// The capture happens with the main thread **suspended**, and if the main
    /// thread was inside `malloc` at that moment it holds the allocator's lock.
    /// Allocating here would then block forever on a thread that cannot run —
    /// the debugging tool deadlocking the process it is debugging. So the buffer
    /// is allocated once, up front, and the suspended window does nothing but
    /// read memory.
    private static let frameCapacity = 64
    private nonisolated(unsafe) static let frames =
        UnsafeMutablePointer<UInt>.allocate(capacity: frameCapacity)

    /// Walk the main thread's frame-pointer chain. Returns the number of frames.
    ///
    /// Only the raw addresses are collected while suspended; symbolication
    /// (which allocates) happens after the thread is running again.
    private static func captureMainThreadStack() -> Int {
        #if arch(arm64)
        guard mainThreadPort != 0, thread_suspend(mainThreadPort) == KERN_SUCCESS else { return 0 }
        defer { thread_resume(mainThreadPort) }

        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(mainThreadPort, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }

        var depth = 0
        frames[depth] = UInt(state.__pc); depth += 1
        var frame = UInt(state.__fp)
        while depth < frameCapacity, frame > 0x1000, frame % 8 == 0 {
            // [fp] = caller's fp, [fp + 8] = return address.
            let next = UnsafeRawPointer(bitPattern: frame)?.load(as: UInt.self) ?? 0
            let returnAddress = UnsafeRawPointer(bitPattern: frame + 8)?.load(as: UInt.self) ?? 0
            guard returnAddress > 0x1000 else { break }
            frames[depth] = returnAddress; depth += 1
            guard next > frame else { break }   // the chain must climb
            frame = next
        }
        return depth
        #else
        return 0
        #endif
    }

    /// Capture and write the main thread's stack, innermost frame first.
    private static func logMainThreadStack(prefix: String) {
        let depth = captureMainThreadStack()
        guard depth > 0 else { return }
        var lines: [String] = []
        for index in 0..<depth {
            let address = frames[index]
            var info = Dl_info()
            if dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let name = info.dli_sname {
                let symbol = String(cString: name)
                let offset = address - UInt(bitPattern: info.dli_saddr)
                lines.append("      \(index): \(demangle(symbol)) + \(offset)")
            } else {
                lines.append("      \(index): 0x\(String(address, radix: 16))")
            }
        }
        log(prefix + "\n" + lines.joined(separator: "\n"))
    }

    /// Swift's runtime demangler, so the log reads as source rather than as
    /// `$s10HelloNotes…`. Absent on a platform without it, the mangled name is
    /// still perfectly identifiable, so failure is not worth handling loudly.
    private static func demangle(_ symbol: String) -> String {
        guard symbol.hasPrefix("$s") || symbol.hasPrefix("_$s") else { return symbol }
        guard let handle = dlopen(nil, RTLD_NOW),
              let pointer = dlsym(handle, "swift_demangle") else { return symbol }
        typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int,
                                             UnsafeMutablePointer<CChar>?,
                                             UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
        let function = unsafeBitCast(pointer, to: Demangle.self)
        guard let result = symbol.withCString({ function($0, strlen($0), nil, nil, 0) }) else { return symbol }
        defer { free(result) }
        return String(cString: result)
    }

    // MARK: - Log

    private static let logURL: URL? = {
        (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true))?
            .appendingPathComponent("hn-stalls.log")
    }()

    /// Writes happen here, off every caller's thread.
    ///
    /// The first version took a lock and did the file I/O inline. The watchdog
    /// then caught the main thread stalled for **six seconds inside
    /// `MainActorWatchdog.log`**, waiting on that very lock — an instrument that
    /// had become the largest blocker it was reporting on. A measuring device
    /// must cost the measured path nothing, so the caller now only formats a
    /// line and hands it over.
    private static let writer = DispatchQueue(label: "com.hellotham.HelloNotes.watchdog.log",
                                              qos: .utility)

    private static func log(_ message: String) {
        guard isEnabled, let logURL else { return }
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        writer.async {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: logURL)
            }
        }
    }
}

private extension Duration {
    var milliseconds: Int { Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000) }
    var seconds: TimeInterval { TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18 }
}
