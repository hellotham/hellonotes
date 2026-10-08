//
//  WebGuardTests.swift
//  HelloNotesTests
//
//  The Assistant's web tools never hand the model what a private address
//  served (`WebGuard`, implemented.md §51.36).
//
//  `validate` resolves the host itself, and URLSession resolves it again to
//  connect: a short-lived DNS answer can be public for the first and
//  `169.254.169.254` — a cloud metadata endpoint — or `127.0.0.1` for the
//  second (DNS rebinding). URLSession cannot be pinned to the address
//  `validate` saw, but it reports the address each connection was made to,
//  and the tools read a body whole before anything of it reaches the model —
//  so what a private address served is refused there.
//

import Foundation
import Testing
@testable import HelloNotes

struct WebGuardTests {

    @Test func aConnectionToAPrivateAddressIsRefused() {
        for address in ["169.254.169.254", "127.0.0.1", "10.1.2.3", "192.168.0.10", "172.16.5.4",
                        "100.64.0.1", "0.0.0.0", "::1", "fe80::1", "fd00::5", "::ffff:127.0.0.1"] {
            #expect(throws: WebGuard.Blocked.self, "\(address) was let through") {
                try WebGuard.verify([.init(address: address, viaProxy: false)])
            }
        }
    }

    @Test func aConnectionToAPublicAddressIsKept() throws {
        for address in ["93.184.216.34", "1.1.1.1", "2606:4700:4700::1111"] {
            try WebGuard.verify([.init(address: address, viaProxy: false)])
        }
    }

    /// Every connection is asked — a redirect's too: the last one alone could
    /// be public after a private one served an earlier hop.
    @Test func everyConnectionIsAsked() {
        #expect(throws: WebGuard.Blocked.self) {
            try WebGuard.verify([.init(address: "169.254.169.254", viaProxy: false),
                                 .init(address: "93.184.216.34", viaProxy: false)])
        }
    }

    /// Through a proxy the address is the proxy's — often a private one on a
    /// company network — and says nothing about where the page came from, so
    /// it is not asked; nor is a connection with no address reported, such as
    /// a load from the cache.
    @Test func aProxyOrAnUnreportedAddressIsNotAsked() throws {
        try WebGuard.verify([.init(address: "10.0.0.8", viaProxy: true)])
        try WebGuard.verify([.init(address: nil, viaProxy: false)])
    }
}
