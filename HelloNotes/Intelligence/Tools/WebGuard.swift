//
//  WebGuard.swift
//  HelloNotes
//
//  SSRF protection for the agent's web tools. The Assistant can be steered by
//  injected content (fetched pages, note bodies), so `web_fetch` / `web_search`
//  must never be usable to reach internal services or cloud metadata endpoints.
//  This rejects non-http(s) URLs and any host that resolves to a loopback,
//  private, link-local, or unique-local address — re-validates every HTTP
//  redirect so an allowed host can't bounce to an internal one — and refuses
//  what a private address served, whatever the host resolved to when it was
//  checked (`load`, against DNS rebinding).
//
//  `nonisolated`, and it matters: this target defaults to the main actor, and
//  `validate` resolves the host with a synchronous `getaddrinfo`. Isolated, every
//  fetch the Assistant made paid a DNS round trip on the main thread — and the
//  redirect delegate, which URLSession calls on its own queue, was calling a
//  main-actor function from off it. Nothing here touches shared state.
//

import Foundation
import Darwin

nonisolated enum WebGuard {
    nonisolated struct Blocked: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Throw if `url` isn't a fetchable public http(s) endpoint.
    static func validate(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw Blocked(reason: "Only http(s) URLs can be fetched.")
        }
        guard let host = url.host, !host.isEmpty else {
            throw Blocked(reason: "The URL has no host.")
        }
        let addresses = resolve(host)
        guard !addresses.isEmpty else {
            throw Blocked(reason: "Couldn't resolve “\(host)”.")
        }
        for addr in addresses where isPrivate(addr) {
            throw Blocked(reason: "Refusing to fetch a private, loopback, or link-local address (\(host)).")
        }
    }

    /// A URLSession whose delegate re-validates each redirect target.
    static func session(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpCookieStorage = nil
        // Every load is a network load, so every connection reports its address.
        config.urlCache = nil
        return URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
    }

    /// `request`'s response and its body, read up to `byteCap` — refused if
    /// any connection that served it was to a private address.
    ///
    /// `validate` resolves the host itself, and URLSession resolves it again
    /// to connect: a short-lived DNS answer can be public for the first and
    /// `169.254.169.254` — a cloud metadata endpoint — for the second (DNS
    /// rebinding). URLSession cannot be pinned to the address `validate` saw,
    /// but it reports the address each connection was made to, and the body is
    /// read whole here before any of it can reach the model: a rebound request
    /// is made, and what it returns is never read (implemented.md §51.36).
    static func load(_ request: URLRequest, timeout: TimeInterval,
                     byteCap: Int) async throws -> (data: Data, response: URLResponse) {
        let session = Self.session(timeout: timeout)
        defer { session.finishTasksAndInvalidate() }
        let connections = Connections()
        let (bytes, response) = try await session.bytes(for: request, delegate: connections)
        var data = Data()
        if let http = response as? HTTPURLResponse, http.expectedContentLength > 0 {
            data.reserveCapacity(min(byteCap, Int(clamping: http.expectedContentLength)))
        }
        for try await byte in bytes {
            data.append(byte)
            if data.count >= byteCap { break }
        }
        bytes.task.cancel()
        try verify(await connections.collected())
        return (data, response)
    }

    /// One connection a load was served over: the address it was made to, if
    /// one was reported, and whether it went through a proxy.
    nonisolated struct Connection: Sendable {
        let address: String?
        let viaProxy: Bool
    }

    /// Throw if any of `connections` was made to a private address.
    ///
    /// A proxy's connection is the proxy's — often a private address on a
    /// company network — and says nothing about where the page came from, so
    /// it is not asked; nor is one with no address reported.
    static func verify(_ connections: [Connection]) throws {
        for connection in connections where !connection.viaProxy {
            guard let address = connection.address, let parsed = sockaddrData(address) else { continue }
            if isPrivate(parsed) {
                throw Blocked(reason: "Refusing what a private, loopback, or link-local address served (\(address)).")
            }
        }
    }

    /// `address`, written as IPv4 or IPv6, as the `sockaddr` `isPrivate` reads.
    private static func sockaddrData(_ address: String) -> Data? {
        let bare = address.split(separator: "%").first.map(String.init) ?? address
        var v4 = sockaddr_in()
        v4.sin_family = sa_family_t(AF_INET)
        if inet_pton(AF_INET, bare, &v4.sin_addr) == 1 {
            return Data(bytes: &v4, count: MemoryLayout<sockaddr_in>.size)
        }
        var v6 = sockaddr_in6()
        v6.sin6_family = sa_family_t(AF_INET6)
        if inet_pton(AF_INET6, bare, &v6.sin6_addr) == 1 {
            return Data(bytes: &v6, count: MemoryLayout<sockaddr_in6>.size)
        }
        return nil
    }

    /// Hears the connections a load was served over, as URLSession reports
    /// them when the task finishes.
    private nonisolated final class Connections: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var reported: [Connection]?

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didFinishCollecting metrics: URLSessionTaskMetrics) {
            let connections = metrics.transactionMetrics
                .filter { $0.resourceFetchType == .networkLoad }
                .map { Connection(address: $0.remoteAddress, viaProxy: $0.isProxyConnection) }
            lock.withLock { reported = connections }
        }

        /// What was reported, once it has been — a task's metrics arrive just
        /// after its last byte. Waits a few seconds at most; if they never
        /// come, there is nothing to ask.
        func collected() async -> [Connection] {
            for _ in 0..<200 {
                if let reported = lock.withLock({ reported }) { return reported }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return []
        }
    }

    // MARK: - DNS + address classification

    private static func resolve(_ host: String) -> [Data] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let head = result else { return [] }
        defer { freeaddrinfo(result) }
        var out: [Data] = []
        var node: UnsafeMutablePointer<addrinfo>? = head
        while let n = node {
            if let sa = n.pointee.ai_addr {
                out.append(Data(bytes: sa, count: Int(n.pointee.ai_addrlen)))
            }
            node = n.pointee.ai_next
        }
        return out
    }

    private static func isPrivate(_ sockaddrData: Data) -> Bool {
        sockaddrData.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            let family = Int32(base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family)
            switch family {
            case AF_INET:
                let sin = base.assumingMemoryBound(to: sockaddr_in.self)
                return isPrivateIPv4(UInt32(bigEndian: sin.pointee.sin_addr.s_addr))
            case AF_INET6:
                let sin6 = base.assumingMemoryBound(to: sockaddr_in6.self)
                var a = sin6.pointee.sin6_addr
                let b = withUnsafeBytes(of: &a) { Array($0) }
                return isPrivateIPv6(b)
            default:
                return true
            }
        }
    }

    private static func isPrivateIPv4(_ a: UInt32) -> Bool {
        let o1 = (a >> 24) & 0xff, o2 = (a >> 16) & 0xff
        if o1 == 10 || o1 == 127 || o1 == 0 { return true }               // 10/8, loopback, 0/8
        if o1 == 169 && o2 == 254 { return true }                         // link-local / metadata
        if o1 == 172 && (16...31).contains(o2) { return true }            // 172.16/12
        if o1 == 192 && o2 == 168 { return true }                         // 192.168/16
        if o1 == 100 && (64...127).contains(o2) { return true }           // CGNAT 100.64/10
        return false
    }

    private static func isPrivateIPv6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return true }
        if b.allSatisfy({ $0 == 0 }) { return true }                      // ::
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true } // ::1 loopback
        if (b[0] & 0xfe) == 0xfc { return true }                          // fc00::/7 unique-local
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }          // fe80::/10 link-local
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
            let v4 = (UInt32(b[12]) << 24) | (UInt32(b[13]) << 16) | (UInt32(b[14]) << 8) | UInt32(b[15])
            return isPrivateIPv4(v4)                                       // IPv4-mapped ::ffff:0:0/96
        }
        if b[0] == 0x00, b[1] == 0x64, b[2] == 0xff, b[3] == 0x9b, b[4..<12].allSatisfy({ $0 == 0 }) {
            let v4 = (UInt32(b[12]) << 24) | (UInt32(b[13]) << 16) | (UInt32(b[14]) << 8) | UInt32(b[15])
            return isPrivateIPv4(v4)                                       // NAT64 64:ff9b::/96
        }
        return false
    }

    /// Blocks a redirect whose new target fails `validate`.
    private nonisolated final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            if let url = request.url, (try? WebGuard.validate(url)) != nil {
                completionHandler(request)
            } else {
                completionHandler(nil)   // stop at the current response; don't follow.
            }
        }
    }
}
