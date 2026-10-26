//
//  GitThreadTests.swift
//  HelloNotesTests
//
//  libgit2's network work runs on a thread of its own — never the pool.
//
//  Every libgit2 call blocks its thread, and a network one for as long as the
//  network takes. Run detached it held a thread of the concurrency pool, which
//  is what every sleeping task in the process wakes through, the main actor's
//  too (implemented.md §51.62, §51.66).
//

import Darwin
import Foundation
import libgit2
import SwiftGitX
import Synchronization
import Testing
@testable import HelloNotes

@Suite(.serialized) @MainActor
struct GitThreadTests {

    /// **Work that waits holds no thread of the pool.** More runs than the
    /// pool has threads each wait on a gate, as a push waits on a host that
    /// does not answer, and a task that sleeps off the main actor goes on
    /// waking. Run detached, each held a thread of the pool, and with more
    /// held than there are threads nothing woke until the gate's breaker let
    /// them go.
    @Test(.timeLimit(.minutes(1)))
    func workThatWaitsHoldsNoThreadOfThePool() async throws {
        let count = ProcessInfo.processInfo.activeProcessorCount + 2
        let gate = Gate(breaker: .seconds(30))
        defer { gate.open() }
        let base = FileManager.default.temporaryDirectory.appending(path: "hn-git-thread-\(UUID().uuidString)")
        let runs = (0..<count).map { index in
            Task.detached {
                try? await GitThread.run(GitThread.push, for: base.appending(path: "\(index)")) { _ in gate.wait() }
            }
        }
        var patience = Waits.Patience(.seconds(30))
        while gate.entered < count, patience.lasts { try await Task.sleep(for: .milliseconds(10)) }

        let ticks = Counter()
        let ticker = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                ticks.add()
            }
        }
        defer { ticker.cancel() }
        let from = ticks.value
        while ticks.value < from + 20, patience.lasts { try await Task.sleep(for: .milliseconds(10)) }
        let woke = ticks.value - from
        #expect(gate.entered == count && woke >= 20 && gate.isHolding,
                "the process stopped while \(gate.entered) of \(count) runs waited: \(woke) wake-ups, held: \(gate.isHolding)")

        gate.open()
        for run in runs { await run.value }
    }

    /// **A cancel reaches work on its own thread through the flag** — the way
    /// Stop reaches libgit2's callbacks there, where `Task.isCancelled` has no
    /// task to ask, and says nothing.
    @Test(.timeLimit(.minutes(1)))
    func aCancelReachesTheWorkThroughItsFlag() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "hn-git-cancel-\(UUID().uuidString)")
        let started = Counter()
        let run = Task {
            try await GitThread.run(GitThread.push, for: url) { cancel -> (flag: Bool, task: Bool) in
                started.add()
                let deadline = ContinuousClock.now + .seconds(10)
                while !cancel.isSet, ContinuousClock.now < deadline { usleep(1_000) }
                return (cancel.isSet, Task.isCancelled)
            }
        }
        var patience = Waits.Patience(.seconds(10))
        while started.value == 0, patience.lasts { try await Task.sleep(for: .milliseconds(10)) }
        run.cancel()
        let seen = try await run.value
        #expect(seen.flag, "the cancel never reached the work")
        #expect(!seen.task, "the work ran on a task's thread, where the flag would not be needed")
    }

    /// **The service's network work runs on threads of its own** — a push, a
    /// fetch, a clone and a new repository pushed to its remote — each heard
    /// by its thread's name, over libgit2's local transport.
    @Test(.timeLimit(.minutes(2)))
    func theServicesNetworkWorkRunsOnThreadsOfItsOwn() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("hn-git-wiring-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let local = base.appendingPathComponent("local", isDirectory: true)
        let remote = try Self.bareRepository(base.appendingPathComponent("remote.git", isDirectory: true))
        let madeRemote = try Self.bareRepository(base.appendingPathComponent("made-remote.git", isDirectory: true))
        try Self.repositoryWithOneNote(at: local, origin: remote)

        let root = try #require(GitService.discoverRepositoryRoot(from: local))
        let cloned = base.appendingPathComponent("remote")
        let made = base.appendingPathComponent("Made", isDirectory: true)
        let heard = Heard()
        let places = [root, cloned, made].map(\.path)
        GitThread.probes.withLock { probes in
            for place in places { probes[place] = { name in heard.add(name, at: place) } }
        }
        defer { GitThread.probes.withLock { probes in for place in places { probes[place] = nil } } }

        let git = GitService()
        git.rootURL = local
        await git.refreshStatus()
        await git.push()
        #expect(git.lastError == nil, "\(git.lastError ?? "")")
        await git.fetch()
        #expect(git.lastError == nil, "\(git.lastError ?? "")")
        let clone = GitService()
        #expect(await clone.cloneRepository(from: remote.absoluteString, into: base) != nil, "\(clone.lastError ?? "")")
        let maker = GitService()
        #expect(await maker.createRepository(named: "Made", in: base, remoteURL: madeRemote) != nil,
                "\(maker.lastError ?? "")")

        #expect(heard.names(at: root.path) == [GitThread.push, GitThread.fetch])
        #expect(heard.names(at: cloned.path) == [GitThread.clone])
        #expect(heard.names(at: made.path) == [GitThread.create])
    }

    /// **Pushes to a host that accepts and never answers hold no thread of
    /// the pool** — more of them than it has threads, each to a server that
    /// takes the connection and says nothing, which no callback of libgit2's
    /// can stop. Only where this process may listen: the sandboxed app may
    /// not, so this runs unsandboxed, as CI runs the suite.
    @Test(.enabled(if: SilentServer.canListen), .timeLimit(.minutes(2)))
    func pushesToAHostThatNeverAnswersHoldNoThreadOfThePool() async throws {
        let count = ProcessInfo.processInfo.activeProcessorCount + 2
        let server = try #require(SilentServer(breaker: .seconds(30)))
        defer { server.close() }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("hn-git-silent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let creates = (0..<count).map { index in
            Task { @MainActor in
                await GitService().createRepository(
                    named: "Silent \(index)", in: base,
                    remoteURL: URL(string: "http://127.0.0.1:\(server.port)/silent-\(index).git"))
            }
        }
        var patience = Waits.Patience(.seconds(30))
        while server.connections < count, patience.lasts { try await Task.sleep(for: .milliseconds(10)) }

        let ticks = Counter()
        let ticker = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                ticks.add()
            }
        }
        defer { ticker.cancel() }
        let from = ticks.value
        while ticks.value < from + 20, patience.lasts { try await Task.sleep(for: .milliseconds(10)) }
        let woke = ticks.value - from
        #expect(server.connections == count && woke >= 20 && server.isHolding,
                "the process stopped while \(server.connections) of \(count) pushes waited: \(woke) wake-ups")

        server.close()
        for create in creates { #expect(await create.value == nil, "a push to a server that said nothing succeeded") }
    }

    // MARK: - Helpers

    /// An empty bare repository at `url`.
    private static func bareRepository(_ url: URL) throws -> URL {
        git_libgit2_init()
        defer { git_libgit2_shutdown() }
        var bare: OpaquePointer?
        try #require(git_repository_init(&bare, url.path, 1) == 0, "could not make the bare remote")
        git_repository_free(bare)
        return url
    }

    /// A repository holding one committed note, with `origin` at `remote`.
    private static func repositoryWithOneNote(at local: URL, origin remote: URL) throws {
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let repository = try Repository(at: local, createIfNotExists: true)
        GitService.ensureCommitIdentity(repository)
        try Data("# Note\n".utf8).write(to: local.appendingPathComponent("Note.md"))
        try repository.add(path: "Note.md")
        _ = try repository.commit(message: "First")
        try repository.remote.add(named: "origin", at: remote)
    }

    /// Shut until the test opens it — or its breaker does, so that a process
    /// that has stopped (the control) still ends; `isHolding` says whether it
    /// is still the test's to open.
    private final class Gate: Sendable {
        private let state = Mutex<(open: Bool, entered: Int)>((false, 0))
        private let deadline: ContinuousClock.Instant

        init(breaker: Duration) { deadline = .now + breaker }

        /// Wait here, on the caller's own thread.
        func wait() {
            state.withLock { $0.entered += 1 }
            while !state.withLock({ $0.open }), ContinuousClock.now < deadline { usleep(10_000) }
        }

        func open() { state.withLock { $0.open = true } }
        var entered: Int { state.withLock { $0.entered } }
        var isHolding: Bool { !state.withLock { $0.open } && ContinuousClock.now < deadline }
    }

    /// The thread names each place's runs were heard on, in order.
    private final class Heard: Sendable {
        private let names = Mutex<[String: [String]]>([:])
        func add(_ name: String, at place: String) { names.withLock { $0[place, default: []].append(name) } }
        func names(at place: String) -> [String] { names.withLock { $0[place] ?? [] } }
    }

    /// A count kept across tasks and threads.
    private final class Counter: Sendable {
        private let count = Mutex(0)
        func add() { count.withLock { $0 += 1 } }
        var value: Int { count.withLock { $0 } }
    }
}

/// A server on the loopback that takes every connection and says nothing —
/// until it is closed, or its breaker closes it. A sandboxed process may not
/// listen, so `canListen` asks first.
private final class SilentServer: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var accepted: [Int32] = []
    private var closed = false
    private let deadline: ContinuousClock.Instant

    init?(breaker: Duration) {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        guard bound == 0, listen(socket, 64) == 0, named == 0 else {
            Darwin.close(socket)
            return nil
        }
        listener = socket
        port = UInt16(bigEndian: address.sin_port)
        deadline = .now + breaker
        Thread.detachNewThread { [self] in acceptUntilClosed() }
        Thread.detachNewThread { [self] in
            while !isClosed, ContinuousClock.now < deadline { usleep(50_000) }
            close()
        }
    }

    /// Whether this process may listen on the loopback at all.
    static var canListen: Bool {
        guard let server = SilentServer(breaker: .seconds(1)) else { return false }
        server.close()
        return true
    }

    var connections: Int { lock.withLock { accepted.count } }
    var isHolding: Bool { !isClosed && ContinuousClock.now < deadline }
    private var isClosed: Bool { lock.withLock { closed } }

    func close() {
        let sockets: [Int32]? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            return accepted + [listener]
        }
        for socket in sockets ?? [] {
            shutdown(socket, SHUT_RDWR)
            Darwin.close(socket)
        }
    }

    private func acceptUntilClosed() {
        while !isClosed {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            let keep = lock.withLock { () -> Bool in
                guard !closed else { return false }
                accepted.append(connection)
                return true
            }
            if !keep { Darwin.close(connection) }
        }
    }
}
