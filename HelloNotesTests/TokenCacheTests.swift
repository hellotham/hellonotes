//
//  TokenCacheTests.swift
//  HelloNotesTests
//
//  The providers' tokens, kept in memory once read (`TokenCache`,
//  implemented.md §51.34) — against a keychain of the test's own, which can
//  fail either way and hold a read part-way. The person's login Keychain is
//  never touched.
//

import Foundation
import Testing
@testable import HelloNotes

struct TokenCacheTests {

    /// Answers from a dictionary, counts its reads, can fail reads or writes,
    /// and can hold the next read of an account until told to go on — having
    /// already taken the answer it will give, as a read in flight has.
    final class FakeKeychain: TokenKeychain, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: String] = [:]
        private var readCount = 0
        private var readsFail = false
        private var writesFail = false
        private var holds: [String: (reached: DispatchSemaphore, resume: DispatchSemaphore)] = [:]
        private var writeHolds: [String: (reached: DispatchSemaphore, resume: DispatchSemaphore)] = [:]

        var reads: Int { lock.withLock { readCount } }
        var failsReads: Bool {
            get { lock.withLock { readsFail } }
            set { lock.withLock { readsFail = newValue } }
        }
        var failsWrites: Bool {
            get { lock.withLock { writesFail } }
            set { lock.withLock { writesFail = newValue } }
        }

        /// As a token written before this launch is.
        func put(_ token: String, for account: String) {
            lock.withLock { items[account] = token }
        }

        func stored(_ account: String) -> String? {
            lock.withLock { items[account] }
        }

        /// The next read of `account` signals `reached` and waits for `resume`.
        func holdNextRead(of account: String) -> (reached: DispatchSemaphore, resume: DispatchSemaphore) {
            let hold = (reached: DispatchSemaphore(value: 0), resume: DispatchSemaphore(value: 0))
            lock.withLock { holds[account] = hold }
            return hold
        }

        /// The next write of `account` signals `reached` and waits for `resume`.
        func holdNextWrite(of account: String) -> (reached: DispatchSemaphore, resume: DispatchSemaphore) {
            let hold = (reached: DispatchSemaphore(value: 0), resume: DispatchSemaphore(value: 0))
            lock.withLock { writeHolds[account] = hold }
            return hold
        }

        func read(_ account: String) -> TokenRead {
            let (answer, hold) = lock.withLock { () -> (TokenRead, (reached: DispatchSemaphore, resume: DispatchSemaphore)?) in
                readCount += 1
                let answer: TokenRead = readsFail ? .failed : items[account].map(TokenRead.found) ?? .absent
                return (answer, holds.removeValue(forKey: account))
            }
            if let hold {
                hold.reached.signal()
                hold.resume.wait()
            }
            return answer
        }

        func write(_ value: String?, for account: String) -> Bool {
            if let hold = lock.withLock({ writeHolds.removeValue(forKey: account) }) {
                hold.reached.signal()
                hold.resume.wait()
            }
            return lock.withLock {
                guard !writesFail else { return false }
                items[account] = value
                return true
            }
        }
    }

    /// A Keychain that could not answer — locked, a prompt refused — is asked
    /// again next time. Remembered as "signed out", it refused every request
    /// until the app quit, and "sign in again" signs out first, deleting the
    /// tokens that were there all along.
    @Test func aFailedReadIsNotRememberedAsSignedOut() {
        let keychain = FakeKeychain()
        keychain.put("token", for: "box#1")
        let cache = TokenCache(keychain: keychain)

        keychain.failsReads = true
        #expect(cache.token(for: "box#1") == nil)
        keychain.failsReads = false
        #expect(cache.token(for: "box#1") == "token", "a read that failed was remembered as signed out")
    }

    /// What it is there for: an account asked about is read once, signed in
    /// or not — the control for the test above, which would pass for a cache
    /// that never remembered anything.
    @Test func anAccountIsReadOnceSignedInOrNot() {
        let keychain = FakeKeychain()
        keychain.put("token", for: "box#1")
        let cache = TokenCache(keychain: keychain)

        #expect(cache.token(for: "box#1") == "token")
        #expect(cache.token(for: "box#1") == "token")
        #expect(cache.token(for: "box#2") == nil)
        #expect(cache.token(for: "box#2") == nil)
        #expect(keychain.reads == 2, "the Keychain was read \(keychain.reads) times for two accounts")
    }

    /// A write that did not reach the Keychain is still this process's token:
    /// Box and OneDrive spend a refresh token when they hand out the next, so
    /// the one just written is the only valid one there is.
    @Test func aTokenWhoseWriteFailedIsKept() {
        let keychain = FakeKeychain()
        let cache = TokenCache(keychain: keychain)

        keychain.failsWrites = true
        #expect(cache.setToken("rotated", for: "box#1-refresh") == false)
        #expect(cache.token(for: "box#1-refresh") == "rotated", "a token whose write failed was forgotten")
        #expect(keychain.reads == 0)

        keychain.failsWrites = false
        #expect(cache.setToken(nil, for: "box#1-refresh"))
        #expect(cache.token(for: "box#1-refresh") == nil, "signing out kept the token")
        #expect(keychain.stored("box#1-refresh") == nil)
    }

    /// One account's token, already known, is answered while another
    /// account's Keychain read is under way. The lock was held across every
    /// Keychain call, so a main-actor read of one account waited on another's
    /// XPC round trip — or on a prompt for as long as it was up.
    @Test func aReadNeverWaitsOnAnotherAccountsKeychainCall() {
        let keychain = FakeKeychain()
        let cache = TokenCache(keychain: keychain)
        cache.setToken("dropbox token", for: "dropbox#1")
        let hold = keychain.holdNextRead(of: "box#1")
        DispatchQueue.global().async { _ = cache.token(for: "box#1") }
        hold.reached.wait()

        let answered = DispatchSemaphore(value: 0)
        let answer = Locked<String?>(nil)
        DispatchQueue.global().async {
            answer.set(cache.token(for: "dropbox#1"))
            answered.signal()
        }
        let waited = answered.wait(timeout: .now() + 2)
        hold.resume.signal()
        #expect(waited == .success, "a read of one account waited on another's Keychain call")
        if waited == .timedOut { answered.wait() }
        #expect(answer.value == "dropbox token")
    }

    /// One account's write never waits on another's — a refresh writing its
    /// two tokens, or a prompt on screen. The writes took one lock for the
    /// whole process, so a Dropbox refresh on the main actor queued behind a
    /// Box refresh's Keychain calls.
    @Test func aWriteNeverWaitsOnAnotherAccountsWrite() {
        let keychain = FakeKeychain()
        let cache = TokenCache(keychain: keychain)
        let hold = keychain.holdNextWrite(of: "box#1")
        DispatchQueue.global().async { cache.setToken("box token", for: "box#1") }
        hold.reached.wait()

        let written = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            cache.setToken("dropbox token", for: "dropbox#1")
            written.signal()
        }
        let waited = written.wait(timeout: .now() + 2)
        hold.resume.signal()
        #expect(waited == .success, "a write of one account waited on another's")
        if waited == .timedOut { written.wait() }
        #expect(cache.token(for: "dropbox#1") == "dropbox token")
    }

    /// Signed out and a Keychain that could not be read are two errors, so a
    /// store can tell the person which; only the first is a sign-in to redo.
    @Test func aMissingTokenAndAnUnreadableKeychainAreTwoErrors() throws {
        let keychain = FakeKeychain()
        keychain.put("token", for: "box#1")
        let cache = TokenCache(keychain: keychain)

        #expect(try cache.require("box#1") == "token")
        #expect(throws: RemoteStoreError.notAuthenticated) { try cache.require("box#2") }
        keychain.failsReads = true
        #expect(throws: RemoteStoreError.keychainUnavailable) { try cache.require("box#3") }
    }

    /// A store that fails every call with `failure`.
    final class FailingStore: RemoteStore, @unchecked Sendable {
        let providerName = "Failing"
        let accountID = "failing"
        let failure: RemoteStoreError
        init(_ failure: RemoteStoreError) { self.failure = failure }
        var isAuthenticated: Bool { true }
        func authenticate() async throws {}
        func signOut() {}
        func list(path: String) async throws -> [RemoteEntry] { throw failure }
        func read(path: String) async throws -> Data { throw failure }
        func write(_ data: Data, to path: String) async throws { throw failure }
        func delete(path: String) async throws { throw failure }
        func move(from source: String, to destination: String) async throws { throw failure }
        func createFolder(path: String) async throws { throw failure }
    }

    /// A Keychain that could not be read does not ask to sign in again —
    /// which signs out first, deleting tokens that are fine. The control: a
    /// token the provider rejects does ask.
    @MainActor
    @Test func aLockedKeychainDoesNotAskToSignInAgain() async {
        let locked = RemoteBrowserModel(store: FailingStore(.keychainUnavailable))
        await locked.load("")
        #expect(!locked.needsReauthentication, "a Keychain that could not be read was taken for a rejected sign-in")
        #expect(locked.error != nil, "the failure was not shown")

        let rejected = RemoteBrowserModel(store: FailingStore(.notAuthenticated))
        await rejected.load("")
        #expect(rejected.needsReauthentication, "a rejected sign-in no longer asks to sign in again")
    }

    /// A refresh landing while the Keychain is being read: the read began
    /// before the write and finishes after it, with the token the write
    /// replaced — which it must neither hand back nor keep.
    @Test func aWriteDuringAReadIsNotUndoneByIt() {
        let keychain = FakeKeychain()
        keychain.put("old", for: "onedrive#1")
        let cache = TokenCache(keychain: keychain)
        let hold = keychain.holdNextRead(of: "onedrive#1")
        let done = DispatchSemaphore(value: 0)
        let seen = Locked<String?>(nil)
        DispatchQueue.global().async {
            seen.set(cache.token(for: "onedrive#1"))
            done.signal()
        }
        hold.reached.wait()

        cache.setToken("new", for: "onedrive#1")
        hold.resume.signal()
        done.wait()
        #expect(seen.value == "new", "a read that began before a write handed back what the write replaced")
        #expect(cache.token(for: "onedrive#1") == "new", "a read that began before a write put back what it replaced")
        #expect(keychain.stored("onedrive#1") == "new")
    }
}

/// A value handed between threads in a test, under a lock.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }
    func set(_ value: Value) { lock.withLock { stored = value } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

/// `TokenRefresh` — the one way every store exchanges a refresh token
/// (implemented.md §51.36) — against a keychain of the test's own. Each test
/// names its own accounts: the coordinators are one per account, for the
/// whole process.
struct TokenRefreshTests {

    private func accounts() -> (access: String, refresh: String) {
        let account = "test#\(UUID().uuidString)"
        return (account, account + "-refresh")
    }

    /// Two stores of one account — two collections, or a collection and the
    /// browser — whose requests both met a 401: one exchange, and one token
    /// for both. Each store had its own coordinator, so each spent the same
    /// single-use refresh token, and the loser got `invalid_grant`.
    @Test func oneExchangePerAccountForEveryStoreOfIt() async throws {
        let (account, refreshAccount) = accounts()
        let cache = TokenCache(keychain: TokenCacheTests.FakeKeychain())
        cache.setToken("refresh-1", for: refreshAccount)
        let exchanges = Locked(0)
        let gate = Gate()
        let exchange: @Sendable (String) async throws -> (access: String, rotated: String?) = { _ in
            exchanges.mutate { $0 += 1 }
            await gate.wait()
            return ("access-2", "refresh-2")
        }
        async let first = TokenRefresh.refresh(account: account, refreshAccount: refreshAccount, in: cache, exchange: exchange)
        async let second = TokenRefresh.refresh(account: account, refreshAccount: refreshAccount, in: cache, exchange: exchange)
        try await Task.sleep(for: .milliseconds(100))
        gate.open()
        let tokens = try await [first, second]
        #expect(tokens == ["access-2", "access-2"])
        #expect(exchanges.value == 1, "one account's refresh token was exchanged \(exchanges.value) times")
        #expect(cache.token(for: refreshAccount) == "refresh-2")
    }

    /// A refresh token another process rotated — a Debug and a Release build
    /// open at once — is spent here, and the provider refuses it: the Keychain
    /// is read again, and the exchange made once more with what it holds.
    @Test func aRefreshTokenRotatedElsewhereIsReadAgain() async throws {
        let (account, refreshAccount) = accounts()
        let keychain = TokenCacheTests.FakeKeychain()
        keychain.put("refresh-old", for: refreshAccount)
        let cache = TokenCache(keychain: keychain)
        #expect(cache.token(for: refreshAccount) == "refresh-old")
        keychain.put("refresh-new", for: refreshAccount)

        let tried = Locked<[String]>([])
        let access = try await TokenRefresh.refresh(account: account, refreshAccount: refreshAccount, in: cache) { token in
            tried.mutate { $0.append(token) }
            guard token == "refresh-new" else { throw RemoteStoreError.http(400, "invalid_grant") }
            return ("access", "refresh-newer")
        }
        #expect(access == "access")
        #expect(tried.value == ["refresh-old", "refresh-new"])
        #expect(keychain.stored(refreshAccount) == "refresh-newer")
    }

    /// The control: a refresh token refused when the Keychain holds no other
    /// is refused once, and the account needs signing in again.
    @Test func aRefusedRefreshTokenIsTriedOnce() async throws {
        let (account, refreshAccount) = accounts()
        let keychain = TokenCacheTests.FakeKeychain()
        keychain.put("refresh-old", for: refreshAccount)
        let cache = TokenCache(keychain: keychain)

        let tried = Locked<[String]>([])
        await #expect(throws: RemoteStoreError.notAuthenticated) {
            _ = try await TokenRefresh.refresh(account: account, refreshAccount: refreshAccount, in: cache) { token in
                tried.mutate { $0.append(token) }
                throw RemoteStoreError.http(400, "invalid_grant")
            }
        }
        #expect(tried.value == ["refresh-old"])
    }

    /// Signed out while a refresh was out: still signed out when it lands. The
    /// refresh wrote its tokens back over the sign-out.
    @Test func aSignOutDuringARefreshStaysSignedOut() async throws {
        let (account, refreshAccount) = accounts()
        let keychain = TokenCacheTests.FakeKeychain()
        let cache = TokenCache(keychain: keychain)
        cache.setToken("access-1", for: account)
        cache.setToken("refresh-1", for: refreshAccount)
        let (reached, resume) = (Gate(), Gate())
        let refreshing = Task {
            try await TokenRefresh.refresh(account: account, refreshAccount: refreshAccount, in: cache) { _ in
                reached.open()
                await resume.wait()
                return ("access-2", "refresh-2")
            }
        }
        await reached.wait()

        cache.setToken(nil, for: account)
        cache.setToken(nil, for: refreshAccount)
        resume.open()
        await #expect(throws: RemoteStoreError.notAuthenticated) { try await refreshing.value }
        #expect(cache.token(for: account) == nil, "the refresh signed the account back in")
        #expect(cache.token(for: refreshAccount) == nil)
        #expect(keychain.stored(account) == nil && keychain.stored(refreshAccount) == nil)
    }
}
