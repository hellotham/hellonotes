//
//  PlatformParityTests.swift
//  HelloNotesTests
//
//  The parity check that reads the source, because the bug it guards against is
//  invisible at runtime.
//
//  `AppActions` is the app's whole command surface, and most of its fields are
//  **optional closures**: a command whose field is nil still appears in the menu
//  bar and in the palette, still draws, still enables, and does nothing when
//  chosen. Nothing crashes and no test fails. Three shipped that way at once —
//  "Open in New Window", "New Window" and "Connect Over the Web" were all nil on
//  iOS while the capability behind each existed on that platform.
//
//  Two audits missed them, both by asking "does iOS have an equivalent?" of each
//  `#if os(macOS)` gate. That question finds features which are *absent*; these
//  were *present and unwired*. This test asks the question that catches them:
//  for every field of `AppActions`, is it supplied on both platforms?
//
//  Source-scanning rather than runtime, because both shells' `appActions` are
//  private computed properties on view structs and there is no instance to
//  inspect. It reads the two files the way a reviewer would, and it is precise
//  enough to be useful: the failure names the field.
//

import Foundation
import Testing
@testable import HelloNotes

struct PlatformParityTests {

    /// Fields that are genuinely one-platform, each with the reason. Anything
    /// *not* on this list must be wired on both — so adding a Mac-only command
    /// is a deliberate act with a justification beside it, not an omission.
    /// Empty, and meant to stay that way.
    ///
    /// It held one entry — `revealInFinder`, justified as "iOS has no Finder,
    /// and no public API to reveal an arbitrary path in Files". The first half
    /// is true and the second was the wrong question: iOS has Files, it opens
    /// at a path, and "show me this file where it lives" is a question both
    /// platforms can answer. `FileReveal` answers it on both, and the entry
    /// went with it.
    ///
    /// The wider ruling on this project is that there are no exemptions. Adding
    /// one here is not a decision to take alone — the record of judgement calls
    /// about "this platform is different" in this codebase is four for four
    /// wrong, each defended in a comment by whoever made it.
    static let platformSpecific: [String: String] = [:]

    private static func source(_ name: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()   // …/HelloNotesTests
            .deletingLastPathComponent()   // …/<repo root>
            .appending(path: "HelloNotes")
            .appending(path: name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every command the menu bar can show is wired on both platforms.
    @Test func everyAppActionIsSuppliedOnBothShells() throws {
        let commands = try Self.source("UI/AppCommands.swift")
        let mac = try Self.source("MacContentView.swift")
        let ios = try Self.source("iOSContentView.swift")

        // The fields of the action structs only — `AppActions` and the nested
        // `…Actions` it carries. Scoped rather than every `var` in the file,
        // because `CloudBrowser.displayName` is also a `var` here and iOS
        // referring to it is not a parity signal. (It failed exactly that way
        // on the first run, which is the sort of thing a scan should be made to
        // prove about itself.)
        let structOpens = /^struct ([A-Za-z_][A-Za-z0-9_]*)/
        let declaration = /^\s*var ([A-Za-z_][A-Za-z0-9_]*)\s*:/
        var fields: Set<String> = []
        var insideActions = false
        for line in commands.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if let opened = try? structOpens.firstMatch(in: text) {
                insideActions = String(opened.1).hasSuffix("Actions")
            }
            guard insideActions, let match = try? declaration.firstMatch(in: text) else { continue }
            fields.insert(String(match.1))
        }
        #expect(fields.count > 30, "the scan found no fields — the declaration shape changed")

        /// Supplied as an argument label anywhere in a shell's source.
        func supplies(_ shell: String, _ field: String) -> Bool {
            shell.contains("\(field):")
        }

        var missing: [String] = []
        for field in fields.sorted() {
            let onMac = supplies(mac, field)
            let onIOS = supplies(ios, field)
            guard onMac != onIOS else { continue }
            if Self.platformSpecific[field] != nil { continue }
            missing.append("\(field) — wired on \(onMac ? "macOS" : "iOS") only")
        }

        #expect(missing.isEmpty, """
            These commands are wired on one platform and not the other. An \
            unwired optional still draws an enabled menu item that does \
            nothing, so either wire it or add it to `platformSpecific` with \
            the reason:
            \(missing.joined(separator: "\n"))
            """)
    }

    /// The documented exceptions have to stay real: a field listed as
    /// platform-specific that no longer exists is a stale excuse, and the next
    /// person reads it as a rule.
    @Test func everyDocumentedExceptionStillExists() throws {
        let commands = try Self.source("UI/AppCommands.swift")
        for (field, reason) in Self.platformSpecific {
            #expect(commands.contains("var \(field):"),
                    "`\(field)` is listed as platform-specific (\(reason)) but is no longer a field of AppActions")
        }
    }
}
